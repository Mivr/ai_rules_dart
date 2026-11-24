/// iOS and macOS application bundle assembly.
///
/// Turns a [BundleConfig] into an unsigned (or `zsign`-signed) `.app`
/// directory and deterministic archive: stages the executable, frameworks,
/// resources and `Info.plist`, fixes Mach-O rpaths, and writes
/// `_CodeSignature/CodeResources` when signing.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'code_resources.dart' show writeCodeResources;
import 'plist_info.dart' show InfoPlistRequest, buildInfoPlist;
import 'xtool_framework.dart'
    show
        copyAdditionalContentSpec,
        copyDirectorySync,
        copyResourceSpec,
        extractFrameworkArchive,
        resolveFrameworkDirectories;
import 'zip_writer.dart' show createDeterministicZipFromDirectory, getUint64LE;

typedef _Type = FileSystemEntityType;

typedef _Scan = ({Set<String> existingRpaths, int minPayloadOffset})?;
typedef _Staged = ({Directory dir, String fileName, String name});

/// Configuration for assembling an iOS or macOS application bundle and archive.
class BundleConfig {
  final String platform; // 'ios', 'ios_sim', or 'macos'
  final String appName;
  final String bundleId;
  final String executablePath;
  final String minimumOsVersion;
  final List<String> families;
  final String? versionFilePath;
  final List<String> infoPlistPaths;
  final Map<String, String> defines;
  final List<String> frameworkPaths;
  final List<String> nativeLibPaths;
  final List<String> resourceSpecs;
  final List<String> additionalContentSpecs;
  final String? provisioningProfilePath;
  final String? entitlementsPath;
  final String? zsignPath;
  final String? certificatePath;
  final String? certificatePasswordFilePath;
  final String? certificatePasswordEnv;
  final String? outputArchivePath;
  final String? outputAppDirPath;
  final String? tempDirPath;
  final Map<String, String>? environment;

  const new({
    required this.platform,
    required this.appName,
    required this.bundleId,
    required this.executablePath,
    required this.minimumOsVersion,
    this.families = const [],
    this.versionFilePath,
    this.infoPlistPaths = const [],
    this.defines = const {},
    this.frameworkPaths = const [],
    this.nativeLibPaths = const [],
    this.resourceSpecs = const [],
    this.additionalContentSpecs = const [],
    this.provisioningProfilePath,
    this.entitlementsPath,
    this.zsignPath,
    this.certificatePath,
    this.certificatePasswordFilePath,
    this.certificatePasswordEnv,
    this.outputArchivePath,
    this.outputAppDirPath,
    this.tempDirPath,
    this.environment,
  });
}

Directory _allocateDeterministicStageSubdir(Directory base, String prefix) {
  final primary = Directory('${base.path}/$prefix');
  if (!primary.existsSync()) {
    primary.createSync(recursive: true);
    return primary;
  }
  for (var i = 1; ; i++) {
    final candidate = Directory('${base.path}/${prefix}_$i');
    if (!candidate.existsSync()) {
      candidate.createSync(recursive: true);
      return candidate;
    }
  }
}

(Directory stageDir, Directory? createdBaseDir) _createStagingDirectory(
  BundleConfig config,
) {
  if (config.tempDirPath != null && config.tempDirPath!.isNotEmpty) {
    final base = Directory(config.tempDirPath!);
    final bool existed = base.existsSync();
    if (!existed) base.createSync(recursive: true);
    final Directory stage = _allocateDeterministicStageSubdir(base, 'stage');
    return (stage, existed ? null : base);
  }

  final List<String> outputParentCandidates = [
    if (config.outputAppDirPath != null && config.outputAppDirPath!.isNotEmpty)
      Directory(config.outputAppDirPath!).parent.path,
    if (config.outputArchivePath != null &&
        config.outputArchivePath!.isNotEmpty)
      File(config.outputArchivePath!).parent.path,
  ];

  for (final candidate in outputParentCandidates) {
    if (candidate.isNotEmpty) {
      final base = Directory(candidate);
      if (!base.existsSync()) base.createSync(recursive: true);
      final Directory stage = _allocateDeterministicStageSubdir(
        base,
        '.xtool_pack_stage',
      );
      return (stage, null);
    }
  }

  final fallbackBase = Directory('.xtool_pack_tmp');
  final bool existed = fallbackBase.existsSync();
  if (!existed) fallbackBase.createSync(recursive: true);
  final Directory stage = _allocateDeterministicStageSubdir(
    fallbackBase,
    'stage',
  );
  return (stage, existed ? null : fallbackBase);
}

