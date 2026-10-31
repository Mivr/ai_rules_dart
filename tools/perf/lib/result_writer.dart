/// Result formatting and summary writer for `dart-sol.json`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Host runner system information.
final class RunnerInfo {
  /// Creates a runner info record.
  const RunnerInfo({
    required this.system,
    required this.release,
    required this.machine,
    required this.cpuCount,
  });

  /// Operating system name (e.g. "linux").
  final String system;

  /// Kernel / OS release string.
  final String release;

  /// Machine architecture (e.g. "x86_64").
  final String machine;

  /// Number of CPU cores available.
  final int cpuCount;

  /// Detects runner info from the current environment.
  static RunnerInfo detect() {
    var system = Platform.operatingSystem;
    var release = Platform.operatingSystemVersion;
    var machine = 'x86_64';
    final cpuCount = Platform.numberOfProcessors;

    if (Platform.isLinux) {
      try {
        final unameRes = Process.runSync('uname', ['-s', '-r', '-m']);
        if (unameRes.exitCode == 0) {
          final parts = (unameRes.stdout as String).trim().split(
            RegExp(r'\s+'),
          );
          if (parts.isNotEmpty) system = parts[0].toLowerCase();
          if (parts.length > 1) release = parts[1];
          if (parts.length > 2) machine = parts[2];
        }
      } on ProcessException catch (e) {
        stderr.writeln('uname process error: $e');
      }
    }

    return RunnerInfo(
      system: system,
      release: release,
      machine: machine,
      cpuCount: cpuCount,
    );
  }

  /// Converts this record to a map.
  Map<String, dynamic> toJson() => {
    'cpu_count': cpuCount,
    'machine': machine,
    'release': release,
    'system': system,
  };
}

/// Result of a single flow in a single repeat.
final class FlowResult {
  /// Creates a flow result record.
  const FlowResult({
    required this.method,
    required this.bazelCpu,
    required this.solCpu,
    required this.identical,
    required this.reason,
    required this.chain,
    required this.workerSteps,
  });

  /// Measurement method: "batch" or "warm-server".
  final String method;

  /// Bazel CPU seconds.
  final double? bazelCpu;

  /// Speed-of-light CPU seconds.
  final double? solCpu;

  /// Whether replayed outputs matched byte-for-byte.
  final bool identical;

  /// Status reason ("ok" or failure description).
  final String reason;

  /// Count of chain spawns replayed.
  final int chain;

  /// Count of persistent worker steps.
  final int workerSteps;

  /// Serializes to JSON map.
  Map<String, dynamic> toJson() => {
    'method': method,
    'bazelCpu': bazelCpu,
    'solCpu': solCpu,
    'identical': identical,
    'reason': reason,
    'chain': chain,
    'workerSteps': workerSteps,
  };

