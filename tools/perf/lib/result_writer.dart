/// Result formatting and summary writer for `dart-sol.json`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'cli_args.dart';
import 'spawn_log.dart';
import 'summary_table.dart';

export 'summary_table.dart';

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
    var system = Platform.operatingSystem.toLowerCase();
    var release = Platform.operatingSystemVersion;
    var machine = 'x86_64';
    final cpuCount = Platform.numberOfProcessors;

    if (Platform.isLinux || Platform.isMacOS) {
      try {
        final unameRes = Process.runSync(
          'uname',
          ['-s', '-r', '-m'],
          environment: cleanProcessEnvironment(),
          includeParentEnvironment: false,
        );
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
    } else if (Platform.isWindows) {
      final arch = (Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '')
          .trim()
          .toLowerCase();
      if (arch.isNotEmpty && arch != 'amd64') {
        machine = arch;
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

/// Converts ordered spawn records to the `steps` object in a chain description.
Map<String, dynamic> chainStepsFromSpawns(List<SpawnRecord> spawns) {
  final steps = <String, dynamic>{};
  for (var i = 0; i < spawns.length; i++) {
    final s = spawns[i];
    final key = 'step_${i + 1}';
    steps[key] = {
      'command_args': List<String>.of(s.commandArgs),
      'declared_outputs': s.declaredOutputs.toList()..sort(),
      'mnemonic': s.mnemonic,
      'runner': s.runner,
    };
  }
  return steps;
}

/// Constructs a chain description map adhering to the `android-sol.json` schema.
Map<String, dynamic> buildChainObject({
  required bool identical,
  required double? solCpu,
  required String reason,
  Map<String, dynamic> steps = const {},
  String? orderingFailed,
}) {
  final failedList = identical
      ? <String>[]
      : (reason.isNotEmpty && reason != 'ok'
            ? <String>[reason]
            : <String>['failed']);
  return {
    'failed': failedList,
    'ordering_failed': orderingFailed,
    'output_drift': {'differ': <String>[], 'n': 0},
    'skipped': <String, dynamic>{},
    'sol_cpu_s': identical ? solCpu : null,
    'status': identical ? 'ok' : 'error',
    'steps': steps,
    'verify_differ': {'differ': <String>[], 'n': 0},
  };
}

/// Toolchain floor data for a flow result.
final class FlowFloorData {
  /// Creates a flow floor data record.
  const FlowFloorData({
    this.cpuSeconds,
    this.reason = 'ok',
    this.floorKind = 'aot',
    this.identical = true,
    this.enabled = true,
  });

  /// Timed floor CPU seconds.
  final double? cpuSeconds;

  /// Floor status reason ("ok" or failure description).
  final String reason;

  /// Floor kind ("aot" or "jit").
  final String floorKind;

  /// Whether the floor execution and verification succeeded.
  final bool identical;

  /// Whether the toolchain floor was enabled.
  final bool enabled;

  /// Disabled floor constant for backward compatibility.
  static const disabled = FlowFloorData(
    cpuSeconds: null,
    reason: 'ok',
    floorKind: 'aot',
    identical: true,
    enabled: false,
  );
}

/// Replay data grouped for flow results.
final class FlowReplayData {
  /// Creates a replay data record.
  const FlowReplayData({
    required this.solCpu,
    required this.identical,
    required this.reason,
    required this.chain,
    this.workerSteps = const {},
  });

  /// Speed-of-light CPU seconds.
  final double? solCpu;

  /// Whether replayed outputs matched byte-for-byte.
  final bool identical;

  /// Status reason.
  final String reason;

  /// Replay chain map.
  final Map<String, dynamic> chain;

  /// Worker step counts.
  final Map<String, int> workerSteps;
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
    this.peakRssMb,
  }) : floor = FlowFloorData.disabled;

  /// Creates a flow result record including floor data.
  FlowResult.withFloor({
    required this.method,
    required this.bazelCpu,
    required FlowReplayData replay,
    this.floor = FlowFloorData.disabled,
    this.peakRssMb,
  }) : solCpu = replay.solCpu,
       identical = replay.identical,
       reason = replay.reason,
       chain = replay.chain,
       workerSteps = replay.workerSteps;

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

  /// Chain description map with replayed steps.
  final Map<String, dynamic> chain;

  /// Persistent worker spawn counts by mnemonic.
  final Map<String, int> workerSteps;

  /// Toolchain floor data.
  final FlowFloorData floor;

  /// Peak summed resident set (MiB) of the measured Bazel command's process
  /// tree, or null when the flow failed or was not sampled.
  final double? peakRssMb;

  /// A copy of this result carrying [peak] as [peakRssMb].
  FlowResult withPeakRssMb(double? peak) => FlowResult.withFloor(
    method: method,
    bazelCpu: bazelCpu,
    replay: FlowReplayData(
      solCpu: solCpu,
      identical: identical,
      reason: reason,
      chain: chain,
      workerSteps: workerSteps,
    ),
    floor: floor,
    peakRssMb: peak,
  );

  /// Timed floor CPU seconds.
  double? get toolchainFloorCpu => floor.cpuSeconds;

  /// Floor failure reason, or "ok".
  String get floorReason => floor.reason;

  /// Floor kind ("aot" or "jit").
  String get floorKind => floor.floorKind;

  /// Whether the floor execution and check succeeded.
  bool get floorIdentical => floor.identical;

  /// Whether the floor was enabled.
  bool get floorEnabled => floor.enabled;

  /// Serializes to JSON map.
  Map<String, dynamic> toJson() => {
    'method': method,
    'bazelCpu': bazelCpu,
    'solCpu': solCpu,
    'identical': identical,
    'reason': reason,
    'chain': chain,
    'workerSteps': workerSteps,
    if (peakRssMb != null) 'peak_rss_mb': peakRssMb,
    if (floor.enabled) ...{
      'floor_enabled': floor.enabled,
      'floor_identical': floor.identical,
      'floor_kind': floor.floorKind,
      'floor_reason': floor.reason,
      'toolchain_floor': floor.cpuSeconds,
    },
  };

  /// Deserializes from JSON map.
  static FlowResult fromJson(Map<String, dynamic> json) {
    final rawWorkerSteps = json['workerSteps'] ?? json['worker_steps'];
    final workerSteps = <String, int>{};
    if (rawWorkerSteps is Map) {
      for (final entry in rawWorkerSteps.entries) {
        final v = (entry.value as num?)?.toInt();
        if (v != null) {
          workerSteps[entry.key.toString()] = v;
        }
      }
    }
    final bazelNum = (json['bazelCpu'] ?? json['bazel']) as num?;
    final solNum = (json['solCpu'] ?? json['sol']) as num?;
    final isIdentical = json['identical'] as bool? ?? false;
    final reason = json['reason'] as String? ?? 'missing';
    final rawChain = json['chain'];
    final Map<String, dynamic> chain;
    if (rawChain is Map<String, dynamic>) {
      chain = rawChain;
    } else if (rawChain is Map) {
      chain = rawChain.cast<String, dynamic>();
    } else {
      chain = buildChainObject(
        identical: isIdentical,
        solCpu: solNum?.toDouble(),
        reason: reason,
      );
    }

    final floorEnabled = json['floor_enabled'] ?? json['floorEnabled'];
    final toolchainFloor =
        (json['toolchain_floor'] ?? json['toolchainFloorCpu']) as num?;
    final floorReason =
        (json['floor_reason'] ?? json['floorReason']) as String?;
    final floorKind = (json['floor_kind'] ?? json['floorKind']) as String?;
    final floorIdentical =
        (json['floor_identical'] ?? json['floorIdentical']) as bool?;

    final FlowFloorData floorData;
    if (floorEnabled == true || toolchainFloor != null || floorReason != null) {
      floorData = FlowFloorData(
        cpuSeconds: toolchainFloor?.toDouble(),
        reason: floorReason ?? 'ok',
        floorKind: floorKind ?? 'aot',
        identical:
            floorIdentical ?? (floorReason == null || floorReason == 'ok'),
        enabled: floorEnabled as bool? ?? true,
      );
    } else {
      floorData = FlowFloorData.disabled;
    }

    return FlowResult.withFloor(
      method: json['method'] as String? ?? 'warm-server',
      bazelCpu: bazelNum?.toDouble(),
      replay: FlowReplayData(
        solCpu: solNum?.toDouble(),
        identical: isIdentical,
        reason: reason,
        chain: chain,
        workerSteps: workerSteps,
      ),
      floor: floorData,
      peakRssMb: (json['peak_rss_mb'] as num?)?.toDouble(),
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
    final idxNum = (json['repeatIndex'] ?? json['repeat']) as num?;
    return RepeatResult(repeatIndex: idxNum?.toInt() ?? 0, flows: flows);
  }
}

/// Flow names every repeat and every summary must carry.
const List<String> expectedFlowKeys = [
  'dart-app-clean',
  'dart-app-body',
  'dart-app-api',
  'dart-test-leaf',
];

bool _isFlowHealthy(FlowResult flow) {
  if (!flow.identical ||
      flow.solCpu == null ||
      flow.bazelCpu == null ||
      flow.reason != 'ok') {
    return false;
  }
  if (flow.floorEnabled) {
    if (!flow.floorIdentical ||
        flow.toolchainFloorCpu == null ||
        flow.floorReason != 'ok') {
      return false;
    }
  }
  return true;
}

/// Whether [result] has all [expectedFlowKeys], each identical, measured and ok.
bool isRepeatHealthy(RepeatResult result) {
  for (final key in expectedFlowKeys) {
    final flow = result.flows[key];
    if (flow == null || !_isFlowHealthy(flow)) return false;
  }
  return true;
}

void _checkFlowSummaryFailure(
  String key,
  Map<dynamic, dynamic>? flow,
  List<String> failures,
) {
  if (flow == null) {
    failures.add('flow $key is missing');
    return;
  }
  final reason = flow['reason'];
  if (flow['identical'] != true || flow['sol'] == null || reason != 'ok') {
    failures.add(
      'flow $key failed: identical=${flow['identical']}, '
      'sol=${flow['sol']}, reason=${reason == null ? 'null' : '"$reason"'}',
    );
  }
  if (flow.containsKey('floor_reason')) {
    final floorReason = flow['floor_reason'];
    final toolchainFloor = flow['toolchain_floor'];
    if (floorReason != 'ok' || toolchainFloor == null) {
      failures.add(
        'flow $key floor failed: toolchain_floor=$toolchainFloor, '
        'floor_reason=${floorReason == null ? 'null' : '"$floorReason"'}',
      );
    }
  }
}

/// Lists why a decoded `dart-sol.json` [summary] is not healthy (empty if ok).
List<String> summaryFailures(Map<String, dynamic> summary) {
  final failures = <String>[];
  final meta = summary['meta'];
  final repeats = meta is Map ? meta['repeats'] : null;
  if (repeats is! int || repeats < 1) {
    failures.add('meta.repeats must be an integer >= 1, got $repeats');
  }
  final flows = summary['flows'];
  for (final key in expectedFlowKeys) {
    final flow = flows is Map ? flows[key] : null;
    _checkFlowSummaryFailure(key, flow is Map ? flow : null, failures);
  }
  return failures;
}

/// Whether [summary] has no [summaryFailures].
bool isSummaryHealthy(Map<String, dynamic> summary) =>
    summaryFailures(summary).isEmpty;

/// Metadata options for summary output.
final class SummaryMeta {
  /// Creates summary metadata.
  const SummaryMeta({
    required this.rulesDartSha,
    required this.targetLoc,
    required this.seed,
    required this.repeats,
    this.bazelFlags = const [],
    this.lockfile = 'committed',
  });

  /// Git commit 40-hex SHA of rules under measurement.
  final String rulesDartSha;

  /// Target lines of code.
  final int targetLoc;

  /// Random seed.
  final int seed;

  /// Expected repeats count.
  final int repeats;

  /// Bazel flags recorded in `meta.bazel_flags`.
  final List<String> bazelFlags;

  /// Lockfile state recorded in `meta.lockfile`.
  final String lockfile;
}

/// Loads valid [RepeatResult] JSON files from [resultsDir], sorted by index.
List<RepeatResult> loadRepeatResults(
  String resultsDir, {
  String? excludeFilePath,
}) {
  final repeatResults = <RepeatResult>[];
  final dir = Directory(resultsDir);
  if (!dir.existsSync()) return repeatResults;

  final excludedNorm = excludeFilePath != null && excludeFilePath.isNotEmpty
      ? resolveCliPath(excludeFilePath)
      : null;
  final files = dir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    if (!file.path.endsWith('.json')) continue;
    if (excludedNorm != null && resolveCliPath(file.path) == excludedNorm) {
      continue;
    }
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) continue;
      final hasIndex =
          decoded.containsKey('repeatIndex') || decoded.containsKey('repeat');
      if (!hasIndex ||
          decoded.containsKey('rules_dart') ||
          decoded['flows'] is! Map<String, dynamic>) {
        continue;
      }
      repeatResults.add(RepeatResult.fromJson(decoded));
    } on FormatException catch (e) {
      stderr.writeln('Malformed JSON in repeat file ${file.path}: $e');
    } on TypeError catch (e) {
      stderr.writeln('Invalid schema in repeat file ${file.path}: $e');
    } on FileSystemException catch (e) {
      stderr.writeln('Error loading repeat file ${file.path}: $e');
    }
  }
  repeatResults.sort((a, b) => a.repeatIndex.compareTo(b.repeatIndex));
  return repeatResults;
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

