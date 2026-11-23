/// File operations and the copy/assemble/fat subcommands.
///
/// Symlink-aware directory copies, the `copy-assets`,
/// `assemble-macos-framework`, `copy-files` and `fat` subcommands.

import 'dart:io';
import 'dart:typed_data';

import 'macho_cli.dart';
import 'macho_constants.dart' show mhMagic64;
import 'macho_framework.dart' show createFrameworkZipBytes;
import 'macho_fat.dart'
    show FatSlice, buildFatMachO, isFatMachO, isMachO32, isMachO64;
import 'macho_patch.dart' show PatchOptions, patchMachO;

/// Copies optional kernel/snapshot blobs into [destDirPath], skipping blanks.
void copySnapshotBlobs(
  String? kernelBlobPath,
  String? vmSnapshotPath,
  String? isolateSnapshotPath,
  String destDirPath,
) {
  if (kernelBlobPath != null && kernelBlobPath.isNotEmpty) {
    File(kernelBlobPath).copySync('$destDirPath/kernel_blob.bin');
  }
  if (vmSnapshotPath != null && vmSnapshotPath.isNotEmpty) {
    File(vmSnapshotPath).copySync('$destDirPath/vm_snapshot_data');
  }
  if (isolateSnapshotPath != null && isolateSnapshotPath.isNotEmpty) {
    File(
      isolateSnapshotPath,
    ).copySync('$destDirPath/isolate_snapshot_data');
  }
}

/// Copies [src] to [dst] recursively, dereferencing symlinks.
void copyDirDereferencingSync(Directory src, Directory dst) {
  dst.createSync(recursive: true);
  if (!src.existsSync()) return;
  final List<FileSystemEntity> children = src.listSync(followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in children) {
    final String name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final destPath = '${dst.path}/$name';
    if (entity is Link) {
      final String resolved = entity.resolveSymbolicLinksSync();
      if (FileSystemEntity.isDirectorySync(resolved)) {
        copyDirDereferencingSync(Directory(resolved), Directory(destPath));
      } else {
        File(resolved).copySync(destPath);
      }
    } else if (entity is Directory) {
      copyDirDereferencingSync(entity, Directory(destPath));
    } else if (entity is File) {
      entity.copySync(destPath);
    }
  }
}

/// Parsed `copy-assets` subcommand flags.
class _CopyAssetsArgs {
  new({
    required this.srcPath,
    required this.dstPath,
    required this.kernelBlobPath,
    required this.vmSnapshotPath,
    required this.isolateSnapshotPath,
  });

  final String? srcPath;
  final String? dstPath;
  final String? kernelBlobPath;
  final String? vmSnapshotPath;
  final String? isolateSnapshotPath;
}

/// Parses `copy-assets` flags; unknown flags fail usage.
_CopyAssetsArgs _parseCopyAssetsArgs(List<String> args) {
  String? srcPath;
  String? dstPath;
  String? kernelBlobPath;
  String? vmSnapshotPath;
  String? isolateSnapshotPath;
  final flags = FlagCursor(args);
  while (flags.moveNext()) {
    final String arg = flags.current;
    switch (arg) {
      case '--src':
        srcPath = flags.take('--src');
      case '--dst':
        dstPath = flags.take('--dst');
      case '--kernel-blob':
        kernelBlobPath = flags.take('--kernel-blob');
      case '--vm-snapshot-data':
        vmSnapshotPath = flags.take('--vm-snapshot-data');
      case '--isolate-snapshot-data':
        isolateSnapshotPath = flags.take('--isolate-snapshot-data');
      default:
        usageError('Unknown flag for copy-assets: $arg');
    }
  }
  return _CopyAssetsArgs(
    srcPath: srcPath,
    dstPath: dstPath,
    kernelBlobPath: kernelBlobPath,
    vmSnapshotPath: vmSnapshotPath,
    isolateSnapshotPath: isolateSnapshotPath,
  );
}