void _collectRpathString(
  Uint8List bytes,
  ByteData bd,
  int pos,
  int cmdsize,
  Set<String> out,
) {
  final int strOff = bd.getUint32(pos + 8, Endian.little);
  if (strOff >= cmdsize) return;
  int end = pos + strOff;
  while (end < pos + cmdsize && bytes[end] != 0) {
    end++;
  }
  out.add(utf8.decode(bytes.sublist(pos + strOff, end), allowMalformed: true));
}

int _sectionPayloadFloor(
  ByteData bd,
  int pos,
  int cmdsize,
  int nsects,
  int floor,
) {
  int sectPos = pos + 72;
  for (var s = 0; s < nsects; s++) {
    if (sectPos + 80 > pos + cmdsize) break;
    final int sectSize = getUint64LE(bd, sectPos + 40);
    final int sectOffset = bd.getUint32(sectPos + 48, Endian.little);
    if (sectSize > 0 && sectOffset > 0 && sectOffset < floor) {
      floor = sectOffset;
    }
    sectPos += 80;
  }
  return floor;
}

int _segmentPayloadFloor(
  Uint8List bytes,
  ByteData bd,
  int pos,
  int cmdsize,
  int floor,
) {
  final Uint8List segBytes = bytes.sublist(pos + 8, pos + 24);
  final int nul = segBytes.indexOf(0);
  final String segName = ascii.decode(
    nul >= 0 ? segBytes.sublist(0, nul) : segBytes,
    allowInvalid: true,
  );
  final int fileoff = getUint64LE(bd, pos + 40);
  final int filesize = getUint64LE(bd, pos + 48);
  final int nsects = bd.getUint32(pos + 64, Endian.little);
  if (segName != '__TEXT' &&
      segName != '__PAGEZERO' &&
      filesize > 0 &&
      fileoff > 0 &&
      fileoff < floor) {
    floor = fileoff;
  }
  return _sectionPayloadFloor(bd, pos, cmdsize, nsects, floor);
}

/// Scans Mach-O load commands for existing `LC_RPATH` entries and the lowest
/// payload file offset, returning null when the binary must be left alone.
_Scan _scanMachOLoadCommands(
  Uint8List bytes,
  ByteData bd,
  int ncmds,
  int sizeofcmds,
) {
  final existingRpaths = <String>{};
  int minPayloadOffset = bytes.length;
  var pos = 32;
  for (var i = 0; i < ncmds; i++) {
    if (pos + 8 > 32 + sizeofcmds) return null;
    final int cmd = bd.getUint32(pos, Endian.little);
    final int cmdsize = bd.getUint32(pos + 4, Endian.little);
    if (cmdsize < 8 || pos + cmdsize > 32 + sizeofcmds) return null;
    if (cmd == 0x8000001c && cmdsize >= 12) {
      _collectRpathString(bytes, bd, pos, cmdsize, existingRpaths);
    } else if (cmd == 0x19 && cmdsize >= 72) {
      minPayloadOffset = _segmentPayloadFloor(
        bytes,
        bd,
        pos,
        cmdsize,
        minPayloadOffset,
      );
    }
    pos += cmdsize;
  }
  return (existingRpaths: existingRpaths, minPayloadOffset: minPayloadOffset);
}

