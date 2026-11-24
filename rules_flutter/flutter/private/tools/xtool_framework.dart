/// Framework and resource materialization for Apple bundles.
///
/// Resolves `--framework` inputs (`.framework` directories, `.xcframework`
/// bundles, Bazel tree-artifact wrappers, and `.framework.zip` archives via
/// `extractFrameworkZip` from `macho_framework.dart`) and copies resource and
/// additional-content specs into the assembled bundle.

import 'dart:io';

import 'macho_framework.dart' show extractFrameworkZip;

// ---------------------------------------------------------------------------
// Framework resolution & Bundle Assembly
// ---------------------------------------------------------------------------

/// Resolves a `--framework` argument into one or more `.framework` directories.
///
/// Accepts:
///   - A `.framework` directory directly (e.g. `foo/App.framework`).
///   - A `.xcframework` directory (e.g. `Flutter.xcframework`), selecting the
///     slice matching [platform] (`ios`, `ios_sim`, or `macos`).
///   - A wrapper directory containing `*.framework` or `*.xcframework` children
///     (such as a Bazel tree artifact output).
///
/// A `.framework.zip` archive is NOT accepted here: callers extract those
/// with [extractFrameworkArchive] first, since Bazel does not preserve
/// directory symlinks inside tree artifacts staged as action inputs and
/// `App.framework` travels between actions as its deterministic zip.
List<Directory> resolveFrameworkDirectories(String inputPath, String platform) {
  final dir = Directory(inputPath);
  if (!dir.existsSync()) {
    throw ArgumentError('Framework path does not exist: $inputPath');
  }

  if (inputPath.endsWith('.framework')) {
    return [dir];
  }

  if (inputPath.endsWith('.xcframework')) {
    return _resolveXcframeworkSlice(dir, platform);
  }

  // Wrapper directory: check immediate children for *.framework or *.xcframework.
  final results = <Directory>[];
  final List<FileSystemEntity> children = dir.listSync(followLinks: true)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final child in children) {
    if (child is Directory) {
      if (child.path.endsWith('.framework')) {
        results.add(child);
      } else if (child.path.endsWith('.xcframework')) {
        results.addAll(_resolveXcframeworkSlice(child, platform));
      }
    }
  }
  if (results.isEmpty) {
    throw ArgumentError(
      'No .framework or .xcframework found inside directory: $inputPath',
    );
  }
  return results;
}

/// Extracts a `.framework.zip` archive (the form `App.framework` travels in
/// between Bazel actions: Bazel does not preserve directory symlinks inside
/// tree artifacts when staging them as action inputs) into [scratchRoot] and
/// returns the extracted `.framework` directory.
///
/// Entry paths in the archive carry the `<Name>.framework/` prefix written by
/// the producer, so the extracted directory is
/// `<scratchRoot>/<archive-basename-minus-.zip>/<archive-basename-minus-.zip>/`.
/// Any previous extraction at that path is removed first so a re-run over a
/// reused scratch root can never see stale entries.
Directory extractFrameworkArchive(String zipPath, Directory scratchRoot) {
  final String zipBase = zipPath.split('/').where((s) => s.isNotEmpty).last;
  if (!zipBase.endsWith('.framework.zip')) {
    throw ArgumentError('Not a framework archive: $zipPath');
  }
  final String fwFileName = zipBase.substring(
    0,
    zipBase.length - '.zip'.length,
  );
  final scratch = Directory('${scratchRoot.path}/$fwFileName');
  if (scratch.existsSync()) {
    scratch.deleteSync(recursive: true);
  }
  scratch.createSync(recursive: true);
  extractFrameworkZip(File(zipPath).readAsBytesSync(), scratch);
  final extracted = Directory('${scratch.path}/$fwFileName');
  if (!extracted.existsSync()) {
    throw ArgumentError(
      'Framework archive $zipPath did not contain $fwFileName/.',
    );
  }
  return extracted;
}

