/// Command-line driver for `scale`: measures sizes, writes `dart-scale.json`.
library;

import 'dart:convert';
import 'dart:io';

import 'cli_args.dart';
import 'runner.dart';
import 'scale_measure.dart';
import 'scale_report.dart';

/// Measures every flow at a library count.
typedef SizeMeasurer = SizeMeasurements Function(int libraries);

/// Sizes measured when `--sizes` is absent: the baseline shape, then 1k, 5k.
const List<int> defaultScaleSizes = [32, 1000, 5000];

const String _usage =
    'Usage: scale --workspace-root=<dir with ws-<n>> --ceilings=<json> '
    '--out=<dart-scale.json> [--sizes=32,1000,5000] [--seed=<int>]';

/// Parses a comma-separated size list; null if any entry is not an int >= 2.
List<int>? parseScaleSizes(String? raw) {
  if (raw == null || raw.trim().isEmpty) return defaultScaleSizes;
  final sizes = raw.split(',').map((s) => int.tryParse(s.trim())).toList();
  if (sizes.any((s) => s == null || s < 2)) return null;
  final unique = sizes.cast<int>().toSet().toList()..sort();
  return unique;
}

/// Reads the flow -> exponent ceiling table.
Map<String, double> readCeilings(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('$path must hold a JSON object of flow ceilings');
  }
  return {for (final e in decoded.entries) e.key: (e.value as num).toDouble()};
}

/// Runs the `scale` CLI and returns its exit code.
///
/// [measurer] defaults to real Bazel measurements of the `ws-<n>` workspaces
/// under `--workspace-root`; tests pass a fake. The report is written before
/// the exit code is decided, so a failing run still leaves `--out` behind.
int runScaleCli(List<String> args, {SizeMeasurer? measurer}) {
  final flags = parseCliFlags(args);
  final sizes = parseScaleSizes(lastFlagValue(flags, const ['sizes']));
  final rawOut = lastFlagValue(flags, const ['out', 'output']);
  final rawCeilings = lastFlagValue(flags, const ['ceilings']);
  final rawRoot = lastFlagValue(flags, const ['workspace-root']);
  final seed = intFlagValue(flags, const ['seed'], defaultValue: 1);
  if (sizes == null ||
      seed == null ||
      rawOut == null ||
      rawOut.isEmpty ||
      rawCeilings == null ||
      rawCeilings.isEmpty ||
      (measurer == null && (rawRoot == null || rawRoot.isEmpty))) {
    stderr.writeln(_usage);
    return 1;
  }
  final outFile = File(resolveCliPath(rawOut));
  final tempRoot = Directory.systemTemp.createTempSync('rd_scale_').path;
  try {
    final measure =
        measurer ??
        ScaleMeasurer(
          workspaceRoot: resolveCliPath(rawRoot!),
          tempRoot: tempRoot,
          profileDir: outFile.parent.path,
        ).call;
    return _measureAndReport(
      sizes: sizes,
      seed: seed,
      measure: measure,
      ceilings: readCeilings(resolveCliPath(rawCeilings)),
      outFile: outFile,
    );
  } finally {
    forceDeleteDirectorySync(Directory(tempRoot));
  }
}

int _measureAndReport({
  required List<int> sizes,
  required int seed,
  required SizeMeasurer measure,
  required Map<String, double> ceilings,
  required File outFile,
}) {
  final bySize = <int, SizeMeasurements>{};
  for (final size in sizes) {
    stdout.writeln('Measuring $size libraries');
    bySize[size] = measure(size);
  }
  final outcome = buildScaleReport(
    bySize: bySize,
    ceilings: ceilings,
    seed: seed,
  );
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(outcome.report)}\n',
  );
  stdout.writeln('Report written to ${outFile.path}');
  for (final problem in outcome.problems) {
    stderr.writeln('scale: $problem');
  }
  return outcome.problems.isEmpty ? 0 : 1;
}
