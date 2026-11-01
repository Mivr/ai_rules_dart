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

void main(List<String> args) {
  final flags = parseCliFlags(args);
  final rawWorkspace = lastFlagValue(flags, const ['workspace', 'ws']);
  final plannedOutputs = resolveRunnerOutputs(flags);

  if (rawWorkspace == null || rawWorkspace.isEmpty || plannedOutputs.isEmpty) {
    stderr.writeln(
      'Usage: runner --workspace=<ws> --repeat=<n> --out=<result.json>',
    );
    exit(1);
  }

  final workspace = resolveCliPath(rawWorkspace);
  final tempRoot = Directory.systemTemp.createTempSync('rd_perf_').path;
  try {
    for (final (repeatIndex, outPath) in plannedOutputs) {
      _runSingleRepeat(
        workspace: workspace,
        repeat: repeatIndex,
        outPath: outPath,
        tempRoot: tempRoot,
      );
    }
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
