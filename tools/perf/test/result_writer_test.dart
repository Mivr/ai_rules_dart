/// Unit tests for result writer and summary JSON schema.
library;

import 'dart:convert';
import 'dart:io';

import 'package:perf/result_writer.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

void _testAllPassSummary() {
  const runner = RunnerInfo(
    system: 'linux',
    release: '6.6.137',
    machine: 'x86_64',
    cpuCount: 4,
  );
  const meta = SummaryMeta(
    rulesDartSha: '0123456789abcdef0123456789abcdef01234567',
    targetLoc: 500000,
    seed: 1,
    repeats: 3,
  );

  final r1 = RepeatResult(
    repeatIndex: 1,
    flows: {
      'dart-app-clean': const FlowResult(
        method: 'batch',
        bazelCpu: 10.0,
        solCpu: 4.0,
        identical: true,
        reason: 'ok',
        chain: 12,
        workerSteps: 5,
      ),
      'dart-app-body': const FlowResult(
        method: 'warm-server',
        bazelCpu: 2.0,
        solCpu: 0.5,
        identical: true,
        reason: 'ok',
        chain: 2,
        workerSteps: 1,
      ),
      'dart-app-api': const FlowResult(
        method: 'warm-server',
        bazelCpu: 4.0,
        solCpu: 1.0,
        identical: true,
        reason: 'ok',
        chain: 6,
        workerSteps: 2,
      ),
      'dart-test-leaf': const FlowResult(
        method: 'warm-server',
        bazelCpu: 3.0,
        solCpu: 0.8,
        identical: true,
        reason: 'ok',
        chain: 3,
        workerSteps: 1,
      ),
    },
  );

  final r2 = RepeatResult(
    repeatIndex: 2,
    flows: {
      'dart-app-clean': const FlowResult(
        method: 'batch',
        bazelCpu: 12.0,
        solCpu: 4.2,
        identical: true,
        reason: 'ok',
        chain: 12,
        workerSteps: 5,
      ),
      'dart-app-body': const FlowResult(
        method: 'warm-server',
        bazelCpu: 2.2,
        solCpu: 0.55,
        identical: true,
        reason: 'ok',
        chain: 2,
        workerSteps: 1,
      ),
      'dart-app-api': const FlowResult(
        method: 'warm-server',
        bazelCpu: 4.4,
        solCpu: 1.1,
        identical: true,
        reason: 'ok',
        chain: 6,
        workerSteps: 2,
      ),
      'dart-test-leaf': const FlowResult(
        method: 'warm-server',
        bazelCpu: 3.2,
        solCpu: 0.85,
        identical: true,
        reason: 'ok',
        chain: 3,
        workerSteps: 1,
      ),
    },
  );

  final r3 = RepeatResult(
    repeatIndex: 3,
    flows: {
      'dart-app-clean': const FlowResult(
        method: 'batch',
        bazelCpu: 11.0,
        solCpu: 4.1,
        identical: true,
        reason: 'ok',
        chain: 12,
        workerSteps: 5,
      ),
      'dart-app-body': const FlowResult(
        method: 'warm-server',
        bazelCpu: 2.1,
        solCpu: 0.52,
        identical: true,
        reason: 'ok',
        chain: 2,
        workerSteps: 1,
      ),
      'dart-app-api': const FlowResult(
        method: 'warm-server',
        bazelCpu: 4.2,
        solCpu: 1.05,
        identical: true,
        reason: 'ok',
        chain: 6,
        workerSteps: 2,
      ),
      'dart-test-leaf': const FlowResult(
        method: 'warm-server',
        bazelCpu: 3.1,
        solCpu: 0.82,
        identical: true,
        reason: 'ok',
        chain: 3,
        workerSteps: 1,
      ),
    },
  );

  final jsonStr = formatDartSolJson(
    repeats: [r1, r2, r3],
    meta: meta,
    runner: runner,
  );

  _check(jsonStr.endsWith('\n'), 'Terminated by newline');
  final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

  // Top level keys
  _check(decoded.containsKey('rules_dart'), 'top-level contains rules_dart');
  _check(decoded.containsKey('unit'), 'top-level contains unit');
  _check(decoded.containsKey('runner'), 'top-level contains runner');
  _check(decoded.containsKey('meta'), 'top-level contains meta');
  _check(decoded.containsKey('flows'), 'top-level contains flows');
  _check(decoded['unit'] == 'cpu_seconds', 'unit is cpu_seconds');

  final metaMap = decoded['meta'] as Map<String, dynamic>;
  _check(metaMap['lockfile'] == 'committed', 'meta.lockfile == committed');
  _check((metaMap['bazel_flags'] as List).isEmpty, 'meta.bazel_flags is empty');
  _check(metaMap['repeats'] == 3, 'meta.repeats == 3');

  final flows = decoded['flows'] as Map<String, dynamic>;
  _check(flows.containsKey('dart-app-clean'), 'has dart-app-clean');
  _check(flows.containsKey('dart-app-body'), 'has dart-app-body');
  _check(flows.containsKey('dart-app-api'), 'has dart-app-api');
  _check(flows.containsKey('dart-test-leaf'), 'has dart-test-leaf');

  final clean = flows['dart-app-clean'] as Map<String, dynamic>;
  _check(clean['identical'] == true, 'clean identical == true');
  _check(clean['method'] == 'batch', 'clean method == batch');
  _check(clean['reason'] == 'ok', 'clean reason == ok');
  _check(clean['bazel'] == 11.0, 'clean bazel median 11.0');
  _check(clean['sol'] == 4.1, 'clean sol median 4.1');
  _check(clean['chain'] == 12, 'clean chain 12');
  _check(clean['worker_steps'] == 5, 'clean worker_steps 5');

  final spread = clean['spread'] as Map<String, dynamic>;
  _check(spread['n'] == 3, 'spread n == 3');
  final spreadBazel = spread['bazel'] as List;
  _check(spreadBazel[0] == 10.0, 'spread bazel min');
  _check(spreadBazel[1] == 12.0, 'spread bazel max');
  final spreadSol = spread['sol'] as List;
  _check(spreadSol[0] == 4.0, 'spread sol min');
  _check(spreadSol[1] == 4.2, 'spread sol max');
}

