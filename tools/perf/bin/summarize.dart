/// Entrypoint binary for summarizing repeat results into `dart-sol.json`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:perf/result_writer.dart';

void main(List<String> args) {
  String? resultsDir;
  String? sha;
  var targetLoc = 500000;
  var seed = 1;
  var repeats = 3;
  String? out;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--results-dir=')) {
      resultsDir = arg.substring('--results-dir='.length);
    } else if (arg == '--results-dir' && i + 1 < args.length) {
      resultsDir = args[++i];
    } else if (arg.startsWith('--sha=')) {
      sha = arg.substring('--sha='.length);
    } else if (arg == '--sha' && i + 1 < args.length) {
      sha = args[++i];
    } else if (arg.startsWith('--target-loc=')) {
      targetLoc = int.parse(arg.substring('--target-loc='.length));
    } else if (arg == '--target-loc' && i + 1 < args.length) {
      targetLoc = int.parse(args[++i]);
    } else if (arg.startsWith('--seed=')) {
      seed = int.parse(arg.substring('--seed='.length));
    } else if (arg == '--seed' && i + 1 < args.length) {
      seed = int.parse(args[++i]);
    } else if (arg.startsWith('--repeats=')) {
      repeats = int.parse(arg.substring('--repeats='.length));
    } else if (arg == '--repeats' && i + 1 < args.length) {
      repeats = int.parse(args[++i]);
    } else if (arg.startsWith('--out=')) {
      out = arg.substring('--out='.length);
    } else if (arg == '--out' && i + 1 < args.length) {
      out = args[++i];
    }
  }

  if (resultsDir == null || sha == null || out == null) {
    stderr.writeln(
      'Usage: summarize --results-dir=<dir> --sha=<sha> --out=<dart-sol.json>',
    );
    exit(1);
  }

  final repeatResults = <RepeatResult>[];
  final dir = Directory(resultsDir);
  if (dir.existsSync()) {
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      if (file.path.endsWith('.json')) {
        try {
          final content = file.readAsStringSync();
          final decoded = jsonDecode(content) as Map<String, dynamic>;
          repeatResults.add(RepeatResult.fromJson(decoded));
        } catch (_) {
          // Ignore unparseable repeat files.
        }
      }
    }
  }

  final meta = SummaryMeta(
    rulesDartSha: sha,
    targetLoc: targetLoc,
    seed: seed,
    repeats: repeats,
  );
  final runner = RunnerInfo.detect();

  final jsonOut = formatDartSolJson(
    repeats: repeatResults,
    meta: meta,
    runner: runner,
  );

  File(out).writeAsStringSync(jsonOut);
  stdout.writeln('Summary written to $out');
}