/// Runs the `copy-assets` subcommand: parses [args] and stages framework assets.
void runCopyAssets(List<String> args) {
  final _CopyAssetsArgs parsed = _parseCopyAssetsArgs(args);
  final String? srcPath = parsed.srcPath;
  final String? dstPath = parsed.dstPath;
  if (srcPath == null || dstPath == null) {
    usageError('copy-assets requires --src and --dst');
  }

  final dstDir = Directory(dstPath);
  copyDirDereferencingSync(Directory(srcPath), dstDir);
  copySnapshotBlobs(
    parsed.kernelBlobPath,
    parsed.vmSnapshotPath,
    parsed.isolateSnapshotPath,
    dstDir.path,
  );
}

/// Deletes [directory] and everything under it, if it exists.
///
/// A directory is removed recursively, including symlinks: the links are
/// deleted as links and never followed, so a stale link cannot reach a path
/// outside the staging tree. A file or link that sits where the directory
/// belongs is deleted too, so the caller always starts from an absent path.
void removeDirectoryTreeSync(Directory directory) {
  final FileSystemEntityType type = FileSystemEntity.typeSync(
    directory.path,
    followLinks: false,
  );
  if (type == FileSystemEntityType.notFound) {
    return;
  }
  if (type == FileSystemEntityType.directory) {
    directory.deleteSync(recursive: true);
    return;
  }
  if (type == FileSystemEntityType.link) {
    Link(directory.path).deleteSync();
    return;
  }
  File(directory.path).deleteSync();
}

/// Creates a symlink at [linkPath] pointing to [target], replacing any existing entry.
void createSymlinkReplacingSync(String linkPath, String target) {
  final link = Link(linkPath);
  if (FileSystemEntity.typeSync(linkPath, followLinks: false) !=
      FileSystemEntityType.notFound) {
    link.deleteSync();
  }
  link.createSync(target);
}

/// Parsed `assemble-macos-framework` subcommand flags.
class _AssembleArgs {
  new({
    required this.binaryPath,
    required this.infoPlistPath,
    required this.assetsPath,
    required this.outputDirPath,
    required this.outputZipPath,
    required this.kernelBlobPath,
    required this.vmSnapshotPath,
    required this.isolateSnapshotPath,
  });

  final String? binaryPath;
  final String? infoPlistPath;
  final String? assetsPath;
  final String? outputDirPath;
  final String? outputZipPath;
  final String? kernelBlobPath;
  final String? vmSnapshotPath;
  final String? isolateSnapshotPath;
}

/// Parses `assemble-macos-framework` flags; unknown flags fail usage.
_AssembleArgs _parseAssembleArgs(List<String> args) {
  String? binaryPath;
  String? infoPlistPath;
  String? assetsPath;
  String? outputDirPath;
  String? outputZipPath;
  String? kernelBlobPath;
  String? vmSnapshotPath;
  String? isolateSnapshotPath;
  final flags = FlagCursor(args);
  while (flags.moveNext()) {
    final String arg = flags.current;
    switch (arg) {
      case '--binary':
        binaryPath = flags.take('--binary');
      case '--info-plist':
        infoPlistPath = flags.take('--info-plist');
      case '--assets':
        assetsPath = flags.take('--assets');
      case '--output-dir':
        outputDirPath = flags.take('--output-dir');
      case '--output-zip':
        outputZipPath = flags.take('--output-zip');
      case '--kernel-blob':
        kernelBlobPath = flags.take('--kernel-blob');
      case '--vm-snapshot-data':
        vmSnapshotPath = flags.take('--vm-snapshot-data');
      case '--isolate-snapshot-data':
        isolateSnapshotPath = flags.take('--isolate-snapshot-data');
      default:
        usageError('Unknown flag for assemble-macos-framework: $arg');
    }
  }
  return _AssembleArgs(
    binaryPath: binaryPath,
    infoPlistPath: infoPlistPath,
    assetsPath: assetsPath,
    outputDirPath: outputDirPath,
    outputZipPath: outputZipPath,
    kernelBlobPath: kernelBlobPath,
    vmSnapshotPath: vmSnapshotPath,
    isolateSnapshotPath: isolateSnapshotPath,
  );
}

