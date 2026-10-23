// Shared staged-source pruning and bounded-provider plumbing for the
// build-action runners under `dart/private/tools`.
//
// `analyzer_summary` and `format_runner` pruned the same orphaned files from
// the action's staged source tree and wrapped the analyzer in bounded
// `package:analyzer` resource providers with their own copy of each;
// `builder_shim` carries the same wrapper shape. This library holds the
// single copy. `analyzer_summary` and `format_runner` depend on the
// `worker_protocol` target below; `builder_shim` (in `dart/ext`) depends on
// it from `dart/ext/BUILD.bazel`.
import 'dart:io';

import 'package:analyzer/file_system/file_system.dart' as fs;
import 'package:path/path.dart' as p;

/// Removes any orphaned symlinks or unlisted files under `<project>/src/` left
/// behind in the shared execroot by previous incremental builds when
/// `.dart_tool/src_manifest.txt` is present, and under sibling `<name>.extpkgs/`
/// when `.dart_tool/extpkgs_manifest.txt` is present. Returns the set of
/// normalized absolute paths allowed under `<project>/src/` (or `null` when no
/// manifest is present). Never prunes without a manifest.
///
/// Named distinctly from the manifest-free `pruneOrphanedStagedFiles` in
/// `analyze_runner` and `fix_runner`, which prune a different tree shape.
Set<String>? pruneStagedSrcFiles(String project) {
  _pruneExtpkgs(project);

  final srcDir = Directory(p.join(project, 'src'));
  if (!srcDir.existsSync()) return null;

  final manifestFile = File(p.join(project, '.dart_tool', 'src_manifest.txt'));
  if (!manifestFile.existsSync()) return null;

  final lines = [
    for (final line in manifestFile.readAsLinesSync())
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (lines.contains('*')) return null;

  final allowedPaths = <String>{
    for (final line in lines)
      p.normalize(p.absolute(p.join(srcDir.path, line))),
  };
  pruneUnlistedUnder(srcDir.path, allowedPaths);
  return allowedPaths;
}

/// Deletes every file under [dirPath] (recursively) whose normalized absolute
/// path is not in [allowedPaths]. Directories themselves are left in place.
void pruneUnlistedUnder(String dirPath, Set<String> allowedPaths) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return;
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) continue;
    final normPath = p.normalize(entity.absolute.path);
    if (!allowedPaths.contains(normPath)) {
      try {
        entity.deleteSync();
      } on FileSystemException {
        // Ignore if read-only or already removed.
      }
    }
  }
}

void _pruneExtpkgs(String project) {
  final normProject = p.normalize(p.absolute(project));
  if (!normProject.endsWith('.proj')) return;
  final extDir = Directory(
    '${normProject.substring(0, normProject.length - '.proj'.length)}.extpkgs',
  );
  if (!extDir.existsSync()) return;
  final extManifest = File(
    p.join(normProject, '.dart_tool', 'extpkgs_manifest.txt'),
  );
  if (!extManifest.existsSync()) return;

  final allowedFiles = <String>{};
  final allowedDirs = <String>[];
  for (final raw in extManifest.readAsLinesSync()) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.endsWith('/')) {
      allowedDirs.add(p.normalize(p.absolute(p.join(extDir.path, trimmed))));
    } else {
      allowedFiles.add(p.normalize(p.absolute(p.join(extDir.path, trimmed))));
    }
  }
  for (final entity in extDir.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) continue;
    final normPath = p.normalize(entity.absolute.path);
    final inAllowedDir = allowedDirs.any((dir) => p.isWithin(dir, normPath));
    if (!inAllowedDir && !allowedFiles.contains(normPath)) {
      try {
        entity.deleteSync();
      } on FileSystemException {
        // Ignore if read-only or already removed.
      }
    }
  }
}

