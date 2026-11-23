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
    'Usage: summarize --results-dir=<dir> --sha=<sha> --out=<dart-sol.json> '
    '[--on-results-dir=<dir> --on-out=<dart-sol-on.json> --ab-report=<md>]';

/// The run shape every `summarize` mode records in `meta`.
final class _RunArgs {
  const _RunArgs({
    required this.targetLoc,
    required this.seed,
    required this.repeats,
    required this.lockfile,
    required this.bazelFlags,
  });

  final int targetLoc;
  final int seed;
  final int repeats;
  final String? lockfile;
  final List<String> bazelFlags;
}

/// The second arm of an A/B summary: `--results-dir` is then the off arm.
final class _AbArgs {
  const _AbArgs({
    required this.onResultsDir,
    required this.onOut,
    required this.report,
  });

  final String onResultsDir;
  final String onOut;
  final String? report;
}

/// Validated `summarize` flags.
final class _SummarizeArgs {
  const _SummarizeArgs({
    required this.resultsDir,
    required this.sha,
    required this.out,
    required this.run,
    this.ab,
  });

  final String resultsDir;
  final String sha;
  final String out;
  final _RunArgs run;
  final _AbArgs? ab;
}

/// Reads the A/B flags; `ok` is false when only one of the two paths is set.
({bool ok, _AbArgs? ab}) _parseAbArgs(Map<String, List<String>> flags) {
  final onDir = lastFlagValue(flags, const ['on-results-dir']);
  final onOut = lastFlagValue(flags, const ['on-out']);
  final report = lastFlagValue(flags, const ['ab-report']);
  final hasDir = onDir != null && onDir.isNotEmpty;
  final hasOut = onOut != null && onOut.isNotEmpty;
  if (hasDir != hasOut || (!hasDir && report != null)) {
    return (ok: false, ab: null);
  }
  if (!hasDir) return (ok: true, ab: null);
  return (
    ok: true,
    ab: _AbArgs(
      onResultsDir: onDir,
      onOut: onOut!,
      report: report != null && report.isNotEmpty ? report : null,
    ),
  );
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
  final abArgs = _parseAbArgs(flags);
  if (rawResultsDir == null ||
      rawResultsDir.isEmpty ||
      rawSha == null ||
      rawSha.isEmpty ||
      rawOut == null ||
      rawOut.isEmpty ||
      targetLoc == null ||
      seed == null ||
      repeats == null ||
      !abArgs.ok) {
    return null;
  }
  return _SummarizeArgs(
    resultsDir: rawResultsDir,
    sha: rawSha,
    out: rawOut,
    ab: abArgs.ab,
    run: _RunArgs(
      targetLoc: targetLoc,
      seed: seed,
      repeats: repeats,
      lockfile: lastFlagValue(flags, const ['lockfile']),
      bazelFlags: (flags['bazel-flag'] ?? const <String>[])
          .where((f) => f.isNotEmpty)
          .toList(),
    ),
  );
}

/// Writes one arm's `dart-sol.json` from [resultsDir] and returns its content.
String _writeSummary(_SummarizeArgs a, String resultsDir, String outPath) {
  final repeatResults = loadRepeatResults(
    resolveCliPath(resultsDir),
    excludeFilePath: outPath,
  );
  final lockfile = a.run.lockfile;
  final meta = SummaryMeta(
    rulesDartSha: _resolveCommitSha(a.sha),
    targetLoc: a.run.targetLoc,
    seed: a.run.seed,
    repeats: a.run.repeats,
    bazelFlags: a.run.bazelFlags,
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

/// Writes one arm's summary, prints its table and returns its failures.
List<String> _summarizeArm(
  _SummarizeArgs a,
  String label,
  (String, String) paths,
) {
  final (resultsDir, out) = paths;
  final jsonOut = _writeSummary(a, resultsDir, resolveCliPath(out));
  final decoded = jsonDecode(jsonOut) as Map<String, dynamic>;
  stdout.writeln(formatStepSummaryTable(decoded));
  return [
    for (final f in summaryFailures(decoded))
      '${label.isEmpty ? '' : '$label: '}$f',
  ];
}

/// Pairs the two arms' repeats, prints and saves the table, returns failures.
List<String> _summarizeAb(_SummarizeArgs a, _AbArgs ab) {
  List<RepeatResult> load(String dir, String out) => loadRepeatResults(
    resolveCliPath(dir),
    excludeFilePath: resolveCliPath(out),
  );
  final off = load(a.resultsDir, a.out);
  final on = load(ab.onResultsDir, ab.onOut);
  final table = formatAbTable(pairArms(off, on));
  stdout.writeln(table);
  final report = ab.report;
  if (report != null) {
    final file = File(resolveCliPath(report));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '### link_modules on/off (paired per repeat)\n\n$table',
    );
  }
  return abFailures(off, on);
}

/// Runs the `summarize` CLI and returns its exit code.
///
/// Refuses `--repeats` below 1 with exit code 1. Otherwise always writes the
/// full `dart-sol.json` first, then returns 1 if [summaryFailures] is non-empty.
/// With `--on-results-dir` it also summarizes the on arm and pairs the arms,
/// returning 1 when [abFailures] is non-empty.
int runSummarizeCli(List<String> args) {
  final parsed = _parseSummarizeArgs(args);
  if (parsed == null) {
    stderr.writeln(_usage);
    return 1;
  }
  if (parsed.run.repeats < 1) {
    stderr.writeln(
      '--repeats must be an integer >= 1, got ${parsed.run.repeats}\n$_usage',
    );
    return 1;
  }

  final ab = parsed.ab;
  final failures = _summarizeArm(parsed, ab == null ? '' : 'off arm', (
    parsed.resultsDir,
    parsed.out,
  ));
  if (ab != null) {
    failures.addAll(
      _summarizeArm(parsed, 'on arm', (ab.onResultsDir, ab.onOut)),
    );
    failures.addAll(_summarizeAb(parsed, ab));
  }
  for (final failure in failures) {
    stderr.writeln('FAIL: $failure');
  }
  return failures.isEmpty ? 0 : 1;
}