/// Runs the `assemble-macos-framework` subcommand: parses [args] and assembles the `.framework` directory.
void runAssembleMacosFramework(List<String> args) {
  final _AssembleArgs parsed = _parseAssembleArgs(args);
  final String? binaryPath = parsed.binaryPath;
  final String? infoPlistPath = parsed.infoPlistPath;
  final String? assetsPath = parsed.assetsPath;
  final String? outputDirPath = parsed.outputDirPath;
  if (binaryPath == null ||
      infoPlistPath == null ||
      assetsPath == null ||
      outputDirPath == null) {
    usageError(
      'assemble-macos-framework requires --binary, --info-plist, --assets, '
      'and --output-dir',
    );
  }

  final fwDir = outputDirPath.endsWith('.framework')
      ? Directory(outputDirPath)
      : Directory('$outputDirPath/App.framework');

  // The output directory is a staging directory, not a fresh sandbox: local
  // and standalone spawn strategies reuse it between runs. Clear the
  // framework tree first so the zip can only ever hold this run's inputs.
  removeDirectoryTreeSync(fwDir);
  final String fwDirName = fwDir.uri.pathSegments
      .where((s) => s.isNotEmpty)
      .last;
  final String fwName = fwDirName.substring(
    0,
    fwDirName.length - '.framework'.length,
  );
  final versionADir = Directory('${fwDir.path}/Versions/A');
  final resourcesDir = Directory('${versionADir.path}/Resources');
  final assetsDestDir = Directory('${resourcesDir.path}/flutter_assets');
  assetsDestDir.createSync(recursive: true);

  File(binaryPath).copySync('${versionADir.path}/$fwName');
  File(infoPlistPath).copySync('${resourcesDir.path}/Info.plist');
  copyDirDereferencingSync(Directory(assetsPath), assetsDestDir);
  copySnapshotBlobs(
    parsed.kernelBlobPath,
    parsed.vmSnapshotPath,
    parsed.isolateSnapshotPath,
    assetsDestDir.path,
  );

  createSymlinkReplacingSync('${fwDir.path}/Versions/Current', 'A');
  createSymlinkReplacingSync(
    '${fwDir.path}/$fwName',
    'Versions/Current/$fwName',
  );
  createSymlinkReplacingSync(
    '${fwDir.path}/Resources',
    'Versions/Current/Resources',
  );

  final String? outputZipPath = parsed.outputZipPath;
  if (outputZipPath != null && outputZipPath.isNotEmpty) {
    final Uint8List zipBytes = createFrameworkZipBytes(
      fwDir,
      archiveRootName: fwDirName,
      executableRelPaths: {'$fwDirName/Versions/A/$fwName'},
    );
    final zipFile = File(outputZipPath);
    zipFile.parent.createSync(recursive: true);
    zipFile.writeAsBytesSync(zipBytes);
  }
}

/// Parsed `copy-files` subcommand flags.
class _CopyFilesArgs {
  new({
    required this.outputDirPath,
    required this.platformName,
    required this.minOsStr,
    required this.sdkVersionStr,
    required this.arch,
    required this.allowNonMacho,
    required this.positional,
  });

  final String outputDirPath;
  final String? platformName;
  final String? minOsStr;
  final String? sdkVersionStr;
  final String? arch;
  final Set<String> allowNonMacho;
  final List<String> positional;
}

