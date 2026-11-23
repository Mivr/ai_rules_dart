/// `check_e2e_coverage`: fails when an e2e workspace has no CI job running
/// it, or when a workflow references an `e2e/<name>` directory with no module.
///
/// Run from the tools module:
///   bazel run //check_e2e_coverage:check_e2e_coverage
library;

import 'dart:io';

import 'package:check_e2e_coverage/coverage.dart';

List<String> _workflowFiles(String repoRoot) {
  final dir = Directory('$repoRoot/.github/workflows');
  if (!dir.existsSync()) return const [];
  return dir
      .listSync(followLinks: false)
      .whereType<File>()
      .where((f) => f.path.endsWith('.yaml') || f.path.endsWith('.yml'))
      .map((f) => f.path)
      .toList();
}

String? _parseRepoArg(List<String> args) {
  String? cliRepo;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a.startsWith('--repo-root=')) {
      cliRepo = a.substring('--repo-root='.length);
    } else if (a.startsWith('--repo=')) {
      cliRepo = a.substring('--repo='.length);
    } else if ((a == '--repo-root' || a == '--repo') && i + 1 < args.length) {
      cliRepo = args[i + 1];
      i++;
    } else if (!a.startsWith('-')) {
      cliRepo = a;
    }
  }
  return cliRepo;
}

void main(List<String> args) {
  final String repoRoot;
  try {
    final startDir =
        _parseRepoArg(args) ??
        Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
        Directory.current.path;
    repoRoot = resolveRepoRoot(startDir);
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exit(2);
  }
  final topLevel = topLevelModules(repoRoot);
  final nested = nestedModules(repoRoot);
  final references = <String>{};
  for (final file in _workflowFiles(repoRoot)) {
    final String text;
    try {
      text = File(file).readAsStringSync();
    } on FileSystemException catch (e) {
      stderr.writeln('cannot read workflow $file: ${e.message}');
      exit(2);
    }
    references.addAll(extractReferences(parseWorkflow(text)));
  }
  final failures = checkCoverage(
    repoRoot: repoRoot,
    topLevel: topLevel,
    nested: nested,
    references: references,
  );
  if (failures.isEmpty) {
    stdout.writeln(
      'e2e coverage OK: ${topLevel.length} workspace(s), '
      '${references.length} reference(s)',
    );
    exit(0);
  }
  failures.forEach(stderr.writeln);
  exit(1);
}
