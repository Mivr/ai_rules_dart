/// Unit tests for execution log parsing, spawn filtering and ordering.
library;

import 'dart:io';

import 'package:perf/spawn_log.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

void _testConcatenatedJsonParsing() {
  const jsonText = '''
{"commandArgs": ["tool1", "arg1"], "runner": "linux-sandbox", "exitCode": 0}
{"commandArgs": ["tool2", "arg{\\"nested\\": 1}"], "runner": "worker", "exitCode": 0}
{"commandArgs": ["tool3"], "exitCode": 1}
''';

  final objs = extractConcatenatedJsonObjects(jsonText).toList();
  _check(objs.length == 3, 'Extracted 3 top-level objects');

  final parsed = parseExecutionLog(jsonText);
  _check(parsed.allSpawns.length == 3, 'All spawns length == 3');
  _check(parsed.workerSteps == 1, 'workerSteps count == 1');
  _check(parsed.chainSpawns.length == 2, 'tool3 excluded due to exitCode 1');
}

void _testExecConfigFiltering() {
  const logText = '''
{
  "commandArgs": ["host_tool"],
  "listedOutputs": ["bazel-out/k8-opt-exec-ST-d5f/bin/tool"],
  "exitCode": 0
}
{
  "commandArgs": ["dart_compile"],
  "listedOutputs": ["bazel-out/k8-fastbuild/bin/app.dill"],
  "exitCode": 0
}
''';

  final parsed = parseExecutionLog(logText);
  _check(parsed.allSpawns.length == 2, 'Parsed 2 spawns');
  _check(
    parsed.chainSpawns.length == 1,
    'Filtered out exec configuration output',
  );
  _check(
    parsed.chainSpawns.first.commandArgs.first == 'dart_compile',
    'Kept target configuration spawn',
  );
}

void _testDependencyOrderingAndRefusal() {
  final spawnA = parseSpawnMap({
    'commandArgs': ['compile_a'],
    'inputs': ['src/a.dart'],
    'listedOutputs': ['bazel-out/a.dill'],
    'exitCode': 0,
  })!;

  final spawnB = parseSpawnMap({
    'commandArgs': ['link_b'],
    'inputs': ['bazel-out/a.dill'],
    'listedOutputs': ['bazel-out/b.app'],
    'exitCode': 0,
  })!;

  // Delivered out of order: B then A
  final ordered = orderChainSpawns([spawnB, spawnA]);
  _check(ordered.length == 2, 'ordered length == 2');
  _check(
    ordered[0].commandArgs.first == 'compile_a',
    'spawnA must execute before spawnB',
  );
  _check(
    ordered[1].commandArgs.first == 'link_b',
    'spawnB must execute after spawnA',
  );

  // Cyclic dependency refusal
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

  var cycleBlocked = false;
  try {
    orderChainSpawns([cycleA, cycleB]);
  } catch (_) {
    cycleBlocked = true;
  }
  _check(cycleBlocked, 'Refuses cyclic dependency in chain spawns');
}

void _testLeafTestVerifySet() {
  final compileSpawn = parseSpawnMap({
    'commandArgs': ['dart_compile'],
    'listedOutputs': ['bazel-out/test.dill'],
    'exitCode': 0,
  })!;

  final testRunnerSpawn = parseSpawnMap({
    'commandArgs': ['test_runner', 'TestRunner'],
    'inputs': ['bazel-out/test.dill'],
    'listedOutputs': [
      'bazel-out/testlogs/test.log',
      'bazel-out/testlogs/test.xml',
      'bazel-out/testlogs/test.cache_status',
    ],
    'exitCode': 0,
  })!;

  final chain = [compileSpawn, testRunnerSpawn];
  final verifySet = selectLeafTestVerifyPaths(chain);

  _check(
    verifySet.contains('bazel-out/test.dill'),
    'Compiled .dill is in verify set',
  );
  _check(
    !verifySet.contains('bazel-out/testlogs/test.log'),
    'test.log excluded from verify set',
  );
  _check(
    !verifySet.contains('bazel-out/testlogs/test.xml'),
    'test.xml excluded from verify set',
  );
  _check(
    !verifySet.contains('bazel-out/testlogs/test.cache_status'),
    'test.cache_status excluded from verify set',
  );
}

void main() {
  _testConcatenatedJsonParsing();
  _testExecConfigFiltering();
  _testDependencyOrderingAndRefusal();
  _testLeafTestVerifySet();
  stdout.writeln('All spawn_log tests passed.');
}
