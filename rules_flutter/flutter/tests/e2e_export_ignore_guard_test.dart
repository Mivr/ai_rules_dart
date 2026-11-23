/// Release-archive guard: every e2e workspace except e2e/smoke is ignored.
///
/// `.gitattributes` keeps development-only workspaces out of the release
/// archive, but names each `e2e/` workspace by hand. This test fails when an
/// e2e workspace (any directory under `e2e/` holding a `MODULE.bazel`) is
/// neither export-ignored nor `e2e/smoke` — the one workspace the archive
/// must keep (`.bcr/presubmit.yml` names it as `module_path`, resolved
/// inside the extracted archive). It also fails when `e2e/smoke` itself
/// stops shipping.
///
/// Like the download digest guard, this test discovers its inputs at
/// runtime from the workspace root (the test's own source file in `data`,
/// or `BUILD_WORKSPACE_DIRECTORY` when set) and is tagged `external`, so a
/// new workspace is checked with no other change and never hidden behind a
/// stale pass.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Whether [root] is the rules_flutter workspace root.
bool _looksLikeRoot(String root) =>
    Directory('$root/e2e').existsSync() &&
    File('$root/.gitattributes').existsSync();

/// Workspace root the test walks: `BUILD_WORKSPACE_DIRECTORY` when set,
/// otherwise the source file behind the test's own anchor in `data` (an
/// unsandboxed runfiles tree symlinks it into the source tree; the root is
/// the first ancestor that looks like the workspace). Null when neither
/// resolves, so the test fails loudly instead of scanning the wrong tree
/// or silently passing.
String? _workspaceRoot() {
  final String? fromEnv = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (fromEnv != null && fromEnv.isNotEmpty && _looksLikeRoot(fromEnv)) {
    return fromEnv;
  }
  final String? anchor = Platform.environment['GUARD_ROOT_ANCHOR'];
  final String? srcdir = Platform.environment['TEST_SRCDIR'];
  if (anchor != null && anchor.isNotEmpty && srcdir != null) {
    try {
      Directory dir = File(
        File('$srcdir/$anchor').resolveSymbolicLinksSync(),
      ).parent;
      for (var i = 0; i < 8; i++) {
        if (_looksLikeRoot(dir.path)) return dir.path;
        dir = dir.parent;
      }
    } on FileSystemException {
      // Fall through to the loud failure below.
    }
  }
  return null;
}

/// Last path segment of [path].
String _baseName(String path) => path.split(Platform.pathSeparator).last;

/// Lists [dir] without following links. Throws a [StateError] naming the
/// path and the OS error when it cannot be listed, so no directory is
/// silently dropped from the check.
List<FileSystemEntity> _listOrFail(Directory dir) {
  try {
    return dir.listSync(followLinks: false);
  } on FileSystemException catch (e) {
    throw StateError(
      'cannot list ${dir.path}: ${e.osError ?? e.message}',
    );
  }
}

/// Relative paths of every directory under `e2e/` holding a `MODULE.bazel`,
/// whether that module file is a regular file or a symlink. Symlinked
/// directories are not descended into. Throws when a directory cannot be
/// listed.
List<String> _findWorkspaces(String root) {
  final found = <String>[];
  final stack = <Directory>[Directory('$root/e2e')];
  while (stack.isNotEmpty) {
    final Directory current = stack.removeLast();
    var hasModule = false;
    final subdirs = <Directory>[];
    for (final FileSystemEntity child in _listOrFail(current)) {
      final String name = _baseName(child.path);
      if (child is Directory) {
        if (name != 'node_modules') subdirs.add(child);
      } else if ((child is File || child is Link) && name == 'MODULE.bazel') {
        hasModule = true;
      }
    }
    if (hasModule) {
      found.add(current.path.substring(root.length + 1));
    }
    stack.addAll(subdirs);
  }
  found.sort();
  return found;
}