/// Encodes an `LC_RPATH` load command for [rpath]; shared with the stub runner generator.
Uint8List encodeMachORpathCommand(String rpath) {
  final Uint8List pathBytes = utf8.encode(rpath);
  const headerSize = 12;
  final int unpadded = headerSize + pathBytes.length + 1;
  final int cmdSize = (unpadded + 7) & ~7;
  final bytes = Uint8List(cmdSize);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x8000001c, Endian.little); // LC_RPATH
  bd.setUint32(4, cmdSize, Endian.little);
  bd.setUint32(8, headerSize, Endian.little); // path offset
  bytes.setRange(headerSize, headerSize + pathBytes.length, pathBytes);
  return bytes;
}

void _appendMissingRpaths(
  File execFile,
  Uint8List bytes,
  int ncmds,
  int sizeofcmds,
  int minPayloadOffset,
  List<Uint8List> missingRpaths,
) {
  final int addedSize = missingRpaths.fold<int>(0, (s, c) => s + c.length);
  final int newLoadCmdEnd = 32 + sizeofcmds + addedSize;
  if (newLoadCmdEnd > minPayloadOffset) return;
  for (int i = 32 + sizeofcmds; i < newLoadCmdEnd; i++) {
    if (bytes[i] != 0) return;
  }
  final out = Uint8List.fromList(bytes);
  final outBd = ByteData.sublistView(out);
  outBd.setUint32(16, ncmds + missingRpaths.length, Endian.little);
  outBd.setUint32(20, sizeofcmds + addedSize, Endian.little);
  int writeOff = 32 + sizeofcmds;
  for (final cmdBytes in missingRpaths) {
    out.setRange(writeOff, writeOff + cmdBytes.length, cmdBytes);
    writeOff += cmdBytes.length;
  }
  execFile.writeAsBytesSync(out);
}

void _ensureExecutableRpaths(File execFile, {required bool isMacOS}) {
  final Uint8List bytes = execFile.readAsBytesSync();
  if (bytes.length < 32) return;
  final bd = ByteData.sublistView(bytes);
  if (bd.getUint32(0, Endian.little) != 0xfeedfacf) return;
  final int ncmds = bd.getUint32(16, Endian.little);
  final int sizeofcmds = bd.getUint32(20, Endian.little);
  if (32 + sizeofcmds > bytes.length) return;

  final _Scan scan = _scanMachOLoadCommands(bytes, bd, ncmds, sizeofcmds);
  if (scan == null) return;
  final requiredRpaths = <String>[
    '@executable_path/Frameworks',
    if (isMacOS) '@executable_path/../Frameworks',
  ];
  final List<Uint8List> missingRpaths = [
    for (final rp in requiredRpaths)
      if (!scan.existingRpaths.contains(rp)) encodeMachORpathCommand(rp),
  ];
  if (missingRpaths.isEmpty) return;
  _appendMissingRpaths(
    execFile,
    bytes,
    ncmds,
    sizeofcmds,
    scan.minPayloadOffset,
    missingRpaths,
  );
}

void _checkBundlePlatform(BundleConfig config) {
  if (config.platform != 'ios' &&
      config.platform != 'ios_sim' &&
      config.platform != 'macos') {
    throw ArgumentError(
      'Unsupported platform "${config.platform}". Expected ios, ios_sim, or macos.',
    );
  }
}

File _requireBundleExecutable(BundleConfig config) {
  final execFile = File(config.executablePath);
  if (!execFile.existsSync()) {
    throw ArgumentError(
      'Executable binary does not exist: ${config.executablePath}',
    );
  }
  return execFile;
}

Map<String, String> _readBundleVersionDefines(BundleConfig config) {
  final effectiveDefines = <String, String>{...config.defines};
  if (config.versionFilePath == null || config.versionFilePath!.isEmpty) {
    return effectiveDefines;
  }
  final versionFile = File(config.versionFilePath!);
  if (!versionFile.existsSync()) {
    throw ArgumentError(
      'Version file does not exist: ${config.versionFilePath}',
    );
  }
  final dynamic decoded = jsonDecode(versionFile.readAsStringSync());
  if (decoded is! Map) {
    throw FormatException(
      'Version file ${config.versionFilePath} must contain a JSON object.',
    );
  }
  final dynamic buildVer = decoded['build_version'];
  final dynamic shortVer = decoded['short_version_string'];
  if (buildVer is String && buildVer.isNotEmpty) {
    effectiveDefines.putIfAbsent('FLUTTER_BUILD_NUMBER', () => buildVer);
  }
  if (shortVer is String && shortVer.isNotEmpty) {
    effectiveDefines.putIfAbsent('FLUTTER_BUILD_NAME', () => shortVer);
  }
  return effectiveDefines;
}

