/// Unit tests for execution log parsing, spawn filtering and chain ordering.
library;

import 'dart:io';

import 'package:perf/spawn_log.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

void _expectStateError(void Function() action, String message) {
  try {
    action();
  } on StateError catch (e) {
    _check(e.message.isNotEmpty, message);
    return;
  }
  throw StateError('FAIL: $message (expected StateError)');
}

void _testConcatenatedJsonParsingAndWorkers() {
  const jsonText =
      '{"commandArgs":["tool1","arg1"],"runner":"linux-sandbox","listedOutputs":["bazel-out/k8-fastbuild/bin/a.dill"],"exitCode":0}'
      '{"commandArgs":["tool2","arg{\\"nested\\": \\"}\\"}","--x={y}"],"runner":"worker","listedOutputs":["bazel-out/k8-fastbuild/bin/b.dill"],"exitCode":0}\n'
      '{"commandArgs":["cached_worker"],"runner":"worker","cacheHit":true,"listedOutputs":["bazel-out/k8-fastbuild/bin/c.dill"],"exitCode":0}\n'
      '{"commandArgs":["failed_tool"],"runner":"worker","listedOutputs":["bazel-out/k8-fastbuild/bin/bad.dill"],"exitCode":1}';

  final objs = extractConcatenatedJsonObjects(jsonText).toList();
  _check(objs.length == 4, 'Extracted 4 concatenated top-level JSON objects');

  final parsed = parseExecutionLog(jsonText);
  _check(parsed.allSpawns.length == 4, 'Parsed all 4 spawn records');
  _check(parsed.chainSpawns.length == 2, 'Excluded cached and failed spawns');
  _check(
    parsed.workerSteps == 1,
    'workerSteps counts only non-cached target chain worker spawns',
  );
  _check(
    parsed.blockedOutputs.contains('bazel-out/k8-fastbuild/bin/bad.dill'),
    'Failed spawn output recorded in blockedOutputs',
  );
}

void _testExecConfigAndWindowsPathFiltering() {
  const logText = r'''
{
  "commandArgs": ["host_tool"],
  "listedOutputs": ["bazel-out/k8-opt-exec-ST-d5f/bin/tool"],
  "runner": "worker",
  "exitCode": 0
}
{
  "commandArgs": ["win_host_tool"],
  "listedOutputs": ["bazel-out\\x64_windows-opt-exec\\bin\\tool.exe"],
  "exitCode": 0
}
{
  "commandArgs": ["dart_compile"],
  "listedOutputs": ["bazel-out\\k8-fastbuild\\bin\\app.dill"],
  "exitCode": 0
}
''';

  final parsed = parseExecutionLog(logText);
  _check(parsed.allSpawns.length == 3, 'Parsed 3 spawns');
  _check(
    parsed.chainSpawns.length == 1,
    'Filtered both Unix and Windows exec-config spawns',
  );
  _check(parsed.workerSteps == 0, 'Exec-config worker not counted in chain');
  _check(
    parsed.chainSpawns.single.declaredOutputs.single ==
        'bazel-out/k8-fastbuild/bin/app.dill',
    'Normalized Windows backslashes in declaredOutputs',
  );
}