List<Directory> _resolveXcframeworkSlice(
  Directory xcframeworkDir,
  String platform,
) {
  final List<Directory> sliceDirs =
      xcframeworkDir.listSync(followLinks: true).whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  bool matchesSlice(String sliceName) {
    final String lower = sliceName.toLowerCase();
    if (platform == 'ios') {
      return lower.startsWith('ios-') && !lower.contains('simulator');
    } else if (platform == 'ios_sim') {
      return lower.startsWith('ios-') && lower.contains('simulator');
    } else if (platform == 'macos') {
      return lower.startsWith('macos-');
    }
    return false;
  }

  for (final slice in sliceDirs) {
    final String sliceName = slice.uri.pathSegments
        .where((s) => s.isNotEmpty)
        .last;
    if (matchesSlice(sliceName)) {
      final List<Directory> frameworks =
          slice
              .listSync(followLinks: true)
              .whereType<Directory>()
              .where((d) => d.path.endsWith('.framework'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      if (frameworks.isNotEmpty) {
        return frameworks;
      }
    }
  }

  throw ArgumentError(
    'No matching slice for platform "$platform" in ${xcframeworkDir.path}',
  );
}

/// Copies the directory tree at [src] to [dst], recreating relative symbolic links.
/// Absolute links and links containing `..` are dereferenced when [dereferenceSymlinks] is set.
void copyDirectorySync(
  Directory src,
  Directory dst, {
  bool dereferenceSymlinks = false,
}) {
  dst.createSync(recursive: true);
  final List<FileSystemEntity> children = src.listSync(followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in children) {
    final String name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final destPath = '${dst.path}/$name';
    if (entity is Link) {
      final String target = entity.targetSync();
      final bool shouldDereference =
          dereferenceSymlinks ||
          target.startsWith('/') ||
          target.contains('..');
      if (shouldDereference) {
        final String resolved = entity.resolveSymbolicLinksSync();
        if (FileSystemEntity.isDirectorySync(resolved)) {
          copyDirectorySync(
            Directory(resolved),
            Directory(destPath),
            dereferenceSymlinks: dereferenceSymlinks,
          );
        } else {
          File(resolved).copySync(destPath);
        }
      } else {
        final existing = Link(destPath);
        if (existing.existsSync()) existing.deleteSync();
        existing.createSync(target);
      }
    } else if (entity is Directory) {
      copyDirectorySync(
        entity,
        Directory(destPath),
        dereferenceSymlinks: dereferenceSymlinks,
      );
    } else if (entity is File) {
      entity.copySync(destPath);
    }
  }
}

const List<String> _unsupportedIbtoolExtensions = ['.storyboard', '.xib'];
const List<String> _unsupportedActoolExtensions = [
  '.xcassets',
  '.appiconset',
  '.icon',
];

void _validateResourceNotRequiringXcodeTools(String pathOrSpec) {
  final String lower = pathOrSpec.toLowerCase();
  for (final String ext in _unsupportedIbtoolExtensions) {
    if (lower.endsWith(ext) ||
        lower.contains('$ext/') ||
        lower.contains('$ext=')) {
      throw ArgumentError(
        'Resource "$pathOrSpec" is an uncompiled Interface Builder source ($ext) '
        'which requires Xcode ibtool and has no hermetic implementation on the '
        'xtool backend.',
      );
    }
  }
  for (final String ext in _unsupportedActoolExtensions) {
    if (lower.endsWith(ext) ||
        lower.contains('$ext/') ||
        lower.contains('$ext=')) {
      throw ArgumentError(
        'Resource "$pathOrSpec" is an uncompiled asset catalog source ($ext) '
        'which requires Xcode actool and has no hermetic implementation on the '
        'xtool backend.',
      );
    }
  }
}

/// Copies a `src[=dest_rel]` resource [spec] into [destRoot], rejecting sources that need Xcode tools.
void copyResourceSpec(String spec, Directory destRoot) {
  _validateResourceNotRequiringXcodeTools(spec);
  final int eqIndex = spec.indexOf('=');
  final String srcPath;
  final String relDest;
  if (eqIndex != -1) {
    srcPath = spec.substring(0, eqIndex);
    relDest = spec.substring(eqIndex + 1);
  } else {
    srcPath = spec;
    relDest = Uri.file(srcPath).pathSegments.where((s) => s.isNotEmpty).last;
  }
  _validateResourceNotRequiringXcodeTools(srcPath);
  _validateResourceNotRequiringXcodeTools(relDest);

  final destPath = '${destRoot.path}/$relDest';
  if (FileSystemEntity.isDirectorySync(srcPath)) {
    copyDirectorySync(
      Directory(srcPath),
      Directory(destPath),
      dereferenceSymlinks: true,
    );
  } else if (FileSystemEntity.isFileSync(srcPath)) {
    File(destPath).parent.createSync(recursive: true);
    File(srcPath).copySync(destPath);
  } else {
    throw ArgumentError('Resource path does not exist: $srcPath');
  }
}

/// Copies a `<subdir>=<path>` additional-content [spec] into [contentsDir], recording executables in [executablePaths].
void copyAdditionalContentSpec(
  String spec,
  Directory contentsDir, {
  required String contentsRelPrefix,
  required Set<String> executablePaths,
}) {
  final int eqIndex = spec.indexOf('=');
  if (eqIndex <= 0 || eqIndex == spec.length - 1) {
    throw ArgumentError(
      'Invalid --additional-content spec "$spec": expected <subdir>=<path>.',
    );
  }
  final String subdir = spec.substring(0, eqIndex).trim();
  final String srcPath = spec.substring(eqIndex + 1);
  if (subdir.isEmpty ||
      subdir.startsWith('/') ||
      subdir.split('/').contains('..')) {
    throw ArgumentError(
      'Invalid additional_contents subdirectory "$subdir": must be a relative '
      'bundle subdirectory without "..".',
    );
  }
  _validateResourceNotRequiringXcodeTools(srcPath);

  final String srcName = Uri.file(srcPath).pathSegments
      .where((s) => s.isNotEmpty)
      .last;
  final destPath = '${contentsDir.path}/$subdir/$srcName';
  final relBase = '$contentsRelPrefix/$subdir/$srcName';

  if (FileSystemEntity.isDirectorySync(srcPath)) {
    // Bazel tree-artifact wrapper directories (named after their target without
    // a bundle extension like .framework/.bundle/.appex/.xpc) expand their
    // contents directly into the destination subdirectory, matching
    // rules_apple's additional_contents semantics.
    final bool isBundleDir = srcName.contains('.');
    final targetDir = isBundleDir
        ? Directory('${contentsDir.path}/$subdir/$srcName')
        : Directory('${contentsDir.path}/$subdir');
    final targetRelPrefix = isBundleDir
        ? '$contentsRelPrefix/$subdir/$srcName'
        : '$contentsRelPrefix/$subdir';
    copyDirectorySync(
      Directory(srcPath),
      targetDir,
      dereferenceSymlinks: false,
    );
    markDirectoryExecutables(
      targetDir,
      targetRelPrefix,
      subdir: subdir,
      executablePaths: executablePaths,
    );
  } else if (FileSystemEntity.isFileSync(srcPath)) {
    File(destPath).parent.createSync(recursive: true);
    File(srcPath).copySync(destPath);
    if (srcName.endsWith('.dylib') ||
        srcName.endsWith('.so') ||
        subdir == 'MacOS' ||
        subdir == 'Frameworks') {
      executablePaths.add(relBase);
    }
  } else {
    throw ArgumentError('Additional content path does not exist: $srcPath');
  }
}

/// Records framework binaries and dynamic libraries under [dir] in [executablePaths] so they keep executable bits.
void markDirectoryExecutables(
  Directory dir,
  String relPrefix, {
  required String subdir,
  required Set<String> executablePaths,
}) {
  if (!dir.existsSync()) return;
  final String dirName = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
  if (dirName.endsWith('.framework')) {
    final String fwName = dirName.substring(
      0,
      dirName.length - '.framework'.length,
    );
    if (File('${dir.path}/$fwName').existsSync()) {
      executablePaths.add('$relPrefix/$fwName');
    }
    if (File('${dir.path}/Versions/A/$fwName').existsSync()) {
      executablePaths.add('$relPrefix/Versions/A/$fwName');
    }
    return;
  }
  for (final FileSystemEntity entity in dir.listSync(followLinks: false)) {
    final String name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (entity is Directory && name.endsWith('.framework')) {
      markDirectoryExecutables(
        entity,
        '$relPrefix/$name',
        subdir: subdir,
        executablePaths: executablePaths,
      );
    } else if (entity is File) {
      if (name.endsWith('.dylib') ||
          name.endsWith('.so') ||
          subdir == 'MacOS') {
        executablePaths.add('$relPrefix/$name');
      }
    }
  }
}
