/// Entrypoint binary for running speed-of-light repeats.
library;

import 'dart:convert';
import 'dart:io';

import 'package:perf/cli_args.dart';
import 'package:perf/runner.dart';

void _runSingleRepeat({
  required String workspace,
  required int repeat,
  required String outPath,
  required String tempRoot,
}) {
  final result = executeRepeat(
    pristineWorkspace: workspace,
    repeatIndex: repeat,
    tempRoot: tempRoot,
  );
  final outFile = File(outPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync('${jsonEncode(result.toJson())}\n');
  stdout.writeln('Repeat $repeat finished, written to $outPath');
}

String _resolveSingleOutFile({
  required String? rawOut,
  required String? rawResultsDir,
  required int repeat,
}) {
  if (rawOut == null || rawOut.isEmpty) {
    final outDir = resolveCliPath(rawResultsDir!);
    Directory(outDir).createSync(recursive: true);
    return '$outDir/repeat-$repeat.json';
  }
  final resolvedOut = resolveCliPath(rawOut);
  if (Directory(resolvedOut).existsSync()) {
    return '$resolvedOut/repeat-$repeat.json';
  }
  return resolvedOut;
}

void _executeRunnerJob({
  required String workspace,
  required int repeat,
  required int? repeatsCount,
  required String? rawOut,
  required String? rawResultsDir,
}) {
  final tempRoot = Directory.systemTemp.createTempSync('rd_perf_').path;
  try {
    final singleJsonOut =
        repeatsCount == 1 &&
        rawResultsDir == null &&
        rawOut != null &&
        rawOut.endsWith('.json') &&
        !Directory(resolveCliPath(rawOut)).existsSync();
    if (repeatsCount != null && repeatsCount > 0 && !singleJsonOut) {
      final outDir = resolveCliPath((rawResultsDir ?? rawOut)!);
      Directory(outDir).createSync(recursive: true);
      for (var i = 1; i <= repeatsCount; i++) {
        _runSingleRepeat(
          workspace: workspace,
          repeat: i,
          outPath: '$outDir/repeat-$i.json',
          tempRoot: tempRoot,
        );
      }
      return;
    }
    final targetRepeat = repeatsCount == 1 ? 1 : repeat;
    final outPath = _resolveSingleOutFile(
      rawOut: rawOut,
      rawResultsDir: rawResultsDir,
      repeat: targetRepeat,
    );
    _runSingleRepeat(
      workspace: workspace,
      repeat: targetRepeat,
      outPath: outPath,
      tempRoot: tempRoot,
    );
  } finally {
    try {
      forceDeleteDirectorySync(Directory(tempRoot));
    } on FileSystemException catch (e) {
      stderr.writeln('Temp cleanup error: $e');
    } on ProcessException catch (e) {
      stderr.writeln('Error cleaning temp directory: $e');
    }
  }
}

void main(List<String> args) {
  final flags = parseCliFlags(args);
  final rawWorkspace = lastFlagValue(flags, const ['workspace', 'ws']);
  final repeat = intFlagValue(flags, const [
    'repeat',
    'repeat-index',
    'repeat_index',
  ], defaultValue: 1);
  final repeatsCount = intFlagValue(flags, const ['repeats']);
  final rawResultsDir = lastFlagValue(flags, const [
    'results-dir',
    'results_dir',
  ]);
  final rawOut = lastFlagValue(flags, const ['out', 'output']);

  if (rawWorkspace == null ||
      rawWorkspace.isEmpty ||
      repeat == null ||
      (rawOut == null && rawResultsDir == null)) {
    stderr.writeln(
      'Usage: runner --workspace=<ws> --repeat=<n> --out=<result.json>',
    );
    exit(1);
  }

  _executeRunnerJob(
    workspace: resolveCliPath(rawWorkspace),
    repeat: repeat,
    repeatsCount: repeatsCount,
    rawOut: rawOut,
    rawResultsDir: rawResultsDir,
  );
}
