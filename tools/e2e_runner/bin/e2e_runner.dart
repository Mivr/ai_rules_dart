/// `e2e_runner`: runs one e2e workspace's `e2e.yaml` spec in an isolated
/// staged copy with its own Bazel output base.
///
/// Usage (from the tools module):
///   bazel run //e2e_runner:e2e_runner -- \
///       --workspace=../e2e/<name> --bazel=bazel
library;

import 'dart:io';

import 'package:e2e_runner/runner.dart';
import 'package:e2e_runner/spec.dart';
import 'package:e2e_runner/workspace.dart';

const String _usage =
    'Usage: e2e_runner --workspace=<path> [--bazel=<client>]\n'
    '  Also reads BIT_WORKSPACE_DIR and BIT_BAZEL_BINARY from the environment.';

String _unquote(String s) {
  final trimmed = s.trim();
  if ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
      (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}

String? _flagValue(List<String> args, String name) {
  final prefix = '--$name=';
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith(prefix)) {
      return _unquote(arg.substring(prefix.length));
    }
    if (arg == '--$name' && i + 1 < args.length) {
      return _unquote(args[i + 1]);
    }
  }
  return null;
}

String _resolveClient(String? bazelArg, String callerDir) {
  if (bazelArg == null || bazelArg.isEmpty) return 'bazel';
  if (bazelArg.contains('/') || bazelArg.contains(r'\')) {
    return normalizePath(absolutePath(bazelArg, base: callerDir));
  }
  return bazelArg;
}

void main(List<String> args) {
  final workspaceArg =
      _flagValue(args, 'workspace') ??
      Platform.environment['BIT_WORKSPACE_DIR'];
  final bazelArg =
      _flagValue(args, 'bazel') ?? Platform.environment['BIT_BAZEL_BINARY'];
  if (workspaceArg == null || workspaceArg.isEmpty) {
    stderr.writeln(_usage);
    exit(2);
  }
  final callerDir =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
      Directory.current.path;
  final workspaceDir = normalizePath(
    absolutePath(workspaceArg, base: callerDir),
  );
  final String repoRoot;
  try {
    repoRoot = resolveRepoRoot(workspaceDir);
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
  final specPath = '$workspaceDir/e2e.yaml';
  final String specText;
  try {
    specText = File(specPath).readAsStringSync();
  } on FileSystemException catch (e) {
    stderr.writeln('cannot read spec $specPath: ${e.message}');
    exit(1);
  }
  final Spec spec;
  try {
    spec = parseSpec(specText, specPath: specPath);
  } on SpecError catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
  final config = RunnerConfig(
    workspaceDir: workspaceDir,
    repoRoot: repoRoot,
    client: _resolveClient(bazelArg, callerDir),
    specPath: specPath,
    spec: spec,
  );
  exit(runSpec(config));
}
