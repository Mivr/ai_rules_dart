/// Unit tests for `tool/refresh_locks_walk.dart`: the workspace and package
/// finders on a fixture tree, the relative-path helper, and the symlink cases
/// (links out of the root, loop pairs, self links, in-root links, dangling
/// links and symlinked marker files) on fixture trees of their own.
///
/// Run with the pinned SDK (no VM, no Bazel, no pubspec needed):
///   dart run tool/test/refresh_locks_walk_test.dart
library;

import 'dart:io';

import '../refresh_locks_walk.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

bool _sameElements(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Creates `rel` (and its parents) under [root], writing [contents] for files.
String _touch(String root, String rel, [String contents = '']) {
  final path = '$root/$rel';
  File(path).parent.createSync(recursive: true);
  File(path).writeAsStringSync(contents);
  return path;
}

/// Creates a symbolic link `link` under [root] pointing at [target].
void _link(String root, String link, String target) {
  Link('$root/$link').createSync(target);
}

/// Fixture tree covering every exclusion of both queries.
String _fixture() {
  final root = Directory.systemTemp.createTempSync('locks_fixture').path;
  _touch(root, 'MODULE.bazel');
  _touch(root, 'a/MODULE.bazel');
  _touch(root, 'e2e/x/MODULE.bazel');
  _touch(root, 'skipme/MODULE.bazel');
  _touch(root, 'references/r/MODULE.bazel');
  _touch(root, '.git/g/MODULE.bazel');
  _touch(root, '.hidden/h/MODULE.bazel');
  _touch(root, 'bazel-out/o/MODULE.bazel');
  _touch(root, 'pkg/pubspec.yaml');
  _touch(root, 'pkg/MODULE.bazel');
  _touch(root, 'dev/testdata/t/pubspec.yaml');
  _touch(root, 'e2e/x/pubspec.yaml');
  _touch(root, 'references/r/pubspec.yaml');
  _touch(root, '.dart_tool/d/pubspec.yaml');
  return root;
}

void _testWorkspaces() {
  final root = _fixture();
  try {
    final found = findMarkedDirs(root, workspaceQuery({'skipme'}));
    _check(
      _sameElements(found, [
        root,
        '$root/a',
        '$root/e2e/x',
        '$root/pkg',
      ]),
      'workspaces: root first then alphabetical, got $found',
    );

    final unskipped = findMarkedDirs(root, workspaceQuery(const {}));
    _check(
      unskipped.contains('$root/skipme'),
      'workspaces: empty skip set keeps skipme, got $unskipped',
    );
  } finally {
    Directory(root).deleteSync(recursive: true);
  }
  stdout.writeln('ok workspaces');
}

void _testPubPackages() {
  final root = _fixture();
  try {
    final found = findMarkedDirs(root, pubPackageQuery);
    _check(
      _sameElements(found, ['$root/pkg']),
      'pub packages: only pkg, got $found',
    );
  } finally {
    Directory(root).deleteSync(recursive: true);
  }
  stdout.writeln('ok pub packages');
}

void _testQueryHelpers() {
  const query = FindQuery(
    markerFile: 'MODULE.bazel',
    prunedFragments: ['/references/'],
  );
  _check(query.prunes('/r/references/x'), 'prunes a fragment path');
  _check(!query.prunes('/r/other/x'), 'keeps a clean path');
  _check(!query.prunes('/r/references'), 'needs the full fragment');

  const rooted = FindQuery(
    markerFile: 'MODULE.bazel',
    prunedFragments: [],
    rootFirst: true,
  );
  _check(rooted.compare('/r', '/r', '/r/a') < 0, 'root sorts first');
  _check(rooted.compare('/r', '/r/a', '/r') > 0, 'root sorts first (b)');
  _check(rooted.compare('/r', '/r/b', '/r/a') > 0, 'then alphabetical');

  const plain = FindQuery(markerFile: 'x', prunedFragments: []);
  _check(plain.compare('/r', '/r/b', '/r/a') > 0, 'plain sort is alphabetical');
  _check(plain.skippedPaths.isEmpty, 'skip set defaults to empty');
  _check(!plain.rootFirst, 'rootFirst defaults to false');
  stdout.writeln('ok query helpers');
}

void _testRelativePath() {
  _check(relativePath('/r', '/r') == '.', 'root maps to dot');
  _check(relativePath('/r', '/r/a') == 'a', 'child is stripped');
  _check(relativePath('/r', '/r/a/b') == 'a/b', 'nested child is stripped');
  _check(relativePath('/r', '/other') == '/other', 'outside is untouched');
  stdout.writeln('ok relative path');
}

void _testLinkOutOfRoot() {
  final root = Directory.systemTemp.createTempSync('locks_link_out').path;
  final outside = Directory.systemTemp.createTempSync('locks_outside').path;
  try {
    _touch(root, 'MODULE.bazel');
    _touch(root, 'inner/MODULE.bazel');
    _touch(outside, 'MODULE.bazel');
    _touch(outside, 'sub/MODULE.bazel');
    _link(root, 'link_out', outside);
    final found = findMarkedDirs(root, workspaceQuery(const {}));
    _check(
      _sameElements(found, [root, '$root/inner']),
      'link out of root is not walked, got $found',
    );
  } finally {
    Directory(root).deleteSync(recursive: true);
    Directory(outside).deleteSync(recursive: true);
  }
  stdout.writeln('ok link out of root');
}

void _testLoopPair() {
  final root = Directory.systemTemp.createTempSync('locks_loop').path;
  try {
    _touch(root, 'MODULE.bazel');
    _touch(root, 'a_ws/MODULE.bazel');
    _touch(root, 'b_ws/MODULE.bazel');
    _link(root, 'a_ws/l', '../b_ws');
    _link(root, 'b_ws/l', '../a_ws');
    final found = findMarkedDirs(root, workspaceQuery(const {}));
    _check(
      _sameElements(found, [root, '$root/a_ws', '$root/b_ws']),
      'loop pair is walked once, got ${found.length} entries: $found',
    );
  } finally {
    Directory(root).deleteSync(recursive: true);
  }
  stdout.writeln('ok loop pair');
}

void _testSelfLink() {
  final root = Directory.systemTemp.createTempSync('locks_self').path;
  try {
    _touch(root, 'MODULE.bazel');
    _touch(root, 'ws/MODULE.bazel');
    _link(root, 'ws/self', '.');
    final found = findMarkedDirs(root, workspaceQuery(const {}));
    _check(
      _sameElements(found, [root, '$root/ws']),
      'self link is not walked, got $found',
    );
  } finally {
    Directory(root).deleteSync(recursive: true);
  }
  stdout.writeln('ok self link');
}

void _testLinkInsideRoot() {
  final root = Directory.systemTemp.createTempSync('locks_inroot').path;
  try {
    _touch(root, 'MODULE.bazel');
    _touch(root, 'real/MODULE.bazel');
    _link(root, 'link_to_real', 'real');
    final found = findMarkedDirs(root, workspaceQuery(const {}));
    _check(
      _sameElements(found, [root, '$root/real']),
      'link inside root adds no duplicate, got $found',
    );
  } finally {
    Directory(root).deleteSync(recursive: true);
  }
  stdout.writeln('ok link inside root');
}

void _testDanglingLink() {
  final root = Directory.systemTemp.createTempSync('locks_dangling').path;
  try {
    _touch(root, 'MODULE.bazel');
    _touch(root, 'ws/MODULE.bazel');
    _link(root, 'dangling', 'nowhere-target');
    final found = findMarkedDirs(root, workspaceQuery(const {}));
    _check(
      _sameElements(found, [root, '$root/ws']),
      'dangling link is not walked, got $found',
    );
  } finally {
    Directory(root).deleteSync(recursive: true);
  }
  stdout.writeln('ok dangling link');
}

void _testSymlinkedMarker() {
  final root = Directory.systemTemp.createTempSync('locks_marker').path;
  try {
    _touch(root, 'MODULE.bazel');
    _touch(root, 'realmod/MODULE.bazel');
    Directory('$root/viamarker').createSync();
    _link(root, 'viamarker/MODULE.bazel', '../realmod/MODULE.bazel');
    final found = findMarkedDirs(root, workspaceQuery(const {}));
    _check(
      _sameElements(found, [root, '$root/realmod', '$root/viamarker']),
      'symlinked marker still marks, got $found',
    );
  } finally {
    Directory(root).deleteSync(recursive: true);
  }
  stdout.writeln('ok symlinked marker');
}

void _testDeterministicOrder() {
  List<String> buildTree(List<String> names) {
    final root = Directory.systemTemp.createTempSync('locks_order').path;
    _touch(root, 'MODULE.bazel');
    for (final name in names) {
      _touch(root, '$name/MODULE.bazel');
    }
    return findMarkedDirs(root, workspaceQuery(const {}));
  }

  List<String> relativeToRoot(List<String> found) => [
    for (final path in found) path.substring(found[0].length),
  ];

  final first = buildTree(['aaa', 'mmm', 'zzz']);
  final second = buildTree(['zzz', 'mmm', 'aaa']);
  try {
    _check(
      _sameElements(relativeToRoot(first), ['', '/aaa', '/mmm', '/zzz']),
      'ordered result, got $first',
    );
    _check(
      _sameElements(relativeToRoot(first), relativeToRoot(second)),
      'order is stable whatever the listing order, got $first vs $second',
    );
  } finally {
    Directory(first[0]).deleteSync(recursive: true);
    Directory(second[0]).deleteSync(recursive: true);
  }
  stdout.writeln('ok deterministic order');
}

void main() {
  _testWorkspaces();
  _testPubPackages();
  _testQueryHelpers();
  _testRelativePath();
  _testLinkOutOfRoot();
  _testLoopPair();
  _testSelfLink();
  _testLinkInsideRoot();
  _testDanglingLink();
  _testSymlinkedMarker();
  _testDeterministicOrder();
  stdout.writeln('All refresh_locks_walk tests passed.');
}