/// The pass-through `fs.Folder` members shared by the bounded staging
/// wrappers: path accessors, child resolution through [folderProvider], and
/// re-wrapping copies/watches through [wrapFolder]/[wrapFile].
///
/// The wrapper classes keep their own divergent members (existence checks,
/// `getChildren`, `contains`, `isOrContains`) and supply the delegate, the
/// provider, and the re-wrapping constructors.
mixin BoundedFolderForwards implements fs.Folder {
  /// The wrapped folder.
  fs.Folder get folderDelegate;

  /// The bounding provider, used to resolve and re-wrap children.
  fs.ResourceProvider get folderProvider;

  /// Re-wraps a folder in the wrapper type.
  fs.Folder wrapFolder(fs.Folder folder);

  /// Re-wraps a file in the wrapper type.
  fs.File wrapFile(fs.File file);

  @override
  String get path => folderDelegate.path;

  @override
  fs.ResourceProvider get provider => folderProvider;

  @override
  String get shortName => folderDelegate.shortName;

  @override
  fs.Folder get parent => isRoot ? this : wrapFolder(folderDelegate.parent);

  @override
  String canonicalizePath(String relPath) => folderProvider.pathContext
      .normalize(folderProvider.pathContext.join(path, relPath));

  @override
  fs.Folder copyTo(fs.Folder parentFolder) =>
      wrapFolder(folderDelegate.copyTo(parentFolder));

  @override
  void create() => folderDelegate.create();

  @override
  void delete() => folderDelegate.delete();

  @override
  fs.Resource getChild(String relPath) =>
      folderProvider.getResource(canonicalizePath(relPath));

  @override
  fs.File getChildAssumingFile(String relPath) => getFile(relPath);

  @override
  fs.Folder getChildAssumingFolder(String relPath) => getFolder(relPath);

  @override
  fs.File getFile(String relPath) =>
      folderProvider.getFile(canonicalizePath(relPath));

  @override
  fs.Folder getFolder(String relPath) =>
      folderProvider.getFolder(canonicalizePath(relPath));

  @override
  fs.Resource resolveSymbolicLinksSync() {
    final resolved = folderDelegate.resolveSymbolicLinksSync();
    if (resolved is fs.Folder) return wrapFolder(resolved);
    if (resolved is fs.File) return wrapFile(resolved);
    return resolved;
  }

  @override
  Uri toUri() => folderDelegate.toUri();

  @override
  fs.ResourceWatcher watch() => folderDelegate.watch();

  @override
  bool operator ==(Object other) => other is fs.Folder && path == other.path;

  @override
  int get hashCode => path.hashCode;
}

/// The pass-through `fs.File` members shared by the bounded staging
/// wrappers: path accessors, copies, and re-wrapped parents through
/// [wrapFolder]/[wrapFile].
///
/// The wrapper classes keep their own divergent members (existence, stat,
/// and read guards) and supply the delegate and the re-wrapping
/// constructors, plus a one-line `provider` getter for their own provider.
mixin BoundedFileForwards implements fs.File {
  /// The wrapped file.
  fs.File get fileDelegate;

  /// Re-wraps a folder in the wrapper type.
  fs.Folder wrapFolder(fs.Folder folder);

  /// Re-wraps a file in the wrapper type.
  fs.File wrapFile(fs.File file);

  @override
  String get path => fileDelegate.path;

  @override
  String get shortName => fileDelegate.shortName;

  @override
  fs.File copyTo(fs.Folder parentFolder) =>
      wrapFile(fileDelegate.copyTo(parentFolder));

  @override
  void delete() => fileDelegate.delete();

  @override
  bool isOrContains(String path) => fileDelegate.isOrContains(path);

  @override
  fs.Folder get parent => wrapFolder(fileDelegate.parent);

  @override
  fs.File renameSync(String newPath) =>
      wrapFile(fileDelegate.renameSync(newPath));

  @override
  fs.Resource resolveSymbolicLinksSync() {
    final resolved = fileDelegate.resolveSymbolicLinksSync();
    if (resolved is fs.File) return wrapFile(resolved);
    if (resolved is fs.Folder) return wrapFolder(resolved);
    return resolved;
  }

  @override
  Uri toUri() => fileDelegate.toUri();

  @override
  fs.ResourceWatcher watch() => fileDelegate.watch();

  @override
  void writeAsBytesSync(List<int> bytes) =>
      fileDelegate.writeAsBytesSync(bytes);

  @override
  void writeAsStringSync(String content) =>
      fileDelegate.writeAsStringSync(content);

  @override
  bool operator ==(Object other) => other is fs.File && path == other.path;

  @override
  int get hashCode => path.hashCode;
}
