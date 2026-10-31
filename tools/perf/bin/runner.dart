/// Entrypoint binary for running speed-of-light repeats.
library;

import 'dart:convert';
import 'dart:io';

import 'package:perf/runner.dart';

(String?, String?) _extractFlagAndValue(String arg, List<String> args, int i) {
  if (arg.startsWith('--')) {
    final eq = arg.indexOf('=');
    if (eq != -1) {
      return (arg.substring(2, eq), arg.substring(eq + 1));
    }
    final key = arg.substring(2);
    final val = i + 1 < args.length ? args[i + 1] : null;
    return (key, val);
  }
  return (null, null);
}

void main(List<String> args) {
  String? workspace;
  var repeat = 1;
  String? out;

  for (var i = 0; i < args.length; i++) {
    final (flag, val) = _extractFlagAndValue(args[i], args, i);
    if (flag == null) continue;
    if (val != null && !args[i].contains('=')) i++;

    switch (flag) {
      case 'workspace':
      case 'ws':
        workspace = val;
      case 'repeat':
      case 'repeat-index':
      case 'repeat_index':
        if (val != null) repeat = int.parse(val);
      case 'out':
      case 'output':
        out = val;
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

    final outFile = File(out);
    outFile.parent.createSync(recursive: true);
    outFile.writeAsStringSync('${jsonEncode(result.toJson())}\n');
    stdout.writeln('Repeat $repeat finished, written to $out');
  } finally {
    try {
      forceDeleteDirectorySync(Directory(tempRoot));
    } on FileSystemException catch (e) {
      stderr.writeln('Temp cleanup error: $e');
    } on Exception catch (e) {
      stderr.writeln('Error cleaning temp directory: $e');
    }
  }
}
