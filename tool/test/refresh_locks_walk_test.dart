/// Unit tests for `tool/refresh_locks_walk.dart`: the workspace and package
/// finders on a fixture tree, plus the relative-path helper.
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

void main() {
  _testWorkspaces();
  _testPubPackages();
  _testQueryHelpers();
  _testRelativePath();
  stdout.writeln('All refresh_locks_walk tests passed.');
}