double _roundCpu(double value) => double.parse(value.toStringAsFixed(6));

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
  final List<double> floorVals = [];
  final List<double> peakRssVals = [];
  bool allIdentical = true;
  bool allFloorIdentical = true;
  bool floorEnabled = false;
  String? flowFailure;
  String? floorFailure;
  String? floorKind;
  Map<String, dynamic>? chainMap;
  final Map<String, int> workerSteps = {};

  void _recordChain(Map<String, dynamic> chain, bool identical) {
    if (chain.isEmpty) return;
    final steps = chain['steps'];
    final hasSteps = steps is Map && steps.isNotEmpty;
    if (chainMap == null) {
      chainMap = chain;
      return;
    }
    if (!hasSteps) return;
    final existingSteps = chainMap!['steps'];
    if (existingSteps is! Map || existingSteps.isEmpty) {
      chainMap = chain;
    } else if (identical && chainMap!['status'] != 'ok') {
      chainMap = chain;
    }
  }

  void _recordReplay(FlowResult f) {
    if (f.bazelCpu != null) bazelVals.add(f.bazelCpu!);
    final isOk =
        f.identical &&
        f.reason == 'ok' &&
        f.solCpu != null &&
        f.bazelCpu != null;
    if (isOk) {
      solVals.add(f.solCpu!);
      return;
    }
    allIdentical = false;
    if (flowFailure == null && f.reason.isNotEmpty && f.reason != 'ok') {
      flowFailure = f.reason;
    }
  }

  void _recordFloor(FlowResult f) {
    if (!f.floorEnabled) return;
    floorEnabled = true;
    floorKind = f.floorKind;
    final isOk =
        f.floorIdentical &&
        f.floorReason == 'ok' &&
        f.toolchainFloorCpu != null;
    if (isOk) {
      floorVals.add(f.toolchainFloorCpu!);
      return;
    }
    allFloorIdentical = false;
    if (floorFailure == null &&
        f.floorReason.isNotEmpty &&
        f.floorReason != 'ok') {
      floorFailure = f.floorReason;
    }
  }

  void recordRepeat(FlowResult? f, int repeatIndex, String key) {
    if (f == null) {
      allIdentical = false;
      allFloorIdentical = false;
      flowFailure ??= 'flow $key missing in repeat $repeatIndex';
      floorFailure ??= 'flow $key missing in repeat $repeatIndex';
      return;
    }

    _recordChain(f.chain, f.identical);
    for (final entry in f.workerSteps.entries) {
      workerSteps[entry.key] = max(workerSteps[entry.key] ?? 0, entry.value);
    }
    _recordReplay(f);
    _recordFloor(f);
    if (f.peakRssMb != null) peakRssVals.add(f.peakRssMb!);
  }
}

