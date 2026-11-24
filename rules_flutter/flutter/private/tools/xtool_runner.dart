/// Darwin SDK resolution and Mach-O `MH_EXECUTE` runner compilation.
///
/// Locates the platform SDK inside a Flutter artifact bundle and compiles
/// (or synthesizes) the runner executable from a [RunnerCompileConfig].

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'xtool_framework.dart'
    show extractFrameworkArchive, resolveFrameworkDirectories;
import 'xtool_stub.dart' show StubRunnerSpec, generateStubExecutableMachO;

({String sdkPrefix, String defaultDirName}) _sdkNamesForPlatform(
  String platform,
) {
  switch (platform) {
    case 'ios':
      return (sdkPrefix: 'iphoneos', defaultDirName: 'iPhoneOS.sdk');
    case 'ios_sim':
      return (
        sdkPrefix: 'iphonesimulator',
        defaultDirName: 'iPhoneSimulator.sdk',
      );
    case 'macos':
      return (sdkPrefix: 'macosx', defaultDirName: 'MacOSX.sdk');
    default:
      throw ArgumentError('Unsupported platform "$platform".');
  }
}

/// Searches an `info.json` artifact bundle for a variant whose key or path
/// names the [sdkPrefix], returning its directory when it exists.
Directory? _findSdkInArtifactInfo(
  Directory sdkRoot,
  Object? decoded,
  String sdkPrefix,
) {
  if (decoded is! Map<String, Object?>) return null;
  final Object? artifacts = decoded['artifacts'];
  if (artifacts is! Map<String, Object?>) return null;
  for (final MapEntry<String, Object?> entry in artifacts.entries) {
    final Directory? candidate = _matchSdkVariant(
      sdkRoot,
      entry.key,
      entry.value,
      sdkPrefix,
    );
    if (candidate != null) return candidate;
  }
  return null;
}

Directory? _matchSdkVariant(
  Directory sdkRoot,
  String key,
  Object? val,
  String sdkPrefix,
) {
  if (val is! Map<String, Object?>) return null;
  final Object? variants = val['variants'];
  if (variants is! List<Object?>) return null;
  final String keyLower = key.toLowerCase();
  for (final Object? v in variants) {
    if (v is! Map<String, Object?>) continue;
    final Object? path = v['path'];
    if (path is! String) continue;
    if (keyLower.startsWith(sdkPrefix) ||
        path.toLowerCase().contains(sdkPrefix)) {
      final candidate = Directory('${sdkRoot.path}/$path');
      if (candidate.existsSync()) {
        return candidate;
      }
    }
  }
  return null;
}

/// Resolves the platform `.sdk` directory inside a `darwin.artifactbundle`
/// directory for [platform] (`ios`, `ios_sim`, or `macos`).
Directory resolveDarwinSdkPathFromArtifactBundle(
  Directory sdkRoot,
  String platform,
) {
  if (!sdkRoot.existsSync()) {
    throw ArgumentError('SDK root directory does not exist: ${sdkRoot.path}');
  }
  final ({String defaultDirName, String sdkPrefix}) names =
      _sdkNamesForPlatform(platform);

  final infoJsonFile = File('${sdkRoot.path}/info.json');
  if (infoJsonFile.existsSync()) {
    final dynamic decoded = jsonDecode(infoJsonFile.readAsStringSync());
    final Directory? fromInfo = _findSdkInArtifactInfo(
      sdkRoot,
      decoded,
      names.sdkPrefix,
    );
    if (fromInfo != null) return fromInfo;
  }

  final fallback = Directory('${sdkRoot.path}/${names.defaultDirName}');
  if (fallback.existsSync()) {
    return fallback;
  }

  throw ArgumentError(
    'Could not resolve Darwin SDK for platform "$platform" in ${sdkRoot.path}',
  );
}

/// Configuration for compiling or synthesizing an iOS/macOS runner binary.
class RunnerCompileConfig {
  final String platform; // 'ios', 'ios_sim', or 'macos'
  final String arch; // 'arm64' or 'x86_64'
  final String appName;
  final String minimumOsVersion;
  final bool sdkAvailable;
  final String? sdkRootPath;
  final String? swiftcPath;
  final String? clangPath;
  final List<String> sourcePaths;
  final List<String> headerPaths;
  final List<String> modulemapPaths;
  final List<String> frameworkPaths;
  final List<String> sdkFrameworks;
  final List<String> sdkDylibs;
  final String outputPath;

