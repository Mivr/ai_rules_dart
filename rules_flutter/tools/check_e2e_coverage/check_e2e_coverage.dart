/// Fails when an e2e module is in no CI workflow without a recorded reason,
/// or when a checked-in `e2e.yaml` does not parse (`loadE2eSpec`).
///
/// Run from the repo root with no arguments (CI runs it as a job step):
/// `bazel run //tools/check_e2e_coverage`.
///
/// A module is any directory holding a `MODULE.bazel`, at `e2e/*/` or one
/// level deeper (`e2e/_overlay_tests/*/`). A module counts as covered when a
/// workflow under `.github/workflows/` references its leaf name outside of
/// comments, either as `working-directory: e2e/<leaf>`, a `workspace: <leaf>`
/// matrix entry, a `WORKSPACES:` list token, or a
/// `bazel run //tools/e2e_runner` `--workspace=e2e/<leaf>` argument. Anything
/// else must appear in
/// [uncoveredReasons] with a one-line reason saying why it has no workflow.
/// A reason for a module that IS covered is also an error, so the table
/// cannot go stale: removing a module from every workflow without recording
/// why fails this check.
library;

import 'dart:io';

import 'coverage.dart';
import 'specs.dart';

void main() {
  // Locate the repo root. BUILD_WORKSPACE_DIRECTORY is set by `bazel run`.
  final String rootPath =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
      Directory.current.path;
  if (!File('$rootPath/MODULE.bazel').existsSync() ||
      !Directory('$rootPath/e2e').existsSync()) {
    stderr.writeln('error: run //tools/check_e2e_coverage from the repo root');
    exit(2);
  }
  final Set<String> modules = findE2eModules(
    Directory('$rootPath/e2e'),
    rootPath,
  );
  final Set<String> covered = findCoveredModules(
    Directory('$rootPath/.github/workflows'),
  );
  final List<String> errors = [
    ...checkCoverage(
      modules: modules,
      covered: covered,
      reasons: uncoveredReasons,
    ),
    ...checkSpecs(Directory('$rootPath/e2e')),
  ];
  if (errors.isNotEmpty) {
    for (final error in errors) {
      stderr.writeln('error: $error');
    }
    exit(1);
  }
  final int coveredCount = modules
      .where((m) => covered.contains(leafName(m)))
      .length;
  print(
    'ok: $coveredCount e2e modules covered by workflows, '
    '${uncoveredReasons.length} with recorded reasons',
  );
}
