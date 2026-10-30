// Slices a whole analysis baseline down to one analyzed target's files.
//
// The `dart_analyze` aspect runs this once per target: its input is the whole
// baseline file, its output the target's own entries. The `DartAnalyze` action
// reads only the slice, so an edit to an entry for another target's file
// changes this action but not the analysis action's key.
import 'dart:convert';
import 'dart:io';

import 'analysis_baseline.dart';

void main(List<String> args) {
  final parsed = _parseArgs(args);
  final baselineFile = File(parsed.baseline);
  if (!baselineFile.existsSync()) {
    stderr.writeln(
      'baseline_slice: ${parsed.config}: ${parsed.baseline}: '
      'missing baseline file',
    );
    exit(1);
  }
  final AnalysisBaseline baseline;
  try {
    baseline = AnalysisBaseline.parse(
      baselineFile.readAsStringSync(),
      source: parsed.baseline,
    );
  } on BaselineException catch (e) {
    stderr.writeln('baseline_slice: ${parsed.config}: $e');
    exit(1);
  }
  final slice = baseline.sliceFor(parsed.files);
  File(parsed.out).writeAsStringSync('${jsonEncode(slice)}\n');
}

/// Parsed `baseline_slice` command line.
typedef _SliceArgs = ({
  String config,
  String baseline,
  String out,
  List<String> files,
});

/// Parses the command line, exiting 64 on an unknown or missing argument.
_SliceArgs _parseArgs(List<String> args) {
  String? config;
  String? baseline;
  String? out;
  final files = <String>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--config':
        config = args[++i];
      case '--baseline':
        baseline = args[++i];
      case '--out':
        out = args[++i];
      case '--file':
        files.add(args[++i]);
      default:
        stderr.writeln('baseline_slice: unknown argument ${args[i]}');
        exit(64);
    }
  }
  if (config == null || baseline == null || out == null) {
    stderr.writeln(
      'baseline_slice: --config, --baseline, and --out are required',
    );
    exit(64);
  }
  return (config: config, baseline: baseline, out: out, files: files);
}