  const new({
    required this.platform,
    this.arch = 'arm64',
    required this.appName,
    required this.minimumOsVersion,
    this.sdkAvailable = false,
    this.sdkRootPath,
    this.swiftcPath,
    this.clangPath,
    this.sourcePaths = const [],
    this.headerPaths = const [],
    this.modulemapPaths = const [],
    this.frameworkPaths = const [],
    this.sdkFrameworks = const [],
    this.sdkDylibs = const [],
    required this.outputPath,
  });
}

void _checkRunnerPlatform(RunnerCompileConfig config) {
  if (config.platform != 'ios' &&
      config.platform != 'ios_sim' &&
      config.platform != 'macos') {
    throw ArgumentError(
      'Unsupported platform "${config.platform}". Expected ios, ios_sim, or macos.',
    );
  }
}

void _requireRunnerFilesExist(List<String> paths, String kind) {
  for (final path in paths) {
    if (!File(path).existsSync()) {
      throw ArgumentError('Runner $kind file does not exist: $path');
    }
  }
}

/// Resolves `--framework` inputs to framework directories and their link
/// names, extracting `.framework.zip` archives beside the runner output.
({List<Directory> dirs, List<String> names}) _resolveRunnerFrameworks(
  RunnerCompileConfig config,
) {
  final resolvedFrameworkDirs = <Directory>[];
  final linkedFrameworkNames = <String>[];
  Directory? frameworksScratch;
  for (final String fwInput in config.frameworkPaths) {
    final List<Directory> dirs;
    if (fwInput.endsWith('.framework.zip')) {
      // Same archive form as bundle embedding (see above): extract beside
      // the declared runner output so the linker gets a real directory.
      frameworksScratch ??= Directory('${config.outputPath}.frameworks')
        ..createSync(recursive: true);
      dirs = [extractFrameworkArchive(fwInput, frameworksScratch)];
    } else {
      dirs = resolveFrameworkDirectories(fwInput, config.platform);
    }
    for (final d in dirs) {
      resolvedFrameworkDirs.add(d);
      final String base = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final String fwName = base.endsWith('.framework')
          ? base.substring(0, base.length - '.framework'.length)
          : base;
      if (!linkedFrameworkNames.contains(fwName)) {
        linkedFrameworkNames.add(fwName);
      }
    }
  }
  return (dirs: resolvedFrameworkDirs, names: linkedFrameworkNames);
}

List<String> _dedupeNonEmpty(List<String> values) {
  final deduped = <String>[];
  for (final value in values) {
    if (value.isNotEmpty && !deduped.contains(value)) {
      deduped.add(value);
    }
  }
  return deduped;
}

Directory? _resolveRunnerSdkDir(RunnerCompileConfig config) {
  if (config.sdkAvailable &&
      config.sdkRootPath != null &&
      config.sdkRootPath!.isNotEmpty) {
    return resolveDarwinSdkPathFromArtifactBundle(
      Directory(config.sdkRootPath!),
      config.platform,
    );
  }
  return null;
}

String _runnerTargetTriple(RunnerCompileConfig config) {
  switch (config.platform) {
    case 'ios':
      return '${config.arch}-apple-ios${config.minimumOsVersion}';
    case 'ios_sim':
      return '${config.arch}-apple-ios${config.minimumOsVersion}-simulator';
    case 'macos':
      return '${config.arch}-apple-macos${config.minimumOsVersion}';
    default:
      throw StateError('Unreachable');
  }
}

List<String> _buildSwiftcArgs(
  RunnerCompileConfig config,
  Directory? resolvedSdkDir,
  List<Directory> resolvedFrameworkDirs,
  List<String> linkedFrameworkNames,
  List<String> sdkFrameworks,
  List<String> sdkDylibs,
) {
  final swiftcArgs = <String>[
    '-target',
    _runnerTargetTriple(config),
    if (resolvedSdkDir != null) ...['-sdk', resolvedSdkDir.path],
    '-Xlinker',
    '-rpath',
    '-Xlinker',
    '@executable_path/Frameworks',
    if (config.platform == 'macos') ...[
      '-Xlinker',
      '-rpath',
      '-Xlinker',
      '@executable_path/../Frameworks',
    ],
  ];

  final seenFwParents = <String>{};
  for (final fwDir in resolvedFrameworkDirs) {
    final String parentPath = fwDir.parent.path;
    if (seenFwParents.add(parentPath)) {
      swiftcArgs.addAll(['-F', parentPath]);
    }
  }
  for (final fwName in linkedFrameworkNames) {
    swiftcArgs.addAll(['-framework', fwName]);
  }
  for (final sdkFw in sdkFrameworks) {
    swiftcArgs.addAll(['-framework', sdkFw]);
  }
  for (final dylib in sdkDylibs) {
    final String libArg = dylib.startsWith('lib') ? dylib.substring(3) : dylib;
    swiftcArgs.add('-l$libArg');
  }

  final seenHeaderDirs = <String>{};
  for (final String hdr in config.headerPaths) {
    final String dirPath = File(hdr).parent.path;
    if (seenHeaderDirs.add(dirPath)) {
      swiftcArgs.addAll(['-I', dirPath]);
    }
  }
  for (final String mm in config.modulemapPaths) {
    swiftcArgs.addAll(['-Xcc', '-fmodule-map-file=$mm']);
  }

  swiftcArgs.addAll([
    ...config.sourcePaths,
    '-emit-executable',
    '-o',
    config.outputPath,
  ]);
  return swiftcArgs;
}

