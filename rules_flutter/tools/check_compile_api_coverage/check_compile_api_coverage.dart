/// Fails when a `manual` compile-api negative target is not built by a CI
/// step that requires the refusal.
///
/// Run from the repo root with no arguments (CI runs it as a job step):
/// `bazel run //tools/check_compile_api_coverage`.
///
/// The targets come from `flutter/tests/compile_api_test.bzl`; the coverage
/// comes from the steps under `.github/workflows/`. The sibling
/// `_compile_api_build_negative` has no suffix and is not covered here: its
/// own step predates this check.
library;

import 'dart:io';

import 'coverage.dart';

const String _bzlPath = 'flutter/tests/compile_api_test.bzl';

void main() {
  // `bazel run` sets BUILD_WORKSPACE_DIRECTORY to the checkout.
  final String root =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
      Directory.current.path;
  final bzl = File('$root/$_bzlPath');
  final workflowsDir = Directory('$root/.github/workflows');
  if (!File('$root/MODULE.bazel').existsSync() ||
      !bzl.existsSync() ||
      !workflowsDir.existsSync()) {
    stderr.writeln(
      'error: run //tools/check_compile_api_coverage from the repo root',
    );
    exit(2);
  }
  final Set<String> targets = findNegativeTargets(bzl.readAsStringSync());
  final Map<String, String> workflows = _readWorkflows(workflowsDir);
  final List<String> errors = checkCompileApiCoverage(
    targets: targets,
    workflows: workflows,
  );
  if (errors.isNotEmpty) {
    errors.map((error) => 'error: $error').forEach(stderr.writeln);
    exit(1);
  }
  stdout.writeln(
    'ok: ${targets.length} compile-api negative targets have must-fail '
    'coverage in ${workflows.length} workflows',
  );
}

/// The `.yaml` and `.yml` files directly under [dir], by path.
Map<String, String> _readWorkflows(Directory dir) => {
  for (final file in dir.listSync(followLinks: false).whereType<File>())
    if (file.path.endsWith('.yaml') || file.path.endsWith('.yml'))
      file.path: file.readAsStringSync(),
};
