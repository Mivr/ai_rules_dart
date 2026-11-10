/// Unit tests for `dart-sol.json` result writer and summary schema.
library;

import 'dart:convert';
import 'dart:io';

import 'package:perf/result_writer.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

const _sampleRunner = RunnerInfo(
  system: 'linux',
  release: '6.6.137',
  machine: 'x86_64',
  cpuCount: 4,
);

const _sampleMeta = SummaryMeta(
  rulesDartSha: '0123456789abcdef0123456789abcdef01234567',
  targetLoc: 500000,
  seed: 1,
  repeats: 3,
);

Map<String, dynamic> _mockChain({
  required int stepCount,
  required double? solCpu,
  required bool identical,
  required String reason,
  String mnemonic = 'DartKernel',
}) {
  final steps = <String, dynamic>{};
  for (var i = 1; i <= stepCount; i++) {
    steps['step_$i'] = {
      'command_args': ['tool', 'arg$i'],
      'declared_outputs': ['out/file$i.dill'],
      'mnemonic': mnemonic,
      'runner': 'worker',
    };
  }
  return buildChainObject(
    identical: identical,
    solCpu: solCpu,
    reason: reason,
    steps: steps,
  );
}

RepeatResult _makePassingRepeat({
  required int index,
  required double cleanBazel,
  required double cleanSol,
  required double bodySol,
}) {
  return RepeatResult(
    repeatIndex: index,
    flows: {
      'dart-app-clean': FlowResult(
        method: 'batch',
        bazelCpu: cleanBazel,
        solCpu: cleanSol,
        identical: true,
        reason: 'ok',
        chain: _mockChain(
          stepCount: 12,
          solCpu: cleanSol,
          identical: true,
          reason: 'ok',
        ),
        workerSteps: const {'DartKernel': 5},
      ),
      'dart-app-body': FlowResult(
        method: 'warm-server',
        bazelCpu: bodySol * 4,
        solCpu: bodySol,
        identical: true,
        reason: 'ok',
        chain: _mockChain(
          stepCount: 2,
          solCpu: bodySol,
          identical: true,
          reason: 'ok',
        ),
        workerSteps: const {'DartKernel': 1},
      ),
      'dart-app-api': FlowResult(
        method: 'warm-server',
        bazelCpu: 4.2,
        solCpu: 1.05,
        identical: true,
        reason: 'ok',
        chain: _mockChain(
          stepCount: 6,
          solCpu: 1.05,
          identical: true,
          reason: 'ok',
        ),
        workerSteps: const {'DartKernel': 2},
      ),
      'dart-test-leaf': FlowResult(
        method: 'warm-server',
        bazelCpu: 3.1,
        solCpu: 0.82,
        identical: true,
        reason: 'ok',
        chain: _mockChain(
          stepCount: 3,
          solCpu: 0.82,
          identical: true,
          reason: 'ok',
          mnemonic: 'TestRunner',
        ),
        workerSteps: const {'DartKernel': 1},
      ),
    },
  );
}

