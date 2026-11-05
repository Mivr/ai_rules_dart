/// Command-line driver for `summarize`: writes `dart-sol.json` and gates on it.
library;

import 'dart:convert';
import 'dart:io';

import 'cli_args.dart';
import 'result_writer.dart';

String? _gitRevParseIn(String repoDir, String revExpr) {
  if (!Directory(repoDir).existsSync()) return null;
  try {
    final res = Process.runSync(
      'git',
      ['-C', repoDir, 'rev-parse', '--verify', revExpr],
      environment: cleanProcessEnvironment(),
      includeParentEnvironment: false,
    );
    if (res.exitCode == 0) {
      final sha = (res.stdout as String).trim().toLowerCase();
      if (RegExp(r'^[0-9a-f]{40}$').hasMatch(sha)) return sha;
    }
  } on ProcessException catch (e) {
    stderr.writeln('git rev-parse failed for $repoDir: $e');
  }
  return null;
}

String _resolveCommitSha(String rawSha) {
  final trimmed = rawSha.trim();
  if (RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(trimmed)) {
    return trimmed.toLowerCase();
  }
  final resolvedDir = resolveCliPath(trimmed);
  final fromDir = _gitRevParseIn(resolvedDir, 'HEAD');
  if (fromDir != null) return fromDir;

  final ghWs = Platform.environment['GITHUB_WORKSPACE'];
  final candidateDirs = <String>[
    if (ghWs != null && ghWs.trim().isNotEmpty) '${ghWs.trim()}/rules-head',
    resolveCliPath('.'),
  ];
  for (final dir in candidateDirs) {
    final resolvedRef = _gitRevParseIn(dir, '$trimmed^{commit}');
    if (resolvedRef != null) return resolvedRef;
  }
  return trimmed;
}

const String _usage =
    'Usage: summarize --results-dir=<dir> --sha=<sha> --out=<dart-sol.json>';

/// Validated `summarize` flags.
final class _SummarizeArgs {
  const _SummarizeArgs({
    required this.resultsDir,
    required this.sha,
    required this.out,
    required this.targetLoc,
    required this.seed,
    required this.repeats,
    required this.lockfile,
    required this.bazelFlags,
  });

  final String resultsDir;
  final String sha;
  final String out;
  final int targetLoc;
  final int seed;
  final int repeats;
  final String? lockfile;
  final List<String> bazelFlags;
}

/// Parses [args], or returns `null` when a required flag is missing/invalid.
_SummarizeArgs? _parseSummarizeArgs(List<String> args) {
  final flags = parseCliFlags(args);
  final rawResultsDir = lastFlagValue(flags, const [
    'results-dir',
    'results_dir',
    'results',
  ]);
  final rawSha = lastFlagValue(flags, const [
    'sha',
    'head-ref',
    'head_ref',
    'rules-dart',
    'rules_dart',
    'rules-head',
    'rules_head',
  ]);
  final targetLoc = intFlagValue(flags, const [
    'target-loc',
    'target_loc',
    'loc',
  ], defaultValue: 500000);
  final seed = intFlagValue(flags, const ['seed'], defaultValue: 1);
  final repeats = intFlagValue(flags, const ['repeats'], defaultValue: 3);
  final rawOut = lastFlagValue(flags, const ['out', 'output']);
  if (rawResultsDir == null ||
      rawResultsDir.isEmpty ||
      rawSha == null ||
      rawSha.isEmpty ||
      rawOut == null ||
      rawOut.isEmpty ||
      targetLoc == null ||
      seed == null ||
      repeats == null) {
    return null;
  }
  return _SummarizeArgs(
    resultsDir: rawResultsDir,
    sha: rawSha,
    out: rawOut,
    targetLoc: targetLoc,
    seed: seed,
    repeats: repeats,
    lockfile: lastFlagValue(flags, const ['lockfile']),
    bazelFlags: (flags['bazel-flag'] ?? const <String>[])
        .where((f) => f.isNotEmpty)
        .toList(),
  );
}

/// Writes `dart-sol.json` for [a] and returns its content.
String _writeSummary(_SummarizeArgs a, String outPath) {
  final repeatResults = loadRepeatResults(
    resolveCliPath(a.resultsDir),
    excludeFilePath: outPath,
  );
  final lockfile = a.lockfile;
  final meta = SummaryMeta(
    rulesDartSha: _resolveCommitSha(a.sha),
    targetLoc: a.targetLoc,
    seed: a.seed,
    repeats: a.repeats,
    bazelFlags: a.bazelFlags,
    lockfile: lockfile != null && lockfile.isNotEmpty ? lockfile : 'committed',
  );
  final jsonOut = formatDartSolJson(
    repeats: repeatResults,
    meta: meta,
    runner: RunnerInfo.detect(),
  );
  final outFile = File(outPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync(jsonOut);
  stdout.writeln('Summary written to $outPath');
  return jsonOut;
}

/// Runs the `summarize` CLI and returns its exit code.
///
/// Refuses `--repeats` below 1 with exit code 1. Otherwise always writes the
/// full `dart-sol.json` first, then returns 1 if [summaryFailures] is non-empty.
int runSummarizeCli(List<String> args) {
  final parsed = _parseSummarizeArgs(args);
  if (parsed == null) {
    stderr.writeln(_usage);
    return 1;
  }
  if (parsed.repeats < 1) {
    stderr.writeln(
      '--repeats must be an integer >= 1, got ${parsed.repeats}\n$_usage',
    );
    return 1;
  }

  final jsonOut = _writeSummary(parsed, resolveCliPath(parsed.out));
  final failures = summaryFailures(jsonDecode(jsonOut) as Map<String, dynamic>);
  for (final failure in failures) {
    stderr.writeln('FAIL: $failure');
  }
  return failures.isEmpty ? 0 : 1;
}
