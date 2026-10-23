// Staged-project pruning shared by `analyze_runner` and `fix_runner`.
//
// Both runners operate on a staged `<name>.proj` tree: per-file symlinks under
// `src/` plus a sibling `<name>.extpkgs` tree, each described by a manifest in
// `.dart_tool`. Before analyzing or fixing, each runner deletes staged files
// the manifests no longer list (a stale symlink from an earlier build would
// otherwise widen the action's inputs). The traversals are one implementation;
// the runners spell allow-list paths differently, so each passes its
// [StagedPruneSpelling] and keeps its exact allow-list semantics.
import 'dart:io';

/// How one runner spells staged paths when pruning orphaned files.
///
/// `analyze_runner` keys its `src/` allow-list by `src/`-relative paths, while
/// `fix_runner` keys its `src/` entries project-relative as `src/<rel>`; both
/// key sibling `.extpkgs` entries `.extpkgs`-relative. Each function preserves
/// its runner's exact mapping.
typedef StagedPruneSpelling = ({
  /// Maps one `src_manifest.txt` line to the `src/` allow-list entry the
  /// caller compares `src/` entity paths against.
  String Function(String line) manifestSrcEntry,

  /// Maps one `extpkgs_manifest.txt` line to the `.extpkgs` allow-list entry
  /// the caller compares sibling entity paths against.
  String Function(String line) manifestExtEntry,

  /// Keys one entity below the `src/` directory for the `src/` allow-list.
  String Function(String root, String path) relativeSrcPath,

  /// Keys one entity below the sibling `.extpkgs` directory for the sibling
  /// allow-list.
  String Function(String root, String path) relativeExtPath,
});

/// Removes orphaned staged files under `<project>/src/` and its sibling
/// `<name>.extpkgs`, as listed by the manifests in `<project>/.dart_tool`.
///
/// Returns the allow-list of staged source paths the caller checks its inputs
/// against, or `null` when no file-level `src_manifest.txt` is present. Never
/// prunes without a manifest.
Set<String>? pruneStagedSrcTree(
  String project, {
  required StagedPruneSpelling spelling,
}) {
  pruneStagedExtpkgs(
    project,
    manifestEntry: spelling.manifestExtEntry,
    relativePath: spelling.relativeExtPath,
  );

  final srcDir = Directory('$project/src');
  if (!srcDir.existsSync()) return null;
  final manifestFile = File('$project/.dart_tool/src_manifest.txt');
  if (!manifestFile.existsSync()) return null;

  final lines = [
    for (final line in manifestFile.readAsLinesSync())
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (lines.contains('*')) return null;

  final allowed = <String>{
    for (final line in lines) spelling.manifestSrcEntry(line),
  };
  for (final entity in srcDir.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) continue;
    final rel = spelling.relativeSrcPath(srcDir.path, entity.path);
    if (!allowed.contains(rel)) {
      try {
        entity.deleteSync();
      } on FileSystemException {
        // Ignore if read-only or already removed.
      }
    }
  }
  return allowed;
}

/// Removes sibling `<name>.extpkgs` entries the extpkgs manifest does not list.
///
/// See [StagedPruneSpelling] for the spelling parameters. Does nothing unless
/// [project] names a `<name>.proj` tree with an `extpkgs_manifest.txt`.
void pruneStagedExtpkgs(
  String project, {
  required String Function(String line) manifestEntry,
  required String Function(String root, String path) relativePath,
}) {
  var normProject = project;
  while (normProject.length > 1 &&
      (normProject.endsWith('/') || normProject.endsWith(r'\'))) {
    normProject = normProject.substring(0, normProject.length - 1);
  }
  if (!normProject.endsWith('.proj')) return;
  final extDir = Directory(
    '${normProject.substring(0, normProject.length - '.proj'.length)}.extpkgs',
  );
  if (!extDir.existsSync()) return;
  final extManifest = File('$normProject/.dart_tool/extpkgs_manifest.txt');
  if (!extManifest.existsSync()) return;

  final allowedFiles = <String>{};
  final allowedDirPrefixes = <String>[];
  for (final raw in extManifest.readAsLinesSync()) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.endsWith('/')) {
      allowedDirPrefixes.add(manifestEntry(trimmed));
    } else {
      allowedFiles.add(manifestEntry(trimmed));
    }
  }
  final rootPath = extDir.path;
  for (final entity in extDir.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) continue;
    final rel = relativePath(rootPath, entity.path);
    final inAllowedDir = allowedDirPrefixes.any(rel.startsWith);
    if (!inAllowedDir && !allowedFiles.contains(rel)) {
      try {
        entity.deleteSync();
      } on FileSystemException {
        // Ignore if read-only or already removed.
      }
    }
  }
}