void _testAllPassSummaryAndSortedSchema() {
  final r1 = _makePassingRepeat(
    index: 1,
    cleanBazel: 10.0,
    cleanSol: 4.0,
    bodySol: 0.50,
  );
  final r2 = _makePassingRepeat(
    index: 2,
    cleanBazel: 12.0,
    cleanSol: 4.2,
    bodySol: 0.55,
  );
  final r3 = _makePassingRepeat(
    index: 3,
    cleanBazel: 11.0,
    cleanSol: 4.1,
    bodySol: 0.52,
  );

  final jsonStr = formatDartSolJson(
    repeats: [r1, r2, r3],
    meta: _sampleMeta,
    runner: _sampleRunner,
  );

  _check(jsonStr.endsWith('\n'), 'JSON ends with trailing newline');
  final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
  final topKeys = decoded.keys.toList();
  _check(
    topKeys.join(',') == 'flows,meta,rules_dart,runner,unit',
    'Top-level keys are sorted: $topKeys',
  );
  _check(
    decoded['rules_dart'] == _sampleMeta.rulesDartSha,
    'rules_dart SHA matches',
  );
  _check(decoded['unit'] == 'cpu_seconds', 'unit is cpu_seconds');

  final metaMap = decoded['meta'] as Map<String, dynamic>;
  _check(metaMap['lockfile'] == 'committed', 'meta.lockfile == committed');
  _check((metaMap['bazel_flags'] as List).isEmpty, 'meta.bazel_flags == []');
  _check(metaMap['repeats'] == 3, 'meta.repeats == 3');
  _check(metaMap['target_loc'] == 500000, 'meta.target_loc == 500000');
  _check(metaMap['seed'] == 1, 'meta.seed == 1');

  final flows = decoded['flows'] as Map<String, dynamic>;
  _check(
    flows.keys.join(',') ==
        'dart-app-api,dart-app-body,dart-app-clean,dart-test-leaf',
    'Flow keys are sorted',
  );

  final clean = flows['dart-app-clean'] as Map<String, dynamic>;
  _check(clean['identical'] == true, 'clean identical == true');
  _check(clean['method'] == 'batch', 'clean method == batch');
  _check(clean['reason'] == 'ok', 'clean reason == ok');
  _check(clean['bazel'] == 11.0, 'clean bazel median == 11.0');
  _check(clean['sol'] == 4.1, 'clean sol median == 4.1');

  final cleanChain = clean['chain'] as Map<String, dynamic>;
  _check(cleanChain['status'] == 'ok', 'clean chain.status == ok');
  _check(cleanChain['sol_cpu_s'] == 4.1, 'clean chain.sol_cpu_s == 4.1');
  _check((cleanChain['failed'] as List).isEmpty, 'clean chain.failed is empty');
  final cleanSteps = cleanChain['steps'] as Map<String, dynamic>;
  _check(cleanSteps.length == 12, 'clean chain.steps length == 12');
  final step1 = cleanSteps['step_1'] as Map<String, dynamic>;
  _check(step1['mnemonic'] == 'DartKernel', 'step_1 mnemonic == DartKernel');

  final cleanWorkerSteps = clean['worker_steps'] as Map<String, dynamic>;
  _check(
    cleanWorkerSteps['DartKernel'] == 5,
    'clean worker_steps == {DartKernel: 5}',
  );

  final spread = clean['spread'] as Map<String, dynamic>;
  _check(spread['n'] == 3, 'spread.n == 3');
  _check((spread['bazel'] as List)[0] == 10.0, 'spread.bazel min');
  _check((spread['bazel'] as List)[1] == 12.0, 'spread.bazel max');
  _check((spread['sol'] as List)[0] == 4.0, 'spread.sol min');
  _check((spread['sol'] as List)[1] == 4.2, 'spread.sol max');
}

