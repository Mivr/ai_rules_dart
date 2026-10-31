// Validates and slices a whole analysis baseline for `dart_analysis_config` and
// the `dart_analyze` aspect.
//
// `dart_analysis_config` runs this with `--validate-only` so building a config
// with a malformed or missing baseline fails immediately naming the config
// label, the baseline file, and the offending entry. The `dart_analyze` aspect
// runs this once per target to slice the validated baseline down to that
// target's own files, keeping unrelated entries out of `DartAnalyze`'s key.
import 'dart:convert';
import 'dart:io';

import 'analysis_baseline.dart';
import 'cli_flags.dart';

/// Validates the baseline and writes either the normalized whole file or one
/// target's slice.
void main(List<String> args) {
  final parsed = _parseArgs(args);
  final baselineFile = File(parsed.baseline);
  if (!baselineFile.existsSync()) {
    stderr.writeln(
      'baseline_slice: ${parsed.config}: baseline `${parsed.baselineDisplay}`: '
      'missing baseline file',
    );
    exit(1);
  }
  final AnalysisBaseline baseline;
  try {
    baseline = AnalysisBaseline.parse(
      baselineFile.readAsStringSync(),
      source: parsed.baselineDisplay,
    );
  } on BaselineException catch (e) {
    stderr.writeln('baseline_slice: ${parsed.config}: $e');
    exit(1);
  }
  final output = parsed.validateOnly
      ? baseline.toJson()
      : baseline.sliceFor(parsed.files);
  File(parsed.out).writeAsStringSync('${jsonEncode(output)}\n');
}

/// Parsed `baseline_slice` command line.
typedef _SliceArgs = ({
  String config,
  String baseline,
  String baselineDisplay,
  String out,
  bool validateOnly,
  List<String> files,
});

/// Parses the command line, exiting 64 on an unknown or missing argument.
_SliceArgs _parseArgs(List<String> args) {
  const requiredSummary = '--config, --baseline, and --out are required';
  final flags = ToolFlags.parse(
    'baseline_slice',
    args,
    valueFlags: {'--config', '--baseline', '--baseline-display', '--out'},
    listFlags: {'--file'},
    boolFlags: {'--validate-only'},
  );
  final config = flags.require('--config', requiredSummary);
  final baseline = flags.require('--baseline', requiredSummary);
  final out = flags.require('--out', requiredSummary);
  return (
    config: config,
    baseline: baseline,
    baselineDisplay: flags.optional('--baseline-display') ?? baseline,
    out: out,
    validateOnly: flags.flag('--validate-only'),
    files: flags.values('--file'),
  );
}