/// Parses `copy-files` flags; unknown flags fail usage.
_CopyFilesArgs _parseCopyFilesArgs(List<String> args) {
  String? outputDirPath;
  String? platformName;
  String? minOsStr;
  String? sdkVersionStr;
  String? arch;
  final allowNonMacho = <String>{};
  final positional = <String>[];
  final flags = FlagCursor(args);
  while (flags.moveNext()) {
    final String arg = flags.current;
    if (arg.startsWith('--allow-non-macho=')) {
      addCommaParts(
        allowNonMacho,
        arg.substring('--allow-non-macho='.length),
      );
    } else if (arg == '--output-dir') {
      outputDirPath = flags.take('--output-dir');
    } else if (arg == '--platform') {
      platformName = flags.take('--platform');
    } else if (arg == '--min-os') {
      minOsStr = flags.take('--min-os');
    } else if (arg == '--sdk-version') {
      sdkVersionStr = flags.take('--sdk-version');
    } else if (arg == '--arch') {
      arch = flags.take('--arch');
    } else if (arg == '--allow-non-macho') {
      final String? next = flags.peek();
      if (next == null || next.startsWith('--')) {
        usageError(
          '--allow-non-macho requires an explicit binary or framework name',
        );
      }
      addCommaParts(allowNonMacho, flags.take('--allow-non-macho'));
    } else if (arg.startsWith('--')) {
      usageError('Unknown flag for copy-files: $arg');
    } else {
      positional.add(arg);
    }
  }

  final checked = outputDirPath;
  if (checked == null) {
    usageError('copy-files requires --output-dir');
  }
  return _CopyFilesArgs(
    outputDirPath: checked,
    platformName: platformName,
    minOsStr: minOsStr,
    sdkVersionStr: sdkVersionStr,
    arch: arch,
    allowNonMacho: allowNonMacho,
    positional: positional,
  );
}

/// Runs the `copy-files` subcommand: parses [args] and stages signed files.
void runCopyFiles(List<String> args) {
  final _CopyFilesArgs parsed = _parseCopyFilesArgs(args);
  final ({int? minOs, int? platform, int? sdkVersion}) versions =
      parsePlatformVersions(
        parsed.platformName,
        parsed.minOsStr,
        parsed.sdkVersionStr,
      );

  Directory(parsed.outputDirPath).createSync(recursive: true);
  _stageCopyFilesEntries(
    parsed.positional,
    (
      outDirPath: parsed.outputDirPath,
      platform: versions.platform,
      minOs: versions.minOs,
      sdkVersion: versions.sdkVersion,
      arch: parsed.arch,
      allowNonMacho: parsed.allowNonMacho,
    ),
  );
}

/// Staging options shared by the `copy-files` entry walkers: destination and
/// patch settings applied to every entry. Grouped so the walkers stay small.
typedef _CopyFilesStaging = ({
  String outDirPath,
  int? platform,
  int? minOs,
  int? sdkVersion,
  String? arch,
  Set<String> allowNonMacho,
});