  /// Deserializes from JSON map.
  static FlowResult fromJson(Map<String, dynamic> json) {
    return FlowResult(
      method: json['method'] as String? ?? 'warm-server',
      bazelCpu: (json['bazelCpu'] as num?)?.toDouble(),
      solCpu: (json['solCpu'] as num?)?.toDouble(),
      identical: json['identical'] as bool? ?? false,
      reason: json['reason'] as String? ?? 'missing',
      chain: (json['chain'] as num?)?.toInt() ?? 0,
      workerSteps: (json['workerSteps'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Result of an entire repeat across all four flows.
final class RepeatResult {
  /// Creates a repeat result.
  const RepeatResult({required this.repeatIndex, required this.flows});

  /// Repeat sequence index.
  final int repeatIndex;

  /// Flow results by flow name.
  final Map<String, FlowResult> flows;

  /// Serializes to JSON map.
  Map<String, dynamic> toJson() => {
    'repeatIndex': repeatIndex,
    'flows': flows.map((k, v) => MapEntry(k, v.toJson())),
  };

  /// Deserializes from JSON map.
  static RepeatResult fromJson(Map<String, dynamic> json) {
    final rawFlows = json['flows'] as Map<String, dynamic>? ?? const {};
    final flows = <String, FlowResult>{};
    for (final entry in rawFlows.entries) {
      if (entry.value is Map<String, dynamic>) {
        flows[entry.key] = FlowResult.fromJson(
          entry.value as Map<String, dynamic>,
        );
      }
    }
    return RepeatResult(
      repeatIndex: (json['repeatIndex'] as num?)?.toInt() ?? 0,
      flows: flows,
    );
  }
}

/// Metadata options for summary output.
final class SummaryMeta {
  /// Creates summary metadata.
  const SummaryMeta({
    required this.rulesDartSha,
    required this.targetLoc,
    required this.seed,
    required this.repeats,
  });

  /// Git commit 40-hex SHA of rules under measurement.
  final String rulesDartSha;

  /// Target lines of code.
  final int targetLoc;

  /// Random seed.
  final int seed;

  /// Expected repeats count.
  final int repeats;
}

/// Computes the median of a list of numbers.
double? calculateMedian(List<double> values) {
  if (values.isEmpty) return null;
  final sorted = List.of(values)..sort();
  final mid = sorted.length ~/ 2;
  if (sorted.length.isOdd) {
    return sorted[mid];
  }
  return (sorted[mid - 1] + sorted[mid]) / 2.0;
}

double _round4(double value) => double.parse(value.toStringAsFixed(4));

/// Recursively sorts map keys alphabetically.
Object? _sortKeysRecursively(Object? value) {
  if (value is Map) {
    final sortedKeys = value.keys.map((k) => k.toString()).toList()..sort();
    final result = <String, Object?>{};
    for (final k in sortedKeys) {
      result[k] = _sortKeysRecursively(value[k]);
    }
    return result;
  } else if (value is List) {
    return value.map(_sortKeysRecursively).toList();
  }
  return value;
}

String _resolveFailureReason(String? flowFailure, String? countFailure) {
  if (flowFailure != null && countFailure != null) {
    return '$flowFailure ($countFailure)';
  }
  return flowFailure ?? countFailure ?? 'failed';
}

final class _FlowAccumulator {
  final List<double> bazelVals = [];
  final List<double> solVals = [];
  bool allIdentical = true;
  String? flowFailure;
  int chainCount = 0;
  int workerSteps = 0;

  void recordRepeat(FlowResult? f, int repeatIndex, String key) {
    if (f == null) {
      allIdentical = false;
      flowFailure ??= 'flow $key missing in repeat $repeatIndex';
      return;
    }

    chainCount = max(chainCount, f.chain);
    workerSteps = max(workerSteps, f.workerSteps);
    if (f.bazelCpu != null) bazelVals.add(f.bazelCpu!);

    if (f.identical && f.solCpu != null && f.bazelCpu != null) {
      solVals.add(f.solCpu!);
    } else {
      allIdentical = false;
      if (flowFailure == null && f.reason.isNotEmpty && f.reason != 'ok') {
        flowFailure = f.reason;
      }
    }
  }
}

Map<String, dynamic> _buildFlowEntry(
  String key,
  List<RepeatResult> repeats,
  int expectedRepeats,
) {
  final method = key == 'dart-app-clean' ? 'batch' : 'warm-server';
  final acc = _FlowAccumulator();
  if (expectedRepeats <= 0 || repeats.length != expectedRepeats) {
    acc.allIdentical = false;
  }

  for (final r in repeats) {
    acc.recordRepeat(r.flows[key], r.repeatIndex, key);
  }

  final countFailure =
      (expectedRepeats <= 0 || repeats.length != expectedRepeats)
      ? 'missing repeats: expected $expectedRepeats, got ${repeats.length}'
      : null;
  final isIdentical = acc.allIdentical && acc.solVals.length == expectedRepeats;
  final bazelMedian = calculateMedian(acc.bazelVals);
  final solMedian = isIdentical ? calculateMedian(acc.solVals) : null;
  final reason = isIdentical
      ? 'ok'
      : _resolveFailureReason(acc.flowFailure, countFailure);

  final spreadBazel = acc.bazelVals.isEmpty
      ? null
      : [
          _round4(acc.bazelVals.reduce(min)),
          _round4(acc.bazelVals.reduce(max)),
        ];
  final spreadSol = (!isIdentical || acc.solVals.isEmpty)
      ? null
      : [_round4(acc.solVals.reduce(min)), _round4(acc.solVals.reduce(max))];

  return {
    'bazel': bazelMedian != null ? _round4(bazelMedian) : null,
    'chain': acc.chainCount,
    'identical': isIdentical,
    'method': method,
    'reason': reason,
    'sol': solMedian != null ? _round4(solMedian) : null,
    'spread': {
      'bazel': spreadBazel,
      'n': acc.bazelVals.length,
      'sol': spreadSol,
    },
    'worker_steps': acc.workerSteps,
  };
}

/// Generates the `dart-sol.json` contents from repeat results.
String formatDartSolJson({
  required List<RepeatResult> repeats,
  required SummaryMeta meta,
  required RunnerInfo runner,
}) {
  const flowKeys = [
    'dart-app-clean',
    'dart-app-body',
    'dart-app-api',
    'dart-test-leaf',
  ];

  final flowsMap = <String, dynamic>{};
  for (final key in flowKeys) {
    flowsMap[key] = _buildFlowEntry(key, repeats, meta.repeats);
  }

  final topLevel = <String, dynamic>{
    'flows': flowsMap,
    'meta': {
      'bazel_flags': <String>[],
      'lockfile': 'committed',
      'repeats': meta.repeats,
      'seed': meta.seed,
      'target_loc': meta.targetLoc,
    },
    'rules_dart': meta.rulesDartSha.trim(),
    'runner': runner.toJson(),
    'unit': 'cpu_seconds',
  };

  final sorted = _sortKeysRecursively(topLevel) as Map<String, dynamic>;
  return '${const JsonEncoder.withIndent('  ').convert(sorted)}\n';
}
