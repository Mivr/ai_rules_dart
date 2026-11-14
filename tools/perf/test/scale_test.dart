/// Tests for the growth fit, the scale report and the `scale` exit code.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:perf/growth_fit.dart';
import 'package:perf/scale_cli.dart';
import 'package:perf/scale_report.dart';
import 'package:runfiles/runfiles.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

void _expectArgumentError(void Function() action, String message) {
  try {
    action();
  } on ArgumentError {
    return;
  }
  throw StateError('FAIL: $message (expected ArgumentError)');
}

List<(int, double)> _power(double exponent, {double scale = 3}) => [
  for (final n in [32, 1000, 5000]) (n, scale * pow(n, exponent).toDouble()),
];

void _testFit() {
  _check(fitGrowthExponent(_power(1)) == 1.0, 'linear points fit 1.0');
  _check(fitGrowthExponent(_power(2)) == 2.0, 'quadratic points fit 2.0');
  _check(fitGrowthExponent(_power(0.5)) == 0.5, 'sqrt points fit 0.5');
  _check(
    fitGrowthExponent([(10, 5.0), (100, 5.0)]) == 0.0,
    'constant cost fits 0.0',
  );
  _expectArgumentError(() => fitGrowthExponent([(32, 1.0)]), 'one point');
  _expectArgumentError(() => fitGrowthExponent([]), 'no points');
  _expectArgumentError(
    () => fitGrowthExponent([(32, 1.0), (64, 0.0)]),
    'zero cost',
  );
  _expectArgumentError(
    () => fitGrowthExponent([(32, 1.0), (64, -2.0)]),
    'negative cost',
  );
  _expectArgumentError(
    () => fitGrowthExponent([(0, 1.0), (64, 2.0)]),
    'zero libraries',
  );
  _expectArgumentError(
    () => fitGrowthExponent([(32, 1.0), (64, double.nan)]),
    'NaN cost',
  );
  _expectArgumentError(
    () => fitGrowthExponent([(32, 1.0), (32, 2.0)]),
    'one distinct size',
  );
}

/// Measurements whose every metric is `base * libraries ^ exponent`.
FlowMeasurement _grown(int libraries, double exponent) {
  final v = 2 * pow(libraries, exponent).toDouble();
  return FlowMeasurement(
    cpuSeconds: v,
    wallSeconds: v,
    peakRssMb: v * 10,
    actionCount: v.ceil(),
    maxCommandLineBytes: v.ceil(),
  );
}

SizeMeasurements _fake(
  int libraries, {
  Map<String, double> exponents = const {},
}) => {
  for (final flow in scaleFlows)
    flow: _grown(libraries, exponents[flow] ?? 1.0),
};

const _sizes = [32, 1000, 5000];

Map<String, double> _ceilings([double value = 1.5]) => {
  for (final flow in scaleFlows) flow: value,
};

void _testReportContent() {
  final outcome = buildScaleReport(
    bySize: {for (final n in _sizes) n: _fake(n)},
    ceilings: _ceilings(),
    seed: 7,
  );
  _check(outcome.problems.isEmpty, 'healthy run: ${outcome.problems}');
  final flows = outcome.report['flows']! as Map<String, Object?>;
  _check(
    flows.keys.toList().toString() == scaleFlows.toString(),
    'report has every flow',
  );
  for (final flow in scaleFlows) {
    final entry = flows[flow]! as Map<String, Object?>;
    for (final section in ['metrics', 'cost_per_library']) {
      final bySection = entry[section]! as Map<String, Object?>;
      for (final metric in scaleMetrics) {
        final perSize = bySection[metric]! as Map<String, Object?>;
        _check(
          perSize.keys.toList().toString() == ['32', '1000', '5000'].toString(),
          '$flow $section $metric holds every size',
        );
      }
    }
    final exponents = entry['growth_exponent']! as Map<String, Object?>;
    _check(
      scaleMetrics.every((m) => exponents[m] != null),
      '$flow has a fitted exponent per metric',
    );
    final cpu = (entry['metrics']! as Map)['cpu_seconds'] as Map;
    _check(cpu['1000'] == _grown(1000, 1).cpuSeconds, 'cpu value recorded');
    final rss = (entry['metrics']! as Map)['peak_rss_mb'] as Map;
    _check(
      rss['1000'] == _grown(1000, 1).peakRssMb,
      'peak_rss_mb recorded per scale point beside cpu and wall',
    );
    _check(
      scaleMetrics.indexOf('peak_rss_mb') ==
          scaleMetrics.indexOf('wall_seconds') + 1,
      'peak_rss_mb follows wall_seconds',
    );
    final per = (entry['cost_per_library']! as Map)['cpu_seconds'] as Map;
    _check(
      (per['1000'] as double) == _grown(1000, 1).cpuSeconds / 1000,
      'cost per library is cost / libraries',
    );
  }
  _check(jsonDecode(jsonEncode(outcome.report)) is Map, 'report is valid JSON');
}