void _testFailureAndMissingRepeats() {
  final partial = RepeatResult(
    repeatIndex: 1,
    flows: {
      'dart-app-clean': FlowResult(
        method: 'batch',
        bazelCpu: 10.0,
        solCpu: null,
        identical: false,
        reason: 'Byte mismatch in output',
        chain: _mockChain(
          stepCount: 12,
          solCpu: null,
          identical: false,
          reason: 'Byte mismatch in output',
        ),
        workerSteps: const {'DartKernel': 5},
      ),
      'dart-app-body': FlowResult(
        method: 'warm-server',
        bazelCpu: 2.0,
        solCpu: 0.5,
        identical: true,
        reason: 'ok',
        chain: _mockChain(
          stepCount: 2,
          solCpu: 0.5,
          identical: true,
          reason: 'ok',
        ),
        workerSteps: const {'DartKernel': 1},
      ),
    },
  );

  final jsonMissing = formatDartSolJson(
    repeats: [partial],
    meta: _sampleMeta,
    runner: _sampleRunner,
  );
  final flows =
      (jsonDecode(jsonMissing) as Map<String, dynamic>)['flows']
          as Map<String, dynamic>;

  final clean = flows['dart-app-clean'] as Map<String, dynamic>;
  _check(clean['identical'] == false, 'Failed flow identical is false');
  _check(clean['sol'] == null, 'Failed flow sol is null');
  _check(
    (clean['reason'] as String).contains('Byte mismatch'),
    'Failed flow preserves failure reason: ${clean['reason']}',
  );
  _check(
    (clean['spread'] as Map<String, dynamic>)['sol'] == null,
    'Failed flow spread.sol is null',
  );
  final failedChain = clean['chain'] as Map<String, dynamic>;
  _check(failedChain['status'] == 'error', 'Failed flow chain.status is error');
  _check(
    failedChain['sol_cpu_s'] == null,
    'Failed flow chain.sol_cpu_s is null',
  );
  _check(
    (failedChain['failed'] as List).any(
      (e) => e.toString().contains('Byte mismatch'),
    ),
    'Failed flow chain.failed contains reason',
  );
  _check(
    (failedChain['steps'] as Map).isNotEmpty,
    'Failed flow chain preserves replayed steps',
  );

  final body = flows['dart-app-body'] as Map<String, dynamic>;
  _check(
    body['identical'] == false,
    'Flow with 1 of 3 expected repeats has identical == false',
  );
  _check(body['sol'] == null, 'Flow with missing repeats has sol == null');
  _check(
    (body['reason'] as String).contains('missing repeats'),
    'Missing repeats reason reported: ${body['reason']}',
  );
}

void _testEmptyRepeatsSummary() {
  final jsonEmpty = formatDartSolJson(
    repeats: const [],
    meta: _sampleMeta,
    runner: _sampleRunner,
  );
  final emptyFlows =
      (jsonDecode(jsonEmpty) as Map<String, dynamic>)['flows']
          as Map<String, dynamic>;
  final emptyLeaf = emptyFlows['dart-test-leaf'] as Map<String, dynamic>;
  _check(emptyLeaf['identical'] == false, 'Zero repeats identical == false');
  _check(emptyLeaf['bazel'] == null, 'Zero repeats bazel == null');
  _check(emptyLeaf['sol'] == null, 'Zero repeats sol == null');
  final emptyChain = emptyLeaf['chain'] as Map<String, dynamic>;
  _check(emptyChain['status'] == 'error', 'Zero repeats chain.status is error');
  _check(
    emptyChain['sol_cpu_s'] == null,
    'Zero repeats chain.sol_cpu_s is null',
  );
  _check(
    (emptyChain['failed'] as List).isNotEmpty,
    'Zero repeats chain.failed is non-empty',
  );
  _check(
    (emptyLeaf['worker_steps'] as Map).isEmpty,
    'Zero repeats worker_steps is empty object',
  );
  _check(
    (emptyLeaf['reason'] as String).isNotEmpty && emptyLeaf['reason'] != 'ok',
    'Zero repeats has non-empty failure reason',
  );
}