void _runSwiftc(RunnerCompileConfig config, List<String> swiftcArgs) {
  File(config.outputPath).parent.createSync(recursive: true);
  final ProcessResult result = Process.runSync(
    config.swiftcPath!,
    swiftcArgs,
    environment: const {'PATH': '/usr/bin:/bin'},
    includeParentEnvironment: false,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      config.swiftcPath!,
      swiftcArgs,
      'swiftc failed (exit ${result.exitCode}):\n${result.stderr}',
      result.exitCode,
    );
  }
}

void _synthesizeRunnerBinary(
  RunnerCompileConfig config,
  Directory? resolvedSdkDir,
  List<String> linkedFrameworkNames,
  List<String> sdkFrameworks,
  List<String> sdkDylibs,
) {
  final metadataEntries = <String>[
    'app=${config.appName}',
    'platform=${config.platform}',
    'arch=${config.arch}',
    'sdk_available=${config.sdkAvailable}',
    if (resolvedSdkDir != null)
      'sdk=${resolvedSdkDir.uri.pathSegments.where((s) => s.isNotEmpty).last}',
    for (final src in config.sourcePaths)
      'source=${Uri.file(src).pathSegments.where((s) => s.isNotEmpty).last}',
    for (final hdr in config.headerPaths)
      'header=${Uri.file(hdr).pathSegments.where((s) => s.isNotEmpty).last}',
    for (final mm in config.modulemapPaths)
      'modulemap=${Uri.file(mm).pathSegments.where((s) => s.isNotEmpty).last}',
    for (final fw in linkedFrameworkNames) 'framework=$fw',
    for (final sdkFw in sdkFrameworks) 'sdk_framework=$sdkFw',
    for (final dylib in sdkDylibs) 'sdk_dylib=$dylib',
  ];

  final Uint8List machoBytes = generateStubExecutableMachO(
    StubRunnerSpec(
      platform: config.platform,
      arch: config.arch,
      minimumOsVersion: config.minimumOsVersion,
      linkedFrameworkNames: linkedFrameworkNames,
      sdkFrameworks: sdkFrameworks,
      sdkDylibs: sdkDylibs,
      metadataEntries: metadataEntries,
    ),
  );
  final outFile = File(config.outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(machoBytes);
}

/// Compiles or synthesizes a Mach-O `MH_EXECUTE` runner binary from
/// [RunnerCompileConfig].
void compileRunner(RunnerCompileConfig config) {
  _checkRunnerPlatform(config);
  _requireRunnerFilesExist(config.sourcePaths, 'source');
  _requireRunnerFilesExist(config.headerPaths, 'header');
  _requireRunnerFilesExist(config.modulemapPaths, 'modulemap');

  final ({List<Directory> dirs, List<String> names}) resolved =
      _resolveRunnerFrameworks(config);
  final List<String> sdkFrameworks = _dedupeNonEmpty(config.sdkFrameworks);
  final List<String> sdkDylibs = _dedupeNonEmpty(config.sdkDylibs);
  final Directory? resolvedSdkDir = _resolveRunnerSdkDir(config);

  if (config.sdkAvailable &&
      config.swiftcPath != null &&
      config.swiftcPath!.isNotEmpty) {
    _runSwiftc(
      config,
      _buildSwiftcArgs(
        config,
        resolvedSdkDir,
        resolved.dirs,
        resolved.names,
        sdkFrameworks,
        sdkDylibs,
      ),
    );
    return;
  }

  _synthesizeRunnerBinary(
    config,
    resolvedSdkDir,
    resolved.names,
    sdkFrameworks,
    sdkDylibs,
  );
}