Map<String, dynamic> _resolveFlowChain(
  _FlowAccumulator acc, {
  required bool isIdentical,
  required double? solMedian,
  required String reason,
}) {
  if (acc.chainMap != null) {
    final entry = Map<String, dynamic>.from(acc.chainMap!);
    if (isIdentical) {
      entry['status'] = 'ok';
      entry['failed'] = <String>[];
      entry['sol_cpu_s'] = solMedian != null ? _roundCpu(solMedian) : null;
    } else {
      entry['status'] = 'error';
      entry['sol_cpu_s'] = null;
      entry['failed'] = [reason];
    }
    return entry;
  }
  return buildChainObject(
    identical: isIdentical,
    solCpu: solMedian != null ? _roundCpu(solMedian) : null,
    reason: reason,
  );
}

Map<String, dynamic> _peakRssField(_FlowAccumulator acc) {
  final median = calculateMedian(acc.peakRssVals);
  if (median == null) return const {};
  return {'peak_rss_mb': double.parse(median.toStringAsFixed(3))};
}

List<double>? _calculateSpread(List<double> vals, {bool valid = true}) {
  if (!valid || vals.isEmpty) return null;
  return [_roundCpu(vals.reduce(min)), _roundCpu(vals.reduce(max))];
}

Map<String, dynamic> _buildFloorFields({
  required String key,
  required _FlowAccumulator acc,
  required double? bazelMedian,
  required int expectedRepeats,
  required String? countFailure,
}) {
  if (!acc.floorEnabled) return const {};
  final isIdentical =
      acc.allFloorIdentical && acc.floorVals.length == expectedRepeats;
  final median = isIdentical ? calculateMedian(acc.floorVals) : null;
  final reason = isIdentical
      ? 'ok'
      : (acc.floorFailure ?? countFailure ?? 'failed');
  final ratio = (bazelMedian != null && median != null && median > 0)
      ? _roundCpu(bazelMedian / median)
      : null;
  return {
    'floor_kind': acc.floorKind ?? (key == 'dart-app-body' ? 'jit' : 'aot'),
    'floor_ratio': ratio,
    'floor_reason': reason,
    'toolchain_floor': median != null ? _roundCpu(median) : null,
    'toolchain_floor_ratio': ratio,
  };
}