void _testLoadRepeatResultsFilteringAndOrder() {
  final dir = Directory.systemTemp.createTempSync('rd_load_repeats_');
  try {
    final r10 = _makePassingRepeat(
      index: 10,
      cleanBazel: 9.0,
      cleanSol: 3.0,
      bodySol: 0.4,
    );
    final r2 = _makePassingRepeat(
      index: 2,
      cleanBazel: 8.0,
      cleanSol: 2.5,
      bodySol: 0.3,
    );
    File('${dir.path}/repeat-10.json')
        .writeAsStringSync('${jsonEncode(r10.toJson())}\n');
    File('${dir.path}/repeat-2.json')
        .writeAsStringSync('${jsonEncode(r2.toJson())}\n');

    final summaryPath = '${dir.path}/dart-sol.json';
    File(summaryPath).writeAsStringSync(
      formatDartSolJson(
        repeats: [r2, r10],
        meta: _sampleMeta,
        runner: _sampleRunner,
      ),
    );
    File('${dir.path}/repeat-5.json').writeAsStringSync(
      '{"repeat":5,"flows":{"dart-app-clean":{"method":"batch","bazel":8.5,'
      '"sol":2.8,"identical":true,"reason":"ok","chain":10,'
      '"worker_steps":{"DartKernel":3}}}}\n',
    );
    File('${dir.path}/other.json')
        .writeAsStringSync('{"flows": {"dart-app-clean": {}}}\n');

    final loaded = loadRepeatResults(dir.path, excludeFilePath: summaryPath);
    _check(loaded.length == 3, 'Ignores dart-sol.json and non-repeat JSON');
    _check(
      loaded[0].repeatIndex == 2 &&
          loaded[1].repeatIndex == 5 &&
          loaded[2].repeatIndex == 10,
      'Sorts repeat files numerically by repeatIndex',
    );
    final r5Clean = loaded[1].flows['dart-app-clean']!;
    _check(
      r5Clean.bazelCpu == 8.5 &&
          r5Clean.solCpu == 2.8 &&
          r5Clean.workerSteps['DartKernel'] == 3 &&
          r5Clean.chain['status'] == 'ok',
      'Parses snake_case repeat JSON fields cleanly',
    );
  } finally {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException catch (e) {
      stderr.writeln('Temp cleanup skipped: $e');
    }
  }
}

RepeatResult _makePassingRepeatWithFloor({
  required int index,
  required double cleanBazel,
  required double cleanSol,
  required double cleanFloor,
  required double bodySol,
  required double bodyFloor,
}) {
  return RepeatResult(
    repeatIndex: index,
    flows: {
      'dart-app-clean': FlowResult.withFloor(
        method: 'batch',
        bazelCpu: cleanBazel,
        replay: FlowReplayData(
          solCpu: cleanSol,
          identical: true,
          reason: 'ok',
          chain: _mockChain(
            stepCount: 12,
            solCpu: cleanSol,
            identical: true,
            reason: 'ok',
          ),
          workerSteps: const {'DartKernel': 5},
        ),
        floor: FlowFloorData(
          cpuSeconds: cleanFloor,
          reason: 'ok',
          floorKind: 'aot',
          identical: true,
          enabled: true,
        ),
      ),
      'dart-app-body': FlowResult.withFloor(
        method: 'warm-server',
        bazelCpu: bodySol * 4,
        replay: FlowReplayData(
          solCpu: bodySol,
          identical: true,
          reason: 'ok',
          chain: _mockChain(
            stepCount: 2,
            solCpu: bodySol,
            identical: true,
            reason: 'ok',
          ),
          workerSteps: const {'DartKernel': 1},
        ),
        floor: FlowFloorData(
          cpuSeconds: bodyFloor,
          reason: 'ok',
          floorKind: 'jit',
          identical: true,
          enabled: true,
        ),
      ),
      'dart-app-api': FlowResult.withFloor(
        method: 'warm-server',
        bazelCpu: 4.2,
        replay: FlowReplayData(
          solCpu: 1.05,
          identical: true,
          reason: 'ok',
          chain: _mockChain(
            stepCount: 6,
            solCpu: 1.05,
            identical: true,
            reason: 'ok',
          ),
          workerSteps: const {'DartKernel': 2},
        ),
        floor: const FlowFloorData(
          cpuSeconds: 0.90,
          reason: 'ok',
          floorKind: 'aot',
          identical: true,
          enabled: true,
        ),
      ),
      'dart-test-leaf': FlowResult.withFloor(
        method: 'warm-server',
        bazelCpu: 3.1,
        replay: FlowReplayData(
          solCpu: 0.82,
          identical: true,
          reason: 'ok',
          chain: _mockChain(
            stepCount: 3,
            solCpu: 0.82,
            identical: true,
            reason: 'ok',
            mnemonic: 'TestRunner',
          ),
          workerSteps: const {'DartKernel': 1},
        ),
        floor: const FlowFloorData(
          cpuSeconds: 0.70,
          reason: 'ok',
          floorKind: 'aot',
          identical: true,
          enabled: true,
        ),
      ),
    },
  );
}

