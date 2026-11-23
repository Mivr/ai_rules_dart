/// Shared directory walk for `tool/refresh_locks.dart`.
///
/// Finding Bazel workspaces and pub packages prunes the tree the same way;
/// only the marker file and the exclusion sets differ. Both finders share
/// [findMarkedDirs] so the walk cannot drift between them.
///
/// Uses only dart:io — no pubspec needed.
library;

import 'dart:io';

/// What [findMarkedDirs] looks for: directories containing [markerFile].
///
/// A directory is pruned when its path contains one of [prunedFragments], and
/// a match is dropped when its repo-relative path is in [skippedPaths].
class FindQuery {
  const FindQuery({
    required this.markerFile,
    required this.prunedFragments,
    this.skippedPaths = const {},
    this.rootFirst = false,
  });

  /// Name of the file marking a directory, e.g. `MODULE.bazel`.
  final String markerFile;

  /// Path fragments pruning the walk, e.g. `/references/`.
  final List<String> prunedFragments;

  /// Repo-relative paths to drop, e.g. nested test-only workspaces.
  final Set<String> skippedPaths;

  /// Sort the repo root before every other match.
  final bool rootFirst;

  /// Whether [dirPath] is pruned from the walk.
  bool prunes(String dirPath) {
    for (final fragment in prunedFragments) {
      if (dirPath.contains(fragment)) return true;
    }
    return false;
  }

  /// Orders two matches: the root first when [rootFirst], then alphabetically.
  int compare(String root, String a, String b) {
    if (!rootFirst) return a.compareTo(b);
    if (a == root) return -1;
    if (b == root) return 1;
    return a.compareTo(b);
  }
}

/// Query matching Bazel workspaces: directories containing `MODULE.bazel`,
/// excluding `references/`. [skippedPaths] holds nested workspaces that
/// resolve only from a parent workspace.
FindQuery workspaceQuery(Set<String> skippedPaths) => FindQuery(
  markerFile: 'MODULE.bazel',
  prunedFragments: const ['/references/', '/.git', '/bazel-'],
  skippedPaths: skippedPaths,
  rootFirst: true,
);

/// Query matching Dart packages: directories containing `pubspec.yaml`,
/// excluding `references/`, `dev/testdata/` and `e2e/`.
const FindQuery pubPackageQuery = FindQuery(
  markerFile: 'pubspec.yaml',
  prunedFragments: [
    '/references/',
    '/dev/testdata/',
    '/e2e/',
    '/.git',
    '/bazel-',
    '/.dart_tool',
  ],
);

/// Finds every directory under [root] matching [query], in [query]'s order.
///
/// Symbolic links to directories are never descended into: a link pointing
/// outside [root], into a loop, at itself, at another directory inside [root],
/// or nowhere contributes no entries and raises nothing. A real directory that
/// a link also points at is still found once, by its real path. Every returned
/// path is inside [root] and appears exactly once, regardless of the order the
/// file system lists entries in. A marker file that is itself a symbolic link
/// still marks its directory.
List<String> findMarkedDirs(String root, FindQuery query) {
  final walk = _MarkedWalk(root, query);
  walk.collect(root);
  walk.found.sort((a, b) => query.compare(root, a, b));
  return walk.found;
}

/// Depth-first walk collecting the directories that hold a query's marker.
///
/// The [root], [query], [found] and [seen] values travel together through the
/// recursion, so they live in one object instead of a long parameter list.
final class _MarkedWalk {
  _MarkedWalk(this.root, this.query);

  /// The repository root the walk started from.
  final String root;

  /// What marker file, pruning and exclusions to apply.
  final FindQuery query;

  /// Matches in walk order; sorted by [findMarkedDirs] before returning.
  final List<String> found = [];

  /// Directories already visited, so each is processed exactly once.
  final Set<String> seen = {};

  /// Collects the marked directories under [dirPath] into [found].
  void collect(String dirPath) {
    if (!_isInsideRoot(root, dirPath)) return;
    if (!seen.add(dirPath)) return;
    if (query.prunes(dirPath)) return;
    if (query.skippedPaths.contains(relativePath(root, dirPath))) return;
    if (File('$dirPath/${query.markerFile}').existsSync()) {
      found.add(dirPath);
    }
    // With followLinks false a link to a directory lists as a Link, never as
    // a Directory, so links are neither descended into nor followed. The
    // explicit link check below keeps that true even if listing ever follows.
    for (final entity in Directory(dirPath).listSync(followLinks: false)) {
      if (entity is! Directory || !_isWalkable(entity)) continue;
      if (FileSystemEntity.isLinkSync(entity.path)) continue;
      collect(entity.path);
    }
  }
}

/// Whether [dir] is descended into: hidden and Bazel output directories, and
/// the `references/` mirror of read-only upstream copies, are never walked.
bool _isWalkable(Directory dir) {
  final name = dir.path.split('/').last;
  return !name.startsWith('.') &&
      !name.startsWith('bazel-') &&
      name != 'references';
}

/// Whether [path] is [root] itself or nested under it.
bool _isInsideRoot(String root, String path) {
  return path == root || path.startsWith('$root/');
}

/// Path of [path] relative to [root]: `.` for the root itself.
String relativePath(String root, String path) {
  if (path == root) return '.';
  if (path.startsWith('$root/')) return path.substring(root.length + 1);
  return path;
}