/// Runs `scale` with a fake measurer; returns (exit code, report or null).
(int, Map<String, dynamic>?) _runScale({
  required Map<String, double> ceilings,
  required SizeMeasurer measurer,
}) {
  final dir = Directory.systemTemp.createTempSync('rd_scale_test_');
  try {
    final ceilingFile = File('${dir.path}/ceilings.json')
      ..writeAsStringSync(jsonEncode(ceilings));
    final out = File('${dir.path}/out/dart-scale.json');
    final code = runScaleCli([
      '--ceilings=${ceilingFile.path}',
      '--out=${out.path}',
      '--sizes=${_sizes.join(',')}',
    ], measurer: measurer);
    return (
      code,
      out.existsSync()
          ? jsonDecode(out.readAsStringSync()) as Map<String, dynamic>
          : null,
    );
  } finally {
    dir.deleteSync(recursive: true);
  }
}

ScaleOutcome _reportWithRss(double? Function(int) peak) => buildScaleReport(
  bySize: {
    for (final n in _sizes)
      n: {
        for (final flow in scaleFlows)
          flow: FlowMeasurement(
            cpuSeconds: n.toDouble(),
            wallSeconds: n.toDouble(),
            peakRssMb: peak(n),
            actionCount: n,
            maxCommandLineBytes: n,
          ),
      },
  },
  ceilings: _ceilings(),
  seed: 7,
);

void _testPeakRssIsReportOnly() {
  final unmeasured = _reportWithRss((n) => null);
  _check(unmeasured.problems.isEmpty, 'unmeasured: ${unmeasured.problems}');
  final steep = _reportWithRss((n) => n * n.toDouble());
  _check(steep.problems.isEmpty, 'rss is report-only: ${steep.problems}');
  final entry =
      (steep.report['flows']! as Map)['dart-app-clean'] as Map<String, Object?>;
  final exponent = (entry['growth_exponent']! as Map)['peak_rss_mb'];
  _check(exponent is double && exponent > 1.9, 'rss exponent reported');
}

void _testCliExitCodes() {
  var (code, report) = _runScale(ceilings: _ceilings(), measurer: _fake);
  _check(code == 0 && report != null, 'healthy run exits 0, got $code');

  (code, report) = _runScale(
    ceilings: _ceilings(),
    measurer: (n) => _fake(n, exponents: {'dart-app-api': 2.0}),
  );
  _check(code == 1, 'exponent above ceiling exits 1, got $code');
  _check(report != null, 'report is written before exiting 1');

  final missing = _ceilings()..remove('dart-test-leaf');
  (code, report) = _runScale(ceilings: missing, measurer: _fake);
  _check(code == 1, 'flow without ceiling exits 1, got $code');
  _check(report != null, 'report is written when a ceiling is missing');

  (code, report) = _runScale(
    ceilings: _ceilings(),
    measurer: (n) => {
      ..._fake(n),
      'dart-app-body': const FlowMeasurement.failed('boom'),
    },
  );
  _check(code == 1 && report != null, 'failed flow exits 1, got $code');

  (code, report) = _runScale(
    ceilings: _ceilings(),
    measurer: (n) => {
      ..._fake(n),
      'dart-app-clean': FlowMeasurement(
        cpuSeconds: 1,
        wallSeconds: 1,
        actionCount: 1,
        maxCommandLineBytes: 1,
        reproducible: n != 1000,
      ),
    },
  );
  _check(code == 1 && report != null, 'irreproducible flow exits 1');
}

void _testBadUsage() {
  _check(runScaleCli([]) == 1, 'no flags exits 1');
  _check(
    runScaleCli(['--out=x.json', '--ceilings=c.json', '--sizes=1,2']) == 1,
    'sizes below 2 exit 1',
  );
  _check(
    runScaleCli(['--out=x.json', '--ceilings=c.json']) == 1,
    'missing --workspace-root exits 1',
  );
}

void _testCheckedInCeilings(String rlocationPath) {
  final path = Runfiles.create().rlocation(rlocationPath);
  _check(File(path).existsSync(), 'ceiling table is in the runfiles');
  final table = readCeilings(path);
  _check(
    scaleFlows.every(table.containsKey),
    'checked-in ceilings cover every flow',
  );
  _check(
    table.values.every((c) => c > 0 && c.isFinite),
    'checked-in ceilings are positive numbers',
  );
}

void main(List<String> args) {
  _testFit();
  _testReportContent();
  _testPeakRssIsReportOnly();
  _testCliExitCodes();
  _testBadUsage();
  _testCheckedInCeilings(args.first);
  stdout.writeln('Scale tests passed.');
}
