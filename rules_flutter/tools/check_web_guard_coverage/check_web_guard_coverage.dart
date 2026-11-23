/// Fails when a web-guard hostile fixture is not built by a CI step that
/// requires the guard refusal and pins its message.
///
/// Run from the repo root with no arguments (CI runs it as a job step):
/// `bazel run //tools/check_web_guard_coverage`.
///
/// The fixtures come from `flutter/tests/web_test.bzl`; the coverage comes
/// from the steps under `.github/workflows/`. The clean control beside the
/// hostile fixtures stays a passing `build_test`, so this check never asks CI
/// to build it as a red path.
library;

import 'dart:io';

import 'coverage.dart';

void main() {
  // Locate the repo root. BUILD_WORKSPACE_DIRECTORY is set by `bazel run`.
  final String rootPath =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
      Directory.current.path;
  final source = File('$rootPath/flutter/tests/web_test.bzl');
  final workflowsDir = Directory('$rootPath/.github/workflows');
  if (!File('$rootPath/MODULE.bazel').existsSync() ||
      !source.existsSync() ||
      !workflowsDir.existsSync()) {
    stderr.writeln(
      'error: run //tools/check_web_guard_coverage from the repo root',
    );
    exit(2);
  }
  final Set<String> fixtures = findHostileFixtures(source.readAsStringSync());
  if (fixtures.isEmpty) {
    stderr.writeln(
      'error: found no _web_guard_hostile_* fixtures in ${source.path}; '
      'the coverage check would be vacuous',
    );
    exit(1);
  }
  final workflows = <String, String>{};
  for (final FileSystemEntity entity in workflowsDir.listSync(
    followLinks: false,
  )) {
    if (entity is! File ||
        (!entity.path.endsWith('.yaml') && !entity.path.endsWith('.yml'))) {
      continue;
    }
    workflows[entity.path] = entity.readAsStringSync();
  }
  final List<String> errors = checkWebGuardCoverage(
    fixtures: fixtures,
    workflows: workflows,
  );
  if (errors.isNotEmpty) {
    for (final error in errors) {
      stderr.writeln('error: $error');
    }
    exit(1);
  }
  print(
    'ok: ${fixtures.length} web-guard hostile fixtures have must-fail '
    'coverage in ${workflows.length} workflows',
  );
}