void _testToolchainFloorInSummaryAndSortedSchema() {
  final r1 = _makePassingRepeatWithFloor(
    index: 1,
    cleanBazel: 10.0,
    cleanSol: 4.0,
    cleanFloor: 3.0,
    bodySol: 0.50,
    bodyFloor: 0.20,
  );
  final r2 = _makePassingRepeatWithFloor(
    index: 2,
    cleanBazel: 12.0,
    cleanSol: 4.2,
    cleanFloor: 3.2,
    bodySol: 0.55,
    bodyFloor: 0.22,
  );
  final r3 = _makePassingRepeatWithFloor(
    index: 3,
    cleanBazel: 11.0,
    cleanSol: 4.1,
    cleanFloor: 3.1,
    bodySol: 0.52,
    bodyFloor: 0.21,
  );

  final jsonStr = formatDartSolJson(
    repeats: [r1, r2, r3],
    meta: _sampleMeta,
    runner: _sampleRunner,
  );

  final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
  final flows = decoded['flows'] as Map<String, dynamic>;

  // Clean flow checks
  final clean = flows['dart-app-clean'] as Map<String, dynamic>;
  _check(clean['sol'] == 4.1, 'clean sol remains 4.1');
  _check(
    clean['toolchain_floor'] == 3.1,
    'clean toolchain_floor is median 3.1',
  );
  _check(
    clean['toolchain_floor_ratio'] != null,
    'clean toolchain_floor_ratio is present',
  );
  _check(clean['floor_kind'] == 'aot', 'clean floor_kind is aot');
  _check(clean['floor_reason'] == 'ok', 'clean floor_reason is ok');

  final cleanSpread = clean['spread'] as Map<String, dynamic>;
  _check(cleanSpread['sol'] != null, 'clean spread sol is present');
  _check(
    cleanSpread['toolchain_floor'] != null,
    'clean spread toolchain_floor is present',
  );
  _check(
    (cleanSpread['toolchain_floor'] as List)[0] == 3.0,
    'floor spread min',
  );
  _check(
    (cleanSpread['toolchain_floor'] as List)[1] == 3.2,
    'floor spread max',
  );

  // Body flow checks (JIT floor)
  final body = flows['dart-app-body'] as Map<String, dynamic>;
  _check(body['floor_kind'] == 'jit', 'body floor_kind is jit');
  _check(
    body['toolchain_floor'] == 0.21,
    'body toolchain_floor median is 0.21',
  );

  // Step summary table check
  final table = formatStepSummaryTable(decoded);
  _check(table.contains('Replay Ratio'), 'Table contains Replay Ratio');
  _check(table.contains('Floor Ratio'), 'Table contains Floor Ratio');
  _check(table.contains('dart-app-clean'), 'Table contains dart-app-clean');
  _check(table.contains('dart-app-body'), 'Table contains dart-app-body');
}

