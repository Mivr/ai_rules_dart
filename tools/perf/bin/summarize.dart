/// Entrypoint binary for summarizing repeat results into `dart-sol.json`.
library;

import 'dart:io';

import 'package:perf/cli_args.dart';
import 'package:perf/result_writer.dart';

String _resolveCommitSha(String rawSha) {
  final trimmed = rawSha.trim();
  if (RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(trimmed)) {
    return trimmed.toLowerCase();
  }
  final resolvedDir = resolveCliPath(trimmed);
  if (Directory(resolvedDir).existsSync()) {
    try {
      final res = Process.runSync(
        'git',
        ['-C', resolvedDir, 'rev-parse', 'HEAD'],
        environment: cleanProcessEnvironment(),
        includeParentEnvironment: false,
      );
      if (res.exitCode == 0) {
        final sha = (res.stdout as String).trim();
        if (sha.isNotEmpty) return sha;
      }
    } on ProcessException catch (e) {
      stderr.writeln('git rev-parse failed for $resolvedDir: $e');
    }
  }
  return trimmed;
}

void main(List<String> args) {
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
  final rawLockfile = lastFlagValue(flags, const ['lockfile']);
  final rawOut = lastFlagValue(flags, const ['out', 'output']);
  final bazelFlags = (flags['bazel-flag'] ?? const <String>[])
      .where((f) => f.isNotEmpty)
      .toList();

  if (rawResultsDir == null ||
      rawResultsDir.isEmpty ||
      rawSha == null ||
      rawSha.isEmpty ||
      rawOut == null ||
      rawOut.isEmpty ||
      targetLoc == null ||
      seed == null ||
      repeats == null) {
    stderr.writeln(
      'Usage: summarize --results-dir=<dir> --sha=<sha> --out=<dart-sol.json>',
    );
    exit(1);
  }

  final resultsDir = resolveCliPath(rawResultsDir);
  final outPath = resolveCliPath(rawOut);
  final sha = _resolveCommitSha(rawSha);

  final repeatResults = loadRepeatResults(resultsDir, excludeFilePath: outPath);
  final meta = SummaryMeta(
    rulesDartSha: sha,
    targetLoc: targetLoc,
    seed: seed,
    repeats: repeats,
    bazelFlags: bazelFlags,
    lockfile: rawLockfile != null && rawLockfile.isNotEmpty
        ? rawLockfile
        : 'committed',
  );
  final runner = RunnerInfo.detect();

  final jsonOut = formatDartSolJson(
    repeats: repeatResults,
    meta: meta,
    runner: runner,
  );

  final outFile = File(outPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync(jsonOut);
  stdout.writeln('Summary written to $outPath');
}
