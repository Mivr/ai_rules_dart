/// Scale measurements, the `dart-scale.json` report and the ceiling check.
library;

import 'growth_fit.dart';
import 'server_heap.dart';

/// Flows measured at every size, in report order.
const List<String> scaleFlows = [
  'dart-app-clean',
  'dart-app-body',
  'dart-app-api',
  'dart-test-leaf',
  'dart-analysis',
];

/// Metrics recorded per flow and size, in report order.
const List<String> scaleMetrics = [
  'cpu_seconds',
  'wall_seconds',
  'peak_rss_mb',
  'action_count',
  'max_command_line_bytes',
];

/// Metrics reported with a growth exponent but held to no ceiling.
const Set<String> reportOnlyScaleMetrics = {'peak_rss_mb'};

/// What Bazel's own counters said about one flow at one size.
final class FlowMeasurement {
  /// Creates a successful, reproducible measurement.
  const FlowMeasurement({
    required this.cpuSeconds,
    required this.wallSeconds,
    required this.actionCount,
    required this.maxCommandLineBytes,
    this.reproducible = true,
    this.serverHeap,
    this.peakRssMb,
  }) : error = null;

  /// Creates a measurement of a flow that failed with [error].
  const FlowMeasurement.failed(String this.error)
    : cpuSeconds = 0,
      wallSeconds = 0,
      actionCount = 0,
      maxCommandLineBytes = 0,
      reproducible = true,
      serverHeap = null,
      peakRssMb = null;

  /// Client plus server CPU seconds.
  final double cpuSeconds;

  /// Wall-clock seconds.
  final double wallSeconds;

  /// Number of actions executed (or planned, for the analysis flow).
  final int actionCount;

  /// Bytes of the largest action command line.
  final int maxCommandLineBytes;

  /// Peak summed resident set (MiB) of the measured Bazel server tree, or
  /// null when it was not measured or the flow failed.
  final double? peakRssMb;

  /// Whether the flow's outputs matched on a repeated run.
  final bool reproducible;

  /// Why the flow failed, or null.
  final String? error;

  /// The server's heap after the flow, or null when not read.
  final ServerHeap? serverHeap;

  /// This measurement with the server heap read after the flow.
  FlowMeasurement withServerHeap(ServerHeap heap) => FlowMeasurement(
    cpuSeconds: cpuSeconds,
    wallSeconds: wallSeconds,
    actionCount: actionCount,
    maxCommandLineBytes: maxCommandLineBytes,
    reproducible: reproducible,
    serverHeap: heap,
    peakRssMb: peakRssMb,
  );

  /// The value of [metric], or null when it was not measured.
  double? metric(String metric) => switch (metric) {
    'cpu_seconds' => cpuSeconds,
    'wall_seconds' => wallSeconds,
    'action_count' => actionCount.toDouble(),
    'peak_rss_mb' => peakRssMb,
    'max_command_line_bytes' => maxCommandLineBytes.toDouble(),
    _ => throw ArgumentError.value(metric, 'metric', 'unknown metric'),
  };
}

/// Measurements of every flow, keyed by flow name, at one size.
typedef SizeMeasurements = Map<String, FlowMeasurement>;

/// A finished scale run: the report plus the problems that fail the run.
final class ScaleOutcome {
  /// Creates an outcome.
  const ScaleOutcome(this.report, this.problems);

  /// The `dart-scale.json` content.
  final Map<String, Object?> report;

  /// Human-readable reasons the run must exit non-zero; empty when healthy.
  final List<String> problems;
}

/// Fits the exponent of [metric] over the sizes in [byLibraries].
///
/// Returns `(exponent, null)` or `(null, reason)` when the fit is undefined.
(double?, String?) _fit(Map<int, FlowMeasurement> byLibraries, String metric) {
  try {
    return (
      fitGrowthExponent([
        for (final e in byLibraries.entries)
          if (e.value.metric(metric) case final value?) (e.key, value),
      ]),
      null,
    );
  } on ArgumentError catch (e) {
    return (null, '${e.message}');
  }
}

double? _perLibrary(double? value, int libraries) =>
    value == null ? null : value / libraries;

Map<String, Object?> _flowReport(
  String flow,
  Map<int, FlowMeasurement> byLibraries,
  double? ceiling,
  List<String> problems,
) {
  final metrics = <String, Object?>{};
  final perLibrary = <String, Object?>{};
  final exponents = <String, Object?>{};
  for (final metric in scaleMetrics) {
    metrics[metric] = {
      for (final e in byLibraries.entries) '${e.key}': e.value.metric(metric),
    };
    perLibrary[metric] = {
      for (final e in byLibraries.entries)
        '${e.key}': _perLibrary(e.value.metric(metric), e.key),
    };
    final (exponent, reason) = _fit(byLibraries, metric);
    exponents[metric] = exponent;
    if (reportOnlyScaleMetrics.contains(metric)) continue;
    if (exponent == null) {
      problems.add('$flow $metric: growth exponent undefined: $reason');
    } else if (ceiling != null && exponent > ceiling) {
      problems.add(
        '$flow $metric: exponent $exponent exceeds ceiling $ceiling',
      );
    }
  }
  return {
    'metrics': metrics,
    'cost_per_library': perLibrary,
    'growth_exponent': exponents,
    'exponent_ceiling': ceiling,
  };
}

/// Builds the report for [bySize] and collects every problem found.
///
/// A flow fails the run when any size reports an error or irreproducible
/// outputs, when it has no entry in [ceilings], when a metric's exponent is
/// undefined or when it is above the flow's ceiling.
ScaleOutcome buildScaleReport({
  required Map<int, SizeMeasurements> bySize,
  required Map<String, double> ceilings,
  required int seed,
}) {
  final problems = <String>[];
  final flows = <String, Object?>{};
  final heaps = <String, Object?>{};
  final sizes = bySize.keys.toList()..sort();
  for (final flow in scaleFlows) {
    final good = <int, FlowMeasurement>{};
    for (final size in sizes) {
      final m = bySize[size]?[flow];
      if (m == null) {
        problems.add('$flow at $size libraries: not measured');
      } else if (m.error != null) {
        problems.add('$flow at $size libraries failed: ${m.error}');
      } else {
        good[size] = m;
        final heap = m.serverHeap;
        if (heap != null) {
          (heaps.putIfAbsent('$size', () => <String, Object?>{})
              as Map<String, Object?>)[flow] = heap
              .toJson();
        }
        if (!m.reproducible) {
          problems.add('$flow at $size libraries: outputs not reproducible');
        }
      }
    }
    final ceiling = ceilings[flow];
    if (ceiling == null)
      problems.add('$flow: no ceiling in scale_ceilings.json');
    flows[flow] = _flowReport(flow, good, ceiling, problems);
  }
  return ScaleOutcome({
    'schema': 1,
    'seed': seed,
    'sizes': sizes,
    'flows': flows,
    'problems': problems,
    'server_heap': heaps,
  }, problems);
}