/// Directories named by `/path/ export-ignore` lines in `.gitattributes`.
Set<String> _ignoredDirs(String root) {
  final ignored = <String>{};
  for (final String line in File('$root/.gitattributes').readAsLinesSync()) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final List<String> parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length != 2) continue;
    if (parts[1] != 'export-ignore') continue;
    String pattern = parts[0];
    if (!pattern.startsWith('/')) continue;
    pattern = pattern.substring(1);
    if (pattern.endsWith('/')) {
      pattern = pattern.substring(0, pattern.length - 1);
    }
    // A file pattern (no trailing slash originally, naming a file) cannot
    // cover a workspace directory; keep only directory patterns.
    if (!parts[0].endsWith('/')) continue;
    ignored.add(pattern);
  }
  return ignored;
}

/// Whether workspace [dir] ships in the archive: it is ignored when it or
/// any ancestor directory is export-ignored.
bool _isIgnored(String dir, Set<String> ignored) {
  var current = dir;
  while (current.isNotEmpty) {
    if (ignored.contains(current)) return true;
    final int slash = current.lastIndexOf('/');
    if (slash < 0) break;
    current = current.substring(0, slash);
  }
  return false;
}

void main() {
  final String? root = _workspaceRoot();
  if (root == null) {
    test('export-ignore guard discovers the workspace', () {
      fail(
        'BUILD_WORKSPACE_DIRECTORY does not point at the rules_flutter '
        'workspace; run this test unsandboxed (it is tagged no-sandbox) via '
        'bazel test //flutter/tests:e2e_export_ignore_guard_test',
      );
    });
    return;
  }

  test('every e2e workspace except e2e/smoke is export-ignored', () {
    final List<String> workspaces = _findWorkspaces(root);
    expect(
      workspaces,
      contains('e2e/smoke'),
      reason: 'the walk under e2e/ missed e2e/smoke itself',
    );
    final Set<String> ignored = _ignoredDirs(root);
    final problems = <String>[];
    for (final workspace in workspaces) {
      if (workspace == 'e2e/smoke') continue;
      if (!_isIgnored(workspace, ignored)) {
        problems.add(
          '$workspace: e2e workspace ships in the release archive; add '
          "'/$workspace/ export-ignore' to .gitattributes",
        );
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  group('fixtures', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('export_ignore_guard_');
      Directory('${tmp.path}/e2e').createSync();
      File('${tmp.path}/.gitattributes').writeAsStringSync('');
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('a workspace whose MODULE.bazel is a symlink is reported', () {
      final ws = Directory('${tmp.path}/e2e/linked');
      ws.createSync();
      File('${ws.path}/MODULE.bazel.real').writeAsStringSync('');
      try {
        Link('${ws.path}/MODULE.bazel').createSync('MODULE.bazel.real');
      } on FileSystemException catch (e) {
        fail('cannot create a symlink on ${Platform.operatingSystem}: $e');
      }
      final List<String> workspaces = _findWorkspaces(tmp.path);
      expect(workspaces, ['e2e/linked']);
      expect(_isIgnored(workspaces.single, _ignoredDirs(tmp.path)), isFalse);
    });

    test('a symlinked directory is not descended into', () {
      final real = Directory('${tmp.path}/real');
      real.createSync();
      File('${real.path}/MODULE.bazel').writeAsStringSync('');
      Link('${tmp.path}/e2e/loop').createSync(real.path);
      expect(_findWorkspaces(tmp.path), isEmpty);
    });

    test('a directory the walk cannot list fails naming it', () {
      Directory('${tmp.path}/e2e').deleteSync();
      File('${tmp.path}/e2e').writeAsStringSync('not a directory');
      expect(
        () => _findWorkspaces(tmp.path),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('cannot list ${tmp.path}/e2e'),
          ),
        ),
      );
    });
  });

  test('e2e/smoke still ships in the release archive', () {
    final Set<String> ignored = _ignoredDirs(root);
    expect(
      _isIgnored('e2e/smoke', ignored),
      isFalse,
      reason:
          'e2e/smoke is export-ignored but the BCR presubmit resolves '
          'it inside the release archive',
    );
  });
}
