/// Entrypoint binary for running speed-of-light repeats.
library;

import 'dart:convert';
import 'dart:io';

import 'package:perf/runner.dart';

void main(List<String> args) {
  String? workspace;
  var repeat = 1;
  String? out;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--workspace=')) {
      workspace = arg.substring('--workspace='.length);
    } else if (arg == '--workspace' && i + 1 < args.length) {
      workspace = args[++i];
    } else if (arg.startsWith('--repeat=')) {
      repeat = int.parse(arg.substring('--repeat='.length));
    } else if (arg == '--repeat' && i + 1 < args.length) {
      repeat = int.parse(args[++i]);
    } else if (arg.startsWith('--out=')) {
      out = arg.substring('--out='.length);
    } else if (arg == '--out' && i + 1 < args.length) {
      out = args[++i];
    }
  }

  if (workspace == null || out == null) {
    stderr.writeln(
      'Usage: runner --workspace=<ws> --repeat=<n> --out=<result.json>',
    );
    exit(1);
  }

  final tempRoot = Directory.systemTemp.createTempSync('rd_perf_').path;
  try {
    final result = executeRepeat(
      pristineWorkspace: workspace,
      repeatIndex: repeat,
      tempRoot: tempRoot,
    );

    final jsonStr = jsonEncode(result.toJson());
    File(out).writeAsStringSync(jsonStr);
    stdout.writeln('Repeat $repeat finished, written to $out');
  } finally {
    try {
      Directory(tempRoot).deleteSync(recursive: true);
    } on FileSystemException catch (e) {
      stderr.writeln('Temp cleanup error: $e');
    } on Exception catch (e) {
      stderr.writeln('Error cleaning temp directory: $e');
    }
  }
}