Map<String, dynamic> _buildSpreadMap({
  required _FlowAccumulator acc,
  required bool isIdentical,
  required int expectedRepeats,
}) {
  final isFloorIdentical =
      acc.allFloorIdentical && acc.floorVals.length == expectedRepeats;
  return {
    'bazel': _calculateSpread(acc.bazelVals),
    'n': acc.bazelVals.length,
    'sol': _calculateSpread(acc.solVals, valid: isIdentical),
    if (acc.floorEnabled)
      'toolchain_floor': _calculateSpread(
        acc.floorVals,
        valid: isFloorIdentical,
      ),
  };
}

Map<String, dynamic> _buildFlowEntry(
  String key,
  List<RepeatResult> repeats,
  int expectedRepeats,
) {
  final acc = _FlowAccumulator();
  final countMismatch =
      expectedRepeats <= 0 || repeats.length != expectedRepeats;
  if (countMismatch) {
    acc.allIdentical = false;
    acc.allFloorIdentical = false;
  }
  for (final r in repeats) {
    acc.recordRepeat(r.flows[key], r.repeatIndex, key);
  }

  final countFailure = countMismatch
      ? 'missing repeats: expected $expectedRepeats, got ${repeats.length}'
      : null;
  final isIdentical = acc.allIdentical && acc.solVals.length == expectedRepeats;
  final bazelMedian = calculateMedian(acc.bazelVals);
  final solMedian = isIdentical ? calculateMedian(acc.solVals) : null;
  final reason = isIdentical
      ? 'ok'
      : _resolveFailureReason(acc.flowFailure, countFailure);

  return {
    'bazel': bazelMedian != null ? _roundCpu(bazelMedian) : null,
    'chain': _resolveFlowChain(
      acc,
      isIdentical: isIdentical,
      solMedian: solMedian,
      reason: reason,
    ),
    ..._buildFloorFields(
      key: key,
      acc: acc,
      bazelMedian: bazelMedian,
      expectedRepeats: expectedRepeats,
      countFailure: countFailure,
    ),
    'identical': isIdentical,
    'method': key == 'dart-app-clean' ? 'batch' : 'warm-server',
    ..._peakRssField(acc),
    'reason': reason,
    'sol': solMedian != null ? _roundCpu(solMedian) : null,
    'spread': _buildSpreadMap(
      acc: acc,
      isIdentical: isIdentical,
      expectedRepeats: expectedRepeats,
    ),
    'worker_steps': Map<String, int>.of(acc.workerSteps),
  };
}

/// Generates the `dart-sol.json` contents from repeat results.
String formatDartSolJson({
  required List<RepeatResult> repeats,
  required SummaryMeta meta,
  required RunnerInfo runner,
}) {
  final flowsMap = <String, dynamic>{};
  for (final key in expectedFlowKeys) {
    flowsMap[key] = _buildFlowEntry(key, repeats, meta.repeats);
  }

  final topLevel = <String, dynamic>{
    'flows': flowsMap,
    'meta': {
      'bazel_flags': List<String>.of(meta.bazelFlags),
      'lockfile': meta.lockfile,
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