/// Stages each `copy-files` positional (a source path with an optional
/// explicit destination name) under [staging.outDirPath].
void _stageCopyFilesEntries(
  List<String> positional,
  _CopyFilesStaging staging,
) {
  var i = 0;
  while (i < positional.length) {
    final String srcPath = positional[i];
    final String destName;
    if (i + 1 < positional.length &&
        !positional[i + 1].contains('/') &&
        !positional[i + 1].contains(r'\')) {
      destName = positional[i + 1];
      i += 2;
    } else {
      destName = Uri.file(
        srcPath,
      ).pathSegments.where((s) => s.isNotEmpty).last;
      i += 1;
    }
    _stageCopyFilesEntry(srcPath, destName, staging);
  }
}

/// Stages one `copy-files` entry, patching Mach-O binaries when a platform
/// was requested and copying anything else verbatim.
void _stageCopyFilesEntry(
  String srcPath,
  String destName,
  _CopyFilesStaging staging,
) {
  final destPath = '${staging.outDirPath}/$destName';
  final int? platform = staging.platform;
  final int? minOs = staging.minOs;
  if (platform == null || minOs == null) {
    File(srcPath).copySync(destPath);
    return;
  }
  final Uint8List inputBytes = File(srcPath).readAsBytesSync();
  final bool isAllowed = isAllowedNonMacho(
    staging.allowNonMacho,
    inputPath: srcPath,
    outputPath: destName,
  );
  if (!isMachO64(inputBytes) && !isFatMachO(inputBytes)) {
    if (isAllowed) {
      File(destPath).writeAsBytesSync(inputBytes);
      return;
    }
    if (isMachO32(inputBytes)) {
      throw FormatException(
        'Input file "$srcPath" ("$destName") is an unsupported 32-bit '
        'Mach-O binary (0xfeedface). Only 64-bit Mach-O binaries are '
        'supported unless explicitly listed in allow_non_macho.',
      );
    }
    throw FormatException(
      'Input file "$srcPath" ("$destName") is a non-Mach-O file (not a '
      '64-bit or universal Mach-O binary). Only Mach-O binaries are '
      'permitted unless explicitly listed in allow_non_macho.',
    );
  }
  try {
    final Uint8List patched = patchMachO(
      inputBytes,
      PatchOptions(
        platform: platform,
        minOs: minOs,
        sdkVersion: staging.sdkVersion,
        arch: staging.arch,
      ),
    );
    File(destPath).writeAsBytesSync(patched);
  } on FormatException catch (e) {
    throw FormatException(
      'Input file "$srcPath" ("$destName"): ${e.message}',
    );
  }
}

/// Runs the `fat` subcommand: parses [args] and builds or thins a Fat binary.
void runFat(List<String> args) {
  String? outputPath;
  final slicePaths = <String>[];

  for (var i = 0; i < args.length; i++) {
    final String arg = args[i];
    if (arg == '--output') {
      if (++i >= args.length) usageError('--output requires a value');
      outputPath = args[i];
    } else if (arg.startsWith('--')) {
      usageError('Unknown flag for fat: $arg');
    } else {
      slicePaths.add(arg);
    }
  }

  if (outputPath == null || slicePaths.isEmpty) {
    usageError('fat requires --output and at least one input slice path');
  }

  final slices = <FatSlice>[
    for (final p in slicePaths) _fatSliceFromFile(p),
  ];

  final Uint8List out = buildFatMachO(slices);
  final outFile = File(outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(out);
}

/// The `ar` archive magic that starts a static library.
const _arMagic = '!<arch>\n';

/// Reads [path] as a thin Mach-O or a static `ar` archive and returns its slice.
///
/// An archive takes its CPU type from the first Mach-O object it holds, which
/// is how `lipo` builds a universal static library.
FatSlice _fatSliceFromFile(String path) {
  final Uint8List bytes = File(path).readAsBytesSync();
  if (isMachO64(bytes) || isMachO32(bytes)) {
    return _cpuSlice(bytes, 0);
  }
  final int? object = _firstArchiveObject(bytes);
  if (object == null) {
    throw FormatException(
      'Input slice "$path" is neither a thin Mach-O binary nor a static '
      'archive of Mach-O objects.',
    );
  }
  return _cpuSlice(bytes, object);
}

/// Builds a slice holding all of [bytes], typed by the Mach-O header at [offset].
FatSlice _cpuSlice(Uint8List bytes, int offset) {
  final bd = ByteData.sublistView(bytes);
  return FatSlice(
    cputype: bd.getUint32(offset + 4, Endian.little),
    cpusubtype: bd.getUint32(offset + 8, Endian.little),
    bytes: bytes,
  );
}

/// Returns the file offset of the first Mach-O object in an `ar` archive.
int? _firstArchiveObject(Uint8List bytes) {
  if (bytes.length < _arMagic.length ||
      String.fromCharCodes(bytes, 0, _arMagic.length) != _arMagic) {
    return null;
  }
  int pos = _arMagic.length;
  while (pos + 60 <= bytes.length) {
    final String name = String.fromCharCodes(bytes, pos, pos + 16).trim();
    final int? size = int.tryParse(
      String.fromCharCodes(bytes, pos + 48, pos + 58),
    );
    if (size == null) return null;
    int data = pos + 60;
    if (name.startsWith('#1/')) {
      data += int.tryParse(name.substring(3)) ?? 0;
    }
    if (data + 12 <= bytes.length &&
        ByteData.sublistView(bytes).getUint32(data, Endian.little) ==
            mhMagic64) {
      return data;
    }
    pos += 60 + size + (size.isOdd ? 1 : 0);
  }
  return null;
}
