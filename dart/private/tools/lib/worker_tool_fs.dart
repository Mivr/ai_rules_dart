// Shared staged-source pruning and bounded-provider plumbing for the
// build-action runners under `dart/private/tools`.
//
// `analyzer_summary` and `format_runner` pruned the same orphaned files from
// the action's staged source tree and wrapped the analyzer in bounded
// `package:analyzer` resource providers with their own copy of each;
// `builder_shim` carries the same wrapper shape. This library holds the
// single copy. `analyzer_summary` and `format_runner` depend on the
// `worker_tool_fs` target below (alongside `worker_protocol`); `builder_shim`
// (in `dart/ext`) depends on it from `dart/ext/BUILD.bazel`.
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
  _deleteUnlisted(
    dirPath,
    allowedPaths,
    (entityPath) => p.normalize(entityPath),
    _ignoreDeleteFailure,
  );
}

/// Ignores a prune deletion failure: the entry was read-only or already
/// removed by a concurrent action.
void _ignoreDeleteFailure(String entryPath, FileSystemException e) {}

/// Deletes every non-directory entry under [dirPath] (recursively, without
/// following links) whose [keyOf] key is not in [allowed], routing deletion
/// failures to [onDeleteFailure]. Symlinked directories surface as links
/// (never as `Directory`), so the traversal neither descends through them
/// nor deletes their targets: deleting a link removes the link itself.
void _deleteUnlisted(
  String dirPath,
  Set<String> allowed,
  String Function(String entityPath) keyOf,
  void Function(String entryPath, FileSystemException e) onDeleteFailure,
) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return;
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) continue;
    final entryPath = entity.absolute.path;
    if (allowed.contains(keyOf(entryPath))) continue;
    try {
      entity.deleteSync();
    } on FileSystemException catch (e) {
      onDeleteFailure(entryPath, e);
    }
  }
}

/// Deletes every file or link under [stageDir] (recursively, without
/// following links) whose stage-relative path is not in [allowedEntries].
///
/// [stageDir] must be the action's own `<name>.pkg_roots` stage root: only
/// entries below it are ever touched, declared files (the allow-set) are
/// never deleted, and symlinked directories are removed as links without
/// descending into them or deleting their targets. A deletion failure throws
/// a [FileSystemException] naming the entry, so a stuck stale file fails the
/// action loudly instead of silently poisoning later builds.
void prunePkgRootsEntries(String stageDir, Set<String> allowedEntries) {
  final root = p.normalize(p.absolute(stageDir));
  final allowed = {
    for (final entry in allowedEntries)
      if (entry.trim().isNotEmpty) p.joinAll(entry.trim().split('/')),
  };
  _deleteUnlisted(
    root,
    allowed,
    (entityPath) => p.joinAll(p.split(p.relative(entityPath, from: root))),
    (entryPath, e) => throw FileSystemException(
      'Failed to prune stale staged file',
      entryPath,
      e.osError,
    ),
  );
}

/// Prunes the `<name>.pkg_roots` stage at [stageDir] down to the
/// stage-relative entries listed in the manifest at [manifestPath], one per
/// line. A null or empty [stageDir] or [manifestPath] prunes nothing, so
/// actions built before the manifest existed behave as before. A missing
/// manifest file throws a [FileSystemException] naming its path: the manifest
/// is a declared action input, so its absence means the build is
/// misconfigured, never a reason to skip pruning.
void prunePkgRootsFromManifest({String? stageDir, String? manifestPath}) {
  if (stageDir == null || stageDir.isEmpty) return;
  if (manifestPath == null || manifestPath.isEmpty) return;
  final manifest = File(manifestPath);
  if (!manifest.existsSync()) {
    throw FileSystemException(
      'pkg-roots manifest declared as an action input is missing',
      manifestPath,
    );
  }
  prunePkgRootsEntries(stageDir, {
    for (final line in manifest.readAsLinesSync()) line,
  });
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
