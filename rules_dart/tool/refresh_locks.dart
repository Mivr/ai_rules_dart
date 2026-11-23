/// Refreshes all lock files in the repository.
///
/// Usage: dart run tool/refresh_locks.dart
///
/// 1. Finds every directory containing a MODULE.bazel (excluding references/)
///    and runs `bazel mod tidy --lockfile_mode=refresh` in each, followed by
///    `bazel mod deps --lockfile_mode=update`, which evaluates every module
///    extension in the graph. `mod tidy` evaluates only the root module's
///    extensions, and a build evaluates only those its targets reach, so
///    neither alone records a dependency's extension (rules_dart's own
///    `ext_pub_deps`, say) in a workspace whose targets never use it. This
///    keeps MODULE.bazel formatting canonical and lock files complete.
///
/// 2. Finds every directory containing a pubspec.yaml (excluding references/,
///    dev/testdata/, and e2e/) and runs `dart pub get` with the pinned SDK
///    (`bazel run @rules_dart//dart`) to refresh the pubspec.lock file.
///
/// Uses only dart:io — no pubspec needed.
library;

import 'dart:io';

import 'refresh_locks_walk.dart';

Future<void> main() async {
  final root = _findRepoRoot();
  final workspaces = _findWorkspaces(root);

  stdout.writeln('Found ${workspaces.length} workspaces:');
  for (final ws in workspaces) {
    stdout.writeln('  ${relativePath(root, ws)}');
  }
  stdout.writeln('');

  var passed = 0;
  var failed = 0;

  for (final ws in workspaces) {
    final rel = relativePath(root, ws);
    stdout.write('Refreshing $rel ... ');

    // Step 1: bazel mod tidy --lockfile_mode=refresh
    // Formats MODULE.bazel and refreshes the lock file from the registry.
    final tidy = await Process.run(
      'bazel',
      ['mod', 'tidy', '--lockfile_mode=refresh'],
      workingDirectory: ws,
    );

    final expectedError = _expectedFailures[rel];
    bool failedAsExpected(ProcessResult r) =>
        expectedError != null && '${r.stderr}'.contains(expectedError);

    if (tidy.exitCode != 0 && !failedAsExpected(tidy)) {
      stdout.writeln('FAILED at mod tidy (exit ${tidy.exitCode})');
      stderr.writeln(tidy.stderr);
      failed++;
      continue;
    }

    // Step 2: bazel mod deps --lockfile_mode=update
    // Evaluates every extension in the graph, not just the root module's.
    final deps = await Process.run(
      'bazel',
      ['mod', 'deps', '--lockfile_mode=update'],
      workingDirectory: ws,
    );

    if (deps.exitCode == 0 || failedAsExpected(deps)) {
      stdout.writeln('ok');
      passed++;
    } else {
      stdout.writeln('FAILED at mod deps (exit ${deps.exitCode})');
      stderr.writeln(deps.stderr);
      failed++;
    }
  }

  // --- Phase 2: pubspec.lock files ---
  final pubPackages = _findPubPackages(root);

  if (pubPackages.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('Found ${pubPackages.length} Dart packages:');
    for (final pkg in pubPackages) {
      stdout.writeln('  ${relativePath(root, pkg)}');
    }
    stdout.writeln('');

    final flutterRoot = _flutterRoot();
    for (final pkg in pubPackages) {
      final rel = relativePath(root, pkg);
      stdout.write('Refreshing $rel pubspec.lock ... ');

      // The pinned SDK rather than the `dart` on PATH, which can be older than
      // a package's SDK floor. FLUTTER_ROOT lets that pub satisfy a Flutter
      // environment constraint (dart/ext's go_router_builder) without
      // resolving through the Dart that Flutter bundles.
      final result = await Process.run(
        'bazel',
        ['run', '@rules_dart//dart', '--', 'pub', 'get'],
        workingDirectory: pkg,
        environment: {'FLUTTER_ROOT': ?flutterRoot},
      );

      if (result.exitCode == 0) {
        stdout.writeln('ok');
        passed++;
      } else {
        stdout.writeln('FAILED (exit ${result.exitCode})');
        stderr.writeln(result.stdout);
        stderr.writeln(result.stderr);
        failed++;
      }
    }
  }

  stdout.writeln('');
  stdout.writeln('Done: $passed passed, $failed failed.');
  if (failed > 0) exit(1);
}

/// The Flutter SDK to report to pub: `FLUTTER_ROOT` if set, else the SDK the
/// `flutter` on PATH belongs to, else null.
String? _flutterRoot() {
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && env.isNotEmpty) return env;
  final separator = Platform.isWindows ? ';' : ':';
  for (final dir in (Platform.environment['PATH'] ?? '').split(separator)) {
    final flutter = File('$dir/flutter');
    if (flutter.existsSync()) {
      return File(flutter.resolveSymbolicLinksSync()).parent.parent.path;
    }
  }
  return null;
}

/// Walk up from the script's location to find the repo root (directory
/// containing MODULE.bazel at the top level).
String _findRepoRoot() {
  // Start from the directory containing this script, or fall back to cwd.
  var dir = Directory(Platform.script.toFilePath()).parent;

  // The script lives in tool/, so the repo root is one level up.
  // But also handle being run from the repo root via `dart run tool/...`.
  for (var i = 0; i < 10; i++) {
    if (File('${dir.path}/MODULE.bazel').existsSync() &&
        Directory('${dir.path}/dart').existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }

  // Fall back to cwd.
  return Directory.current.path;
}

/// Workspaces whose pub extension fails on purpose, with the error each must
/// fail with. Bazel still records every other extension before failing, so
/// the rest of their lock is refreshed like any other workspace's.
const _expectedFailures = {
  // Two lockfiles declare conflicting versions of the same package. The
  // `expected-failure` CI job asserts the resulting error message.
  'e2e/pub_lock_conflict': 'conflicting versions across lock files',
};

/// Workspaces that resolve only in a non-standalone context and cannot be
/// refreshed on their own.
const _skipWorkspaces = {
  // Nested submodule consumed only from the parent `pub_lock_cross_module`
  // workspace. Its MODULE.bazel declares `bazel_dep(rules_dart, 0.0.0)` with
  // no local_path_override, so standalone resolution can't find rules_dart.
  'e2e/pub_lock_cross_module/module_b',
  // Same: consumed only from the parent workspace. It names its pub hub
  // `deps_a`, the name the parent also uses, which is the collision the parent
  // fixture exists to cover.
  'e2e/pub_lock_cross_module/module_c',
};

/// Find all directories containing MODULE.bazel, excluding references/.
List<String> _findWorkspaces(String root) =>
    findMarkedDirs(root, workspaceQuery(_skipWorkspaces));

/// Find all directories containing pubspec.yaml, excluding references/,
/// dev/testdata/, and e2e/.
List<String> _findPubPackages(String root) =>
    findMarkedDirs(root, pubPackageQuery);