void _testOrderingTreeArtifactsAndBlockedRefusal() {
  final spawnMod = parseSpawnMap({
    'commandArgs': ['compile_kmod'],
    'inputs': [
      {'path': 'packages/pkg0/lib/pkg0.dart'},
    ],
    'listedOutputs': ['bazel-out/k8-fastbuild/bin/packages/pkg0/pkg0.kmod'],
    'exitCode': 0,
  })!;

  final spawnLink = parseSpawnMap({
    'commandArgs': ['kernel_link'],
    'inputs': [
      {'path': 'bazel-out/k8-fastbuild/bin/packages/pkg0/pkg0.kmod/0.dill'},
    ],
    'listedOutputs': [
      'bazel-out/k8-fastbuild/bin/packages/pkg0/pkg0_test.dill',
    ],
    'exitCode': 0,
  })!;

  final spawnTest = parseSpawnMap({
    'mnemonic': 'TestRunner',
    'commandArgs': ['test-setup.sh'],
    'inputs': [
      {
        'path': 'bazel-out/k8-fastbuild/bin/packages/pkg0/pkg0_test.runfiles/_main/packages/pkg0/pkg0_test.dill',
      },
    ],
    'listedOutputs': ['bazel-out/k8-fastbuild/testlogs/pkg0_test/test.xml'],
    'exitCode': 0,
  })!;

  final ordered = orderChainSpawns([spawnTest, spawnLink, spawnMod]);
  _check(ordered.length == 3, 'Ordered 3 spawns');
  _check(ordered[0].commandArgs.single == 'compile_kmod', 'Tree producer 1st');
  _check(ordered[1].commandArgs.single == 'kernel_link', 'Tree consumer 2nd');
  _check(
    ordered[2].commandArgs.single == 'test-setup.sh',
    'Runfiles consumer TestRunner ordered 3rd',
  );

  // Refuse cyclic dependency
  final cycleA = parseSpawnMap({
    'commandArgs': ['ca'],
    'inputs': ['bazel-out/cb.out'],
    'listedOutputs': ['bazel-out/ca.out'],
  })!;
  final cycleB = parseSpawnMap({
    'commandArgs': ['cb'],
    'inputs': ['bazel-out/ca.out'],
    'listedOutputs': ['bazel-out/cb.out'],
  })!;
  _expectStateError(
    () => orderChainSpawns([cycleA, cycleB]),
    'Refuses cyclic dependency in chain spawns',
  );

  // Refuse blocked input produced by a failed upstream spawn
  const blockedLog = '''
{
  "commandArgs": ["broken_gen"],
  "listedOutputs": ["bazel-out/k8-fastbuild/bin/gen.dart"],
  "exitCode": 1
}
{
  "commandArgs": ["downstream_compile"],
  "inputs": ["bazel-out/k8-fastbuild/bin/gen.dart"],
  "listedOutputs": ["bazel-out/k8-fastbuild/bin/out.dill"],
  "exitCode": 0
}
''';
  final parsedBlocked = parseExecutionLog(blockedLog);
  _expectStateError(
    () => orderChainSpawns(
      parsedBlocked.chainSpawns,
      blockedOutputs: parsedBlocked.blockedOutputs,
    ),
    'Refuses chain spawn consuming output of failed upstream spawn',
  );
}

void _testLeafTestVerifySetSelection() {
  final kmodSpawn = parseSpawnMap({
    'mnemonic': 'DartKernelModule',
    'commandArgs': ['kernel_module'],
    'listedOutputs': ['bazel-out/k8-fastbuild/bin/pkg28.kmod'],
    'exitCode': 0,
  })!;
  final linkSpawn = parseSpawnMap({
    'mnemonic': 'DartKernelLink',
    'commandArgs': ['kernel_link'],
    'inputs': ['bazel-out/k8-fastbuild/bin/pkg28.kmod/module.dill'],
    'listedOutputs': ['bazel-out/k8-fastbuild/bin/pkg28_test.dill'],
    'exitCode': 0,
  })!;
  final testRunnerSpawn = parseSpawnMap({
    'mnemonic': 'TestRunner',
    'commandArgs': ['external/bazel_tools/tools/test/test-setup.sh', 'pkg28'],
    'inputs': ['bazel-out/k8-fastbuild/bin/pkg28_test.dill'],
    'listedOutputs': [
      'bazel-out/k8-fastbuild/testlogs/pkg28_test/test.log',
      'bazel-out/k8-fastbuild/testlogs/pkg28_test/test.xml',
      'bazel-out/k8-fastbuild/testlogs/pkg28_test/test.cache_status',
    ],
    'exitCode': 0,
  })!;

  _check(testRunnerSpawn.isTestRunner, 'Detects TestRunner via mnemonic');
  final verifySet = selectLeafTestVerifyPaths([
    kmodSpawn,
    linkSpawn,
    testRunnerSpawn,
  ]);
  _check(
    verifySet.contains('bazel-out/k8-fastbuild/bin/pkg28_test.dill'),
    'Compiled .dill verified',
  );
  _check(
    verifySet.contains('bazel-out/k8-fastbuild/bin/pkg28.kmod'),
    'Compiled .kmod verified',
  );
  _check(
    !verifySet.any((p) => p.contains('testlogs/')),
    'TestRunner test.log/test.xml/test.cache_status excluded from verifySet',
  );
}

void main() {
  _testConcatenatedJsonParsingAndWorkers();
  _testExecConfigAndWindowsPathFiltering();
  _testOrderingTreeArtifactsAndBlockedRefusal();
  _testLeafTestVerifySetSelection();
  stdout.writeln('All spawn_log tests passed.');
}
