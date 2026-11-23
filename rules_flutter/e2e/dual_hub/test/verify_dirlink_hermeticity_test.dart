/// Dirlink fetch hermeticity guard: a `flutter.pub` path-spoke fetch must
/// never write, create, or delete anything in the source tree when the
/// path package holds directory symlinks.
///
/// The `dirlink_plugin` fixture package's `android/` and `assets/` are
/// symlinks to `shared_android/` and `shared_assets/` elsewhere in this
/// workspace. A fetch that symlinks a directory instead of mirroring it
/// writes the spoke's generated `android/BUILD.bazel` through the link,
/// overwriting the sentinel in `shared_android/BUILD.bazel`.
///
/// The `data` dep on `@hub_a//:dirlink_plugin` forces the spoke to fetch
/// and load before this test runs: on a broken spoke the run fails there.
/// This test then pins the source tree itself: the links still links, the
/// sentinel still intact with no generated content beside it, and the
/// danger files present, so a deleted fixture fails loudly instead of
/// passing vacuously.
///
/// Like the repo's static guards, this test discovers its inputs at runtime
/// from the workspace root (found through `BUILD_WORKSPACE_DIRECTORY` when
/// set, else the test's own anchor in `data` resolved through the runfiles
/// library, hence no-sandbox), and is tagged `external` so Bazel re-runs it
/// on every invocation instead of replaying a cached pass after an
/// untracked source file changed.
library;

// This script's diagnostics are its product: it reports what it found in
// the source tree to the bazel test log, so `print` is its output channel
// rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Sentinel carried by `shared_android/BUILD.bazel`, the user-owned file a
/// write-through fetch overwrites.
const _sentinel = 'DIRLINK-USER-ANDROID-SENTINEL';

/// Whether [root] is the dual_hub workspace root.
bool _looksLikeRoot(String root) =>
    File('$root/MODULE.bazel').existsSync() &&
    File('$root/hub_a/dirlink_plugin/pubspec.yaml').existsSync();

/// Workspace root the test walks: `BUILD_WORKSPACE_DIRECTORY` when set,
/// otherwise the test's own anchor in `data` resolved through the runfiles
/// library (an unsandboxed runfiles tree symlinks it into the source tree;
/// the root is the first ancestor that looks like the workspace). Null when
/// neither resolves, so the test fails loudly instead of checking the wrong
/// tree or silently passing.
String? _workspaceRoot() {
  final fromEnv = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (fromEnv != null && fromEnv.isNotEmpty && _looksLikeRoot(fromEnv)) {
    return fromEnv;
  }
  final anchor = Platform.environment['GUARD_ROOT_ANCHOR'];
  if (anchor != null && anchor.isNotEmpty) {
    // Resolve the anchor through the runfiles library rather than
    // guessing paths: that works under both the Unix symlink tree and
    // the Windows manifest. An unresolvable anchor throws here, loudly,
    // instead of checking the wrong tree.
    final resolved = Runfiles.create().rlocation(anchor);
    try {
      var dir = File(File(resolved).resolveSymbolicLinksSync()).parent;
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

/// Whether [path] is itself a symlink (never following it).
bool _isLink(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  return type == FileSystemEntityType.link;
}

/// Any filesystem entity at [path]: file, directory, link, or dangling
/// link.
bool _entityExists(String path) {
  return FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
}

void main() {
  var failed = false;

  void check(bool cond, String ok, String fail) {
    if (cond) {
      print('OK: $ok');
    } else {
      stderr.writeln('FAIL: $fail');
      failed = true;
    }
  }

  final root = _workspaceRoot();
  if (root == null) {
    stderr.writeln(
      'FAIL: dual_hub workspace root not found: set '
      'BUILD_WORKSPACE_DIRECTORY or run unsandboxed with the test source '
      'in data',
    );
    exit(1);
  }

  const links = {
    'hub_a/dirlink_plugin/android': '../shared_android',
    'hub_a/dirlink_plugin/assets': '../shared_assets',
  };
  for (final entry in links.entries) {
    final path = '$root/${entry.key}';
    check(
      _isLink(path),
      '${entry.key} is still a symlink',
      '${entry.key} is no longer a symlink: the fetch replaced the '
          'directory link instead of mirroring through it',
    );
    if (_isLink(path)) {
      check(
        Link(path).targetSync() == entry.value,
        '${entry.key} still points at ${entry.value}',
        '${entry.key} points at ${Link(path).targetSync()}: the fetch '
            'retargeted the directory link',
      );
    }
  }

  final userBuild = File('$root/hub_a/shared_android/BUILD.bazel');
  check(
    userBuild.existsSync(),
    'hub_a/shared_android/BUILD.bazel exists',
    'fixture file missing: $userBuild',
  );
  if (userBuild.existsSync()) {
    final content = userBuild.readAsStringSync();
    check(
      content.contains(_sentinel),
      'hub_a/shared_android/BUILD.bazel keeps its sentinel',
      'hub_a/shared_android/BUILD.bazel lost its sentinel: the spoke fetch wrote '
          'its generated file through the symlinked android/ directory into '
          'the source tree',
    );
    check(
      !content.contains('kt_android_library'),
      'hub_a/shared_android/BUILD.bazel carries no generated library',
      'hub_a/shared_android/BUILD.bazel contains generated content: the spoke '
          'fetch wrote its android/BUILD.bazel into the source tree',
    );
  }

  final danger = [
    'hub_a/dirlink_plugin/pubspec.yaml',
    'hub_a/dirlink_plugin/lib/dirlink_plugin.dart',
    'hub_a/shared_android/settings.gradle',
    'hub_a/shared_android/src/main/kotlin/com/example/DirlinkPlugin.kt',
    'hub_a/shared_assets/any.txt',
    'hub_a/shared_assets/extra.txt',
    'hub_a/shared_assets/.keep',
  ];
  for (final rel in danger) {
    check(
      _entityExists('$root/$rel'),
      'fixture file present: $rel',
      'fixture danger file missing, checks are vacuous: $root/$rel',
    );
  }

  if (failed) {
    exit(1);
  }
}
