/// Validates that every Maven install in the e2e workspaces is lock-pinned.
///
/// Run from the repo root with no arguments (CI runs it as a job step):
/// `bazel run //tools/check_maven_pins`.
library;

import 'dart:io';

import 'pins.dart';

/// CLI entry point for checking Maven lock files.
void main(List<String> args) {
  final String rootPath =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
      Directory.current.path;

  if (!File('$rootPath/MODULE.bazel').existsSync() ||
      !Directory('$rootPath/e2e').existsSync()) {
    stderr.writeln('error: run //tools/check_maven_pins from the repo root');
    exit(2);
  }

  final List<String> workspaces = args.isNotEmpty
      ? args
      : discoverMavenWorkspaces(rootPath);
  final List<String> errors = checkAllWorkspaces(
    rootPath: rootPath,
    workspaces: workspaces.isEmpty ? null : workspaces,
  );

  if (errors.isNotEmpty) {
    for (final error in errors) {
      stderr.writeln('error: $error');
    }
    exit(1);
  }

  stdout.writeln(
    'ok: ${countInstalls(rootPath, workspaces)} maven.install declarations '
    'in ${workspaces.length} workspaces have valid sha256-pinned locks',
  );
}