void _stripCodeSignatures(Directory dir) {
  if (!dir.existsSync()) return;
  for (final FileSystemEntity entity in dir.listSync(followLinks: false)) {
    final String name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name == '_CodeSignature') {
      entity.deleteSync(recursive: true);
    } else if (entity is Directory) {
      _stripCodeSignatures(entity);
    }
  }
}

void _replaceWithSymlinkSync(String linkPath, String target) {
  final _Type type = FileSystemEntity.typeSync(linkPath, followLinks: false);
  if (type == FileSystemEntityType.directory) {
    Directory(linkPath).deleteSync(recursive: true);
  } else if (type == FileSystemEntityType.link) {
    Link(linkPath).deleteSync();
  } else if (type != FileSystemEntityType.notFound) {
    File(linkPath).deleteSync();
  }
  Link(linkPath).createSync(target);
}

void _normalizeMacosVersionedFramework(Directory fwDir, String fwName) {
  final versionADir = Directory('${fwDir.path}/Versions/A');
  if (!versionADir.existsSync()) return;

  _replaceWithSymlinkSync('${fwDir.path}/Versions/Current', 'A');
  if (File('${versionADir.path}/$fwName').existsSync()) {
    _replaceWithSymlinkSync(
      '${fwDir.path}/$fwName',
      'Versions/Current/$fwName',
    );
  }
  for (final sub in const ['Resources', 'Headers', 'Modules']) {
    if (Directory('${versionADir.path}/$sub').existsSync()) {
      _replaceWithSymlinkSync('${fwDir.path}/$sub', 'Versions/Current/$sub');
    }
  }
}

/// Assembles one application bundle inside a staging directory: copies the
/// executable, metadata, resources, frameworks and native libraries, signs
/// when configured, and emits the requested outputs.
/// Host environment variables that pass through into bundle tool runs (such as `zsign`).
const Set<String> ambientHostEnvVars = {
  'TMPDIR',
  'TEST_TMPDIR',
  'HOME',
  'PATH',
  'PWD',
  'USER',
  'LOGNAME',
  'SHELL',
  'SHLVL',
  '_',
};

class _BundleAssembly {
  final BundleConfig config;
  final Directory tempDir;
  final Map<String, String> effectiveDefines;

  late final bool isMacOS = config.platform == 'macos';
  late final String appRelPath = isMacOS
      ? '${config.appName}.app'
      : 'Payload/${config.appName}.app';
  late final String contentsRelPrefix = isMacOS
      ? '$appRelPath/Contents'
      : appRelPath;
  late final Directory frameworksScratch = Directory(
    '${tempDir.path}/frameworks',
  );

  // Bundle staging directories. Assigned eagerly by [_createLayout] (called
  // first by [run]) in the fixed order below. Directory creation must never
  // depend on a lazy initializer's side effect: a resourceless macOS bundle
  // still stages an (empty) Contents/Resources/.
  late Directory appDir;
  late Directory contentsDir;
  late Directory execDir;
  late Directory frameworksDir;
  late Directory resourcesDir;

  final executablePaths = <String>{};

  bool get shouldSign =>
      config.zsignPath != null && config.zsignPath!.isNotEmpty;

  new(this.config, this.tempDir, this.effectiveDefines);

  void run() {
    _createLayout();
    _copyMainExecutable();
    _writeBundleMetadata();
    _copyBundleResources();
    _copyProvisioningProfile();
    _embedFrameworks();
    _embedNativeLibs();
    _signOrStripBundle();
    _emitAppDir();
    _emitArchive();
  }