void _testFailedFloorSetsReasonAndMakesSummaryUnhealthy() {
  final badFloorRepeat = RepeatResult(
    repeatIndex: 1,
    flows: {
      'dart-app-clean': FlowResult.withFloor(
        method: 'batch',
        bazelCpu: 10.0,
        replay: FlowReplayData(
          solCpu: 4.0,
          identical: true,
          reason: 'ok',
          chain: _mockChain(
            stepCount: 2,
            solCpu: 4.0,
            identical: true,
            reason: 'ok',
          ),
        ),
        floor: const FlowFloorData(
          cpuSeconds: null,
          reason: 'Floor AOT output differs from Bazel output',
          floorKind: 'aot',
          identical: false,
          enabled: true,
        ),
      ),
      'dart-app-body': FlowResult.withFloor(
        method: 'warm-server',
        bazelCpu: 2.0,
        replay: FlowReplayData(
          solCpu: 0.5,
          identical: true,
          reason: 'ok',
          chain: _mockChain(
            stepCount: 1,
            solCpu: 0.5,
            identical: true,
            reason: 'ok',
          ),
        ),
      ),
      'dart-app-api': FlowResult.withFloor(
        method: 'warm-server',
        bazelCpu: 2.0,
        replay: FlowReplayData(
          solCpu: 0.5,
          identical: true,
          reason: 'ok',
          chain: _mockChain(
            stepCount: 1,
            solCpu: 0.5,
            identical: true,
            reason: 'ok',
          ),
        ),
      ),
      'dart-test-leaf': FlowResult.withFloor(
        method: 'warm-server',
        bazelCpu: 2.0,
        replay: FlowReplayData(
          solCpu: 0.5,
          identical: true,
          reason: 'ok',
          chain: _mockChain(
            stepCount: 1,
            solCpu: 0.5,
            identical: true,
            reason: 'ok',
          ),
        ),
      ),
    },
  );

  _check(
    !isRepeatHealthy(badFloorRepeat),
    'Repeat with failed floor is unhealthy',
  );

  final jsonStr = formatDartSolJson(
    repeats: [badFloorRepeat],
    meta: const SummaryMeta(
      rulesDartSha: '0123456789abcdef0123456789abcdef01234567',
      targetLoc: 500000,
      seed: 1,
      repeats: 1,
    ),
    runner: _sampleRunner,
  );
  final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
  final flows = decoded['flows'] as Map<String, dynamic>;
  final clean = flows['dart-app-clean'] as Map<String, dynamic>;

  _check(clean['sol'] == 4.0, 'sol is unchanged on floor failure');
  _check(
    clean['toolchain_floor'] == null,
    'toolchain_floor is null on floor failure',
  );
  _check(
    clean['floor_reason'].contains('differs'),
    'floor_reason carries the floor failure message',
  );
  _check(!isSummaryHealthy(decoded), 'Summary with failed floor is unhealthy');
  final failures = summaryFailures(decoded);
  _check(
    failures.any((f) => f.contains('floor failed')),
    'summaryFailures lists floor failure',
  );
}

void _testFloorOffProducesBaseSchema() {
  final r1 = _makePassingRepeat(
    index: 1,
    cleanBazel: 10.0,
    cleanSol: 4.0,
    bodySol: 0.50,
  );
  _check(
    isRepeatHealthy(r1),
    'Floor-disabled repeat is healthy when replay passes',
  );

  final jsonStr = formatDartSolJson(
    repeats: [r1],
    meta: const SummaryMeta(
      rulesDartSha: '0123456789abcdef0123456789abcdef01234567',
      targetLoc: 500000,
      seed: 1,
      repeats: 1,
    ),
    runner: _sampleRunner,
  );
  final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
  final flows = decoded['flows'] as Map<String, dynamic>;
  final clean = flows['dart-app-clean'] as Map<String, dynamic>;

  _check(
    !clean.containsKey('toolchain_floor'),
    'Floor off omits toolchain_floor',
  );
  _check(!clean.containsKey('floor_kind'), 'Floor off omits floor_kind');
  _check(!clean.containsKey('floor_reason'), 'Floor off omits floor_reason');
  _check(
    !(clean['spread'] as Map).containsKey('toolchain_floor'),
    'Floor off omits toolchain_floor from spread',
  );
  _check(isSummaryHealthy(decoded), 'Floor-off summary is healthy');
}

void main() {
  _testAllPassSummaryAndSortedSchema();
  _testToolchainFloorInSummaryAndSortedSchema();
  _testFailedFloorSetsReasonAndMakesSummaryUnhealthy();
  _testFloorOffProducesBaseSchema();
  _testFailureAndMissingRepeats();
  _testEmptyRepeatsSummary();
  _testLoadRepeatResultsFilteringAndOrder();
  stdout.writeln('All result_writer tests passed.');
}
