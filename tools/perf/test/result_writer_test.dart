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
        chain: 12,
        workerSteps: const {'DartKernel': 5},
      ),
      'dart-app-body': FlowResult(
        method: 'warm-server',
        bazelCpu: bodySol * 4,
        solCpu: bodySol,
        identical: true,
        reason: 'ok',
        chain: 2,
        workerSteps: const {'DartKernel': 1},
      ),
      'dart-app-api': const FlowResult(
        method: 'warm-server',
        bazelCpu: 4.2,
        solCpu: 1.05,
        identical: true,
        reason: 'ok',
        chain: 6,
        workerSteps: {'DartKernel': 2},
      ),
      'dart-test-leaf': const FlowResult(
        method: 'warm-server',
        bazelCpu: 3.1,
        solCpu: 0.82,
        identical: true,
        reason: 'ok',
        chain: 3,
        workerSteps: {'DartKernel': 1},
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
  _check(clean['chain'] == 12, 'clean chain == 12');
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
      'dart-app-clean': const FlowResult(
        method: 'batch',
        bazelCpu: 10.0,
        solCpu: null,
        identical: false,
        reason: 'Byte mismatch in output',
        chain: 12,
        workerSteps: {'DartKernel': 5},
      ),
      'dart-app-body': const FlowResult(
        method: 'warm-server',
        bazelCpu: 2.0,
        solCpu: 0.5,
        identical: true,
        reason: 'ok',
        chain: 2,
        workerSteps: {'DartKernel': 1},
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
          r5Clean.workerSteps['DartKernel'] == 3,
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

void main() {
  _testAllPassSummaryAndSortedSchema();
  _testFailureAndMissingRepeats();
  _testEmptyRepeatsSummary();
  _testLoadRepeatResultsFilteringAndOrder();
  stdout.writeln('All result_writer tests passed.');
}