  /// Creates every bundle staging directory up front, in the same order the
  /// pre-refactor [assembleBundle] created them. In particular the macOS
  /// Contents/Resources/ directory always exists, even when the bundle packs
  /// no resources.
  void _createLayout() {
    appDir = Directory('${tempDir.path}/$appRelPath')
      ..createSync(recursive: true);
    contentsDir = isMacOS
        ? (Directory('${appDir.path}/Contents')..createSync())
        : appDir;
    execDir = isMacOS
        ? (Directory('${contentsDir.path}/MacOS')..createSync())
        : contentsDir;
    frameworksDir = Directory('${contentsDir.path}/Frameworks');
    resourcesDir = isMacOS
        ? (Directory('${contentsDir.path}/Resources')..createSync())
        : contentsDir;
  }

  void _copyMainExecutable() {
    // 1. Copy main executable and ensure @executable_path/Frameworks LC_RPATH.
    // Executable permissions (0755) are recorded directly in the ZIP central
    // directory via executablePaths without spawning an external chmod process.
    final destExecPath = '${execDir.path}/${config.appName}';
    File(config.executablePath).copySync(destExecPath);
    _ensureExecutableRpaths(File(destExecPath), isMacOS: isMacOS);
    executablePaths.add(
      isMacOS
          ? '$appRelPath/Contents/MacOS/${config.appName}'
          : '$appRelPath/${config.appName}',
    );
  }

  void _writeBundleMetadata() {
    // 2. Merge and write Info.plist + PkgInfo.
    final List<String> plistXmls = [
      for (final p in config.infoPlistPaths) File(p).readAsStringSync(),
    ];
    final String mergedPlist = buildInfoPlist(
      InfoPlistRequest(
        plistXmls: plistXmls,
        platform: config.platform,
        appName: config.appName,
        bundleId: config.bundleId,
        minimumOsVersion: config.minimumOsVersion,
        extraVariables: effectiveDefines,
        families: config.families,
      ),
    );
    File('${contentsDir.path}/Info.plist').writeAsStringSync(mergedPlist);
    File('${contentsDir.path}/PkgInfo').writeAsStringSync('APPL????');
  }

  void _copyBundleResources() {
    // 3. Copy resources.
    for (final String spec in config.resourceSpecs) {
      copyResourceSpec(spec, resourcesDir);
    }

    // 3b. Copy additional_contents into their target bundle subdirectories.
    for (final String spec in config.additionalContentSpecs) {
      copyAdditionalContentSpec(
        spec,
        contentsDir,
        contentsRelPrefix: contentsRelPrefix,
        executablePaths: executablePaths,
      );
    }
  }

  void _copyProvisioningProfile() {
    // 4. Copy provisioning profile (iOS device builds).
    if (config.provisioningProfilePath != null && !isMacOS) {
      final profileFile = File(config.provisioningProfilePath!);
      if (!profileFile.existsSync()) {
        throw ArgumentError(
          'Provisioning profile does not exist: ${config.provisioningProfilePath}',
        );
      }
      profileFile.copySync('${appDir.path}/embedded.mobileprovision');
    }
  }

  void _embedFrameworks() {
    // 5. Resolve and embed frameworks and native dynamic libraries.
    for (final String fwInput in config.frameworkPaths) {
      final List<Directory> fwDirs;
      if (fwInput.endsWith('.framework.zip')) {
        // App.framework travels between actions as its deterministic archive
        // because Bazel does not preserve the framework's directory symlinks
        // when staging a tree artifact as an action input.
        fwDirs = [extractFrameworkArchive(fwInput, frameworksScratch)];
      } else {
        fwDirs = resolveFrameworkDirectories(fwInput, config.platform);
      }
      for (final fwDir in fwDirs) {
        _embedFrameworkDir(fwDir);
      }
    }
  }

  _Staged _stageFrameworkDir(Directory fwDir) {
    frameworksDir.createSync(recursive: true);
    final String fwFileName = fwDir.uri.pathSegments
        .where((s) => s.isNotEmpty)
        .last;
    final String fwName = fwFileName.substring(
      0,
      fwFileName.length - '.framework'.length,
    );
    final destFwDir = Directory('${frameworksDir.path}/$fwFileName');
    copyDirectorySync(fwDir, destFwDir, dereferenceSymlinks: false);
    return (dir: destFwDir, fileName: fwFileName, name: fwName);
  }

