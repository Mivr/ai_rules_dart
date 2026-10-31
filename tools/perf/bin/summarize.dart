/// Entrypoint binary for summarizing repeat results into `dart-sol.json`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:perf/result_writer.dart';

final class _SummarizeArgs {
  _SummarizeArgs({
    this.resultsDir,
    this.sha,
    this.targetLoc = 500000,
    this.seed = 1,
    this.repeats = 3,
    this.out,
  });

  final String? resultsDir;
  final String? sha;
  final int targetLoc;
  final int seed;
  final int repeats;
  final String? out;
}

_SummarizeArgs _parseArgs(List<String> args) {
  String? resultsDir;
  String? sha;
  var targetLoc = 500000;
  var seed = 1;
  var repeats = 3;
  String? out;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    final (flag, val) = _extractFlagAndValue(arg, args, i);
    if (flag == null) continue;
    if (val != null && !arg.contains('=')) i++;

    switch (flag) {
      case 'results-dir':
      case 'results_dir':
      case 'results':
        resultsDir = val;
      case 'sha':
      case 'head-ref':
      case 'head_ref':
      case 'rules-dart':
      case 'rules_dart':
        sha = val;
      case 'target-loc':
      case 'target_loc':
      case 'loc':
        if (val != null) targetLoc = int.parse(val);
      case 'seed':
        if (val != null) seed = int.parse(val);
      case 'repeats':
        if (val != null) repeats = int.parse(val);
      case 'out':
      case 'output':
        out = val;
    }
  }

  return _SummarizeArgs(
    resultsDir: resultsDir,
    sha: sha,
    targetLoc: targetLoc,
    seed: seed,
    repeats: repeats,
    out: out,
  );
}

(String?, String?) _extractFlagAndValue(
  String arg,
  List<String> args,
  int index,
) {
  if (arg.startsWith('--')) {
    final eq = arg.indexOf('=');
    if (eq != -1) {
      return (arg.substring(2, eq), arg.substring(eq + 1));
    }
    final key = arg.substring(2);
    final val = index + 1 < args.length ? args[index + 1] : null;
    return (key, val);
  }
  return (null, null);
}

List<RepeatResult> _loadRepeatResults(String resultsDir) {
  final repeatResults = <RepeatResult>[];
  final dir = Directory(resultsDir);
  if (!dir.existsSync()) return repeatResults;

  final files = dir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    if (!file.path.endsWith('.json')) continue;
    try {
      final content = file.readAsStringSync();
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      repeatResults.add(RepeatResult.fromJson(decoded));
    } on FormatException catch (e) {
      stderr.writeln('Malformed JSON in repeat file ${file.path}: $e');
    } on TypeError catch (e) {
      stderr.writeln('Invalid schema in repeat file ${file.path}: $e');
    } on FileSystemException catch (e) {
      stderr.writeln('Error loading repeat file ${file.path}: $e');
    }
  }
  return repeatResults;
}

void main(List<String> args) {
  final parsed = _parseArgs(args);

  if (parsed.resultsDir == null || parsed.sha == null || parsed.out == null) {
    stderr.writeln(
      'Usage: summarize --results-dir=<dir> --sha=<sha> --out=<dart-sol.json>',
    );
    exit(1);
  }

  var sha = parsed.sha!;
  if (Directory(sha).existsSync()) {
    final res = Process.runSync('git', ['-C', sha, 'rev-parse', 'HEAD']);
    if (res.exitCode == 0) {
      sha = (res.stdout as String).trim();
    }
  }

  final repeatResults = _loadRepeatResults(parsed.resultsDir!);
  final meta = SummaryMeta(
    rulesDartSha: sha,
    targetLoc: parsed.targetLoc,
    seed: parsed.seed,
    repeats: parsed.repeats,
  );
  final runner = RunnerInfo.detect();

  final jsonOut = formatDartSolJson(
    repeats: repeatResults,
    meta: meta,
    runner: runner,
  );

  final outFile = File(parsed.out!);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync(jsonOut);
  stdout.writeln('Summary written to ${parsed.out}');
}