void _testFailureAndMissingRepeats() {
  const runner = RunnerInfo(
    system: 'linux',
    release: '6.6.137',
    machine: 'x86_64',
    cpuCount: 4,
  );
  const meta = SummaryMeta(
    rulesDartSha: '0123456789abcdef0123456789abcdef01234567',
    targetLoc: 500000,
    seed: 1,
    repeats: 3,
  );

  // Only 1 repeat delivered out of 3 expected
  final r1 = RepeatResult(
    repeatIndex: 1,
    flows: {
      'dart-app-clean': const FlowResult(
        method: 'batch',
        bazelCpu: 10.0,
        solCpu: null,
        identical: false,
        reason: 'Byte mismatch in output',
        chain: 12,
        workerSteps: 5,
      ),
    },
  );

  final jsonStr = formatDartSolJson(repeats: [r1], meta: meta, runner: runner);
  final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
  final flows = decoded['flows'] as Map<String, dynamic>;
  final clean = flows['dart-app-clean'] as Map<String, dynamic>;

  _check(clean['identical'] == false, 'identical is false');
  _check(clean['sol'] == null, 'sol is null on failure');
  _check(clean['reason'] != 'ok', 'non-empty failure reason');
  _check(
    (clean['reason'] as String).contains('Byte mismatch') ||
        (clean['reason'] as String).contains('missing repeats'),
    'failure reason described correctly',
  );

  final spread = clean['spread'] as Map<String, dynamic>;
  _check(spread['sol'] == null, 'spread.sol is null when identical is false');
}

void main() {
  _testAllPassSummary();
  _testFailureAndMissingRepeats();
  stdout.writeln('All result_writer tests passed.');
}
