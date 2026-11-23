/// Pure checks over the directories Bazel leaves behind after `bazel fetch`.
///
/// A repository rule that returns `repo_metadata(reproducible = True)` has its
/// tree stored once in the repo contents cache, and every output base's
/// `external/<repo>` becomes a symlink to that entry. These checks take plain
/// paths, so they run on fake directory trees without Bazel or a network.
library;

import 'dart:io';

/// The fetched state of one repository under one output base.
typedef FetchedRepo = ({String outputBase, String repo});

/// The outcome of checking one cached repo: its problems and its cache entry.
typedef CachedCheck = ({List<String> problems, String? entry});

/// Where the fetched repo lives under its output base's `external/` directory.
String externalPath(FetchedRepo fetched) =>
    '${fetched.outputBase}/external/${fetched.repo}';

/// The `<hash>` directory of the repo contents cache that holds `entry`.
String cacheHashDir(String entry) => File(entry).parent.path;

/// Whether `target` is an absolute path on any host this repo supports.
bool isAbsoluteTarget(String target) =>
    target.startsWith('/') ||
    target.startsWith(r'\') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(target);

/// Whether the relative `target` of a link in `linkDirSegments` leaves the root.
///
/// `linkDirSegments` are the link's directory components below the repo root.
/// The target is resolved lexically, the way the kernel resolves a relative
/// link that sits in a real directory.
bool escapesRoot(List<String> linkDirSegments, String target) {
  final stack = List<String>.of(linkDirSegments);
  for (final String segment in target.split(RegExp(r'[\\/]'))) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (stack.isEmpty) return true;
      stack.removeLast();
    } else {
      stack.add(segment);
    }
  }
  return false;
}

/// Reports every symlink under `root` that is absolute or leaves [root].
///
/// Such a link would dangle or point into the host once the tree is shared
/// from the cache, so a repository holding one cannot be marked reproducible.
List<String> findUnsafeLinks(String root) {
  final problems = <String>[];
  final String base = root.endsWith('/')
      ? root.substring(0, root.length - 1)
      : root;
  for (final FileSystemEntity entity in Directory(base).listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! Link) continue;
    final String relative = entity.path.substring(base.length + 1);
    final String target = entity.targetSync();
    if (isAbsoluteTarget(target)) {
      problems.add('$relative -> $target (absolute symlink)');
      continue;
    }
    final List<String> segments = relative.split('/')..removeLast();
    if (escapesRoot(segments, target)) {
      problems.add('$relative -> $target (symlink leaves the repository)');
    }
  }
  return problems;
}

/// Checks that `fetched` is a symlink to a cache entry holding no bad links.
///
/// Returns the problems found (empty when the repo is cached correctly) and,
/// through `entry`, the cache entry the symlink resolves to.
CachedCheck checkCachedRepo(FetchedRepo fetched) {
  final String path = externalPath(fetched);
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.link) {
    return (
      problems: <String>['${fetched.repo}: $path is not a cache symlink'],
      entry: null,
    );
  }
  final String entry = Link(path).targetSync();
  final problems = <String>[];
  final int entries = Directory(cacheHashDir(entry))
      .listSync(followLinks: false)
      .where((FileSystemEntity e) => !e.path.endsWith('.recorded_inputs'))
      .length;
  if (entries != 1) {
    problems.add(
      '${fetched.repo}: cache directory ${cacheHashDir(entry)} holds '
      '$entries entries, expected exactly 1',
    );
  }
  for (final String bad in findUnsafeLinks(entry)) {
    problems.add('${fetched.repo}: $bad');
  }
  return (problems: problems, entry: entry);
}

/// Checks that `fetched` is a real directory, as an unmarked repo must be.
List<String> checkRealDirectory(FetchedRepo fetched) {
  final String path = externalPath(fetched);
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.directory) {
    return const <String>[];
  }
  return <String>[
    '${fetched.repo}: expected a real directory at $path (an unmarked repo)',
  ];
}