  void _embedFrameworkDir(Directory fwDir) {
    final _Staged staged = _stageFrameworkDir(fwDir);
    if (isMacOS) _normalizeMacosVersionedFramework(staged.dir, staged.name);

    // Mark framework binary executable in ZIP metadata.
    final fwRelPrefix = '$contentsRelPrefix/Frameworks/${staged.fileName}';
    _markFrameworkExecutables(staged.dir, staged.name, fwRelPrefix);

    if (shouldSign) {
      writeCodeResources(
        staged.dir,
        excludedRelativePaths: {
          staged.name,
          'Versions/A/${staged.name}',
          'Versions/Current/${staged.name}',
        },
      );
    } else {
      _stripCodeSignatures(staged.dir);
    }
  }

  void _markFrameworkExecutables(
    Directory destFwDir,
    String fwName,
    String fwRelPrefix,
  ) {
    final topBinary = File('${destFwDir.path}/$fwName');
    final versionedBinary = File('${destFwDir.path}/Versions/A/$fwName');
    if (topBinary.existsSync()) executablePaths.add('$fwRelPrefix/$fwName');
    if (versionedBinary.existsSync()) {
      executablePaths.add('$fwRelPrefix/Versions/A/$fwName');
    }
  }

  void _embedNativeLibs() {
    for (final String dylibPath in config.nativeLibPaths) {
      if (FileSystemEntity.isDirectorySync(dylibPath)) {
        _embedNativeLibDir(dylibPath);
      } else if (FileSystemEntity.isFileSync(dylibPath)) {
        _embedNativeLibFile(File(dylibPath));
      } else {
        throw ArgumentError('Native library does not exist: $dylibPath');
      }
    }
  }

  void _embedNativeLibDir(String dylibPath) {
    final List<FileSystemEntity> children = Directory(
      dylibPath,
    ).listSync(followLinks: true)..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in children) {
      if (entity is File) {
        _embedNativeLibFile(entity);
      } else if (entity is Directory && entity.path.endsWith('.framework')) {
        _embedNativeChildFramework(entity);
      }
    }
  }

  void _embedNativeLibFile(File dylibFile) {
    frameworksDir.createSync(recursive: true);
    final String baseName = dylibFile.uri.pathSegments
        .where((s) => s.isNotEmpty)
        .last;
    dylibFile.copySync('${frameworksDir.path}/$baseName');
    executablePaths.add('$contentsRelPrefix/Frameworks/$baseName');
  }

  void _embedNativeChildFramework(Directory entity) {
    final _Staged staged = _stageFrameworkDir(entity);
    final fwRelPrefix = '$contentsRelPrefix/Frameworks/${staged.fileName}';
    _markFrameworkExecutables(staged.dir, staged.name, fwRelPrefix);
  }

  void _signOrStripBundle() {
    // 6. Sign bundle with _CodeSignature/CodeResources + zsign when configured,
    //    or ensure unsigned bundles contain no _CodeSignature/ artifacts.
    if (!shouldSign) {
      _stripCodeSignatures(appDir);
      return;
    }
    writeCodeResources(
      contentsDir,
      excludedRelativePaths: {
        if (isMacOS) 'MacOS/${config.appName}' else config.appName,
      },
    );
    _runZsign(_resolveSigningPassword());
  }

  String? _resolveSigningPassword() {
    if (config.certificatePasswordFilePath != null &&
        config.certificatePasswordFilePath!.isNotEmpty) {
      final pwFile = File(config.certificatePasswordFilePath!);
      if (!pwFile.existsSync()) {
        throw ArgumentError(
          'Certificate password file does not exist: '
          '${config.certificatePasswordFilePath}',
        );
      }
      return pwFile.readAsStringSync().replaceAll(RegExp(r'[\r\n]+$'), '');
    }
    if (config.certificatePasswordEnv == null ||
        config.certificatePasswordEnv!.isEmpty) {
      return null;
    }
    final String pwEnvKey = config.certificatePasswordEnv!;
    final String? envVal;
    if (pwEnvKey == 'TMPDIR' || pwEnvKey == 'TEST_TMPDIR') {
      envVal = config.environment != null
          ? (config.environment![pwEnvKey] ?? '')
          : '';
    } else if (config.environment != null) {
      envVal = config.environment![pwEnvKey];
    } else if (ambientHostEnvVars.contains(pwEnvKey)) {
      envVal = null;
    } else {
      envVal = Platform.environment[pwEnvKey];
    }
    if (envVal == null) {
      throw ArgumentError(
        'Certificate password environment variable '
        '"$pwEnvKey" is not set.',
      );
    }
    return envVal;
  }

  void _runZsign(String? resolvedPassword) {
    final zsignArgs = <String>[];
    final redactedArgs = <String>[];
    if (config.certificatePath != null && config.certificatePath!.isNotEmpty) {
      zsignArgs.addAll(['-k', config.certificatePath!]);
      redactedArgs.addAll(['-k', config.certificatePath!]);
    }
    if (resolvedPassword != null && resolvedPassword.isNotEmpty) {
      zsignArgs.addAll(['-p', resolvedPassword]);
      redactedArgs.addAll(['-p', '<redacted>']);
    }
    if (config.provisioningProfilePath != null &&
        config.provisioningProfilePath!.isNotEmpty) {
      zsignArgs.addAll(['-m', config.provisioningProfilePath!]);
      redactedArgs.addAll(['-m', config.provisioningProfilePath!]);
    }
    if (config.entitlementsPath != null &&
        config.entitlementsPath!.isNotEmpty) {
      zsignArgs.addAll(['-e', config.entitlementsPath!]);
      redactedArgs.addAll(['-e', config.entitlementsPath!]);
    }
    zsignArgs.add(appDir.path);
    redactedArgs.add(appDir.path);
    final ProcessResult result = Process.runSync(
      config.zsignPath!,
      zsignArgs,
      environment: const {'PATH': '/usr/bin:/bin'},
      includeParentEnvironment: false,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        config.zsignPath!,
        redactedArgs,
        'zsign failed (exit ${result.exitCode}):\n${result.stderr}',
        result.exitCode,
      );
    }
  }

  void _emitAppDir() {
    // 8. Emit --output-app-dir if requested.
    if (config.outputAppDirPath != null &&
        config.outputAppDirPath!.isNotEmpty) {
      final outAppDir = Directory(config.outputAppDirPath!);
      if (outAppDir.existsSync()) outAppDir.deleteSync(recursive: true);
      copyDirectorySync(appDir, outAppDir, dereferenceSymlinks: false);
    }
  }

  void _emitArchive() {
    // 9. Emit --output-archive (.ipa or .app.zip) if requested.
    if (config.outputArchivePath != null &&
        config.outputArchivePath!.isNotEmpty) {
      final Uint8List zipBytes = createDeterministicZipFromDirectory(
        tempDir,
        executablePaths: executablePaths,
      );
      final outArchive = File(config.outputArchivePath!);
      outArchive.parent.createSync(recursive: true);
      outArchive.writeAsBytesSync(zipBytes);
    }
  }
}

/// Assembles an iOS `.ipa` or macOS `.app.zip` (and optional `.app` directory)
/// according to [config].
void assembleBundle(BundleConfig config) {
  _checkBundlePlatform(config);
  _requireBundleExecutable(config);
  final Map<String, String> effectiveDefines = _readBundleVersionDefines(
    config,
  );
  final (Directory tempDir, Directory? createdBaseDir) =
      _createStagingDirectory(config);
  try {
    _BundleAssembly(config, tempDir, effectiveDefines).run();
  } finally {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    if (createdBaseDir != null && createdBaseDir.existsSync()) {
      createdBaseDir.deleteSync(recursive: true);
    }
  }
}
