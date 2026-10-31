/// Unit tests for chain replay and byte-identical verification.
library;

import 'dart:io';

import 'package:perf/cpu.dart';
import 'package:perf/replay.dart';
import 'package:perf/spawn_log.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

void _testReplayIdenticalAndRestore() {
  final tempDir = Directory.systemTemp.createTempSync('rd_replay_test_');
  try {
    final execroot = tempDir.path;
    final outDir = Directory('$execroot/bazel-out')
      ..createSync(recursive: true);
    final outFile = File('${outDir.path}/app.dill')
      ..writeAsStringSync('ORIGINAL_BYTES_123');

    // Create a script or command to produce the same file
    final script = File('$execroot/mock_compile.sh');
    script.writeAsStringSync('''#!/bin/sh
mkdir -p bazel-out
printf "ORIGINAL_BYTES_123" > bazel-out/app.dill
''');
    if (Platform.isLinux || Platform.isMacOS) {
      Process.runSync('chmod', ['+x', script.path]);
    }

    final spawn = SpawnRecord(
      commandArgs: ['/bin/sh', script.path],
      environmentVariables: {},
      inputs: [],
      listedOutputs: ['bazel-out/app.dill'],
      actualOutputs: [],
      runner: 'local',
      exitCode: 0,
      isCached: false,
    );

    final clock = FakeChildCpuClock([0.0, 0.05]);
    final result = replayChainAndVerify(
      orderedSpawns: [spawn],
      execroot: execroot,
      verifyPaths: {'bazel-out/app.dill'},
      clock: clock,
    );

    _check(result.identical, 'Replay was byte-identical');
    _check(result.reason == 'ok', 'Reason is ok');
    _check(result.solCpuSeconds == 0.05, 'CPU measured 0.05s');

    // Verify original outputs restored
    _check(outFile.existsSync(), 'Original output restored in place');
    _check(
      outFile.readAsStringSync() == 'ORIGINAL_BYTES_123',
      'Content restored',
    );
  } finally {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // Best-effort cleanup.
    }
  }
}

void _testReplayMismatchAndFailure() {
  final tempDir = Directory.systemTemp.createTempSync('rd_replay_mismatch_');
  try {
    final execroot = tempDir.path;
    final outDir = Directory('$execroot/bazel-out')
      ..createSync(recursive: true);
    File('${outDir.path}/app.dill').writeAsStringSync('ORIGINAL');

    final script = File('$execroot/mock_bad_compile.sh');
    script.writeAsStringSync('''#!/bin/sh
mkdir -p bazel-out
printf "DIFFERENT" > bazel-out/app.dill
''');
    if (Platform.isLinux || Platform.isMacOS) {
      Process.runSync('chmod', ['+x', script.path]);
    }

    final spawn = SpawnRecord(
      commandArgs: ['/bin/sh', script.path],
      environmentVariables: {},
      inputs: [],
      listedOutputs: ['bazel-out/app.dill'],
      actualOutputs: [],
      runner: 'local',
      exitCode: 0,
      isCached: false,
    );

    final clock = FakeChildCpuClock([0.0, 0.02]);
    final result = replayChainAndVerify(
      orderedSpawns: [spawn],
      execroot: execroot,
      verifyPaths: {'bazel-out/app.dill'},
      clock: clock,
    );

    _check(!result.identical, 'Detected mismatch');
    _check(result.solCpuSeconds == null, 'solCpuSeconds is null on mismatch');
    _check(
      result.reason.contains('Byte mismatch'),
      'Reason contains Byte mismatch',
    );
  } finally {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // Best-effort cleanup.
    }
  }
}

void _testNonZeroTestRunnerFails() {
  final tempDir = Directory.systemTemp.createTempSync('rd_test_fail_');
  try {
    final execroot = tempDir.path;
    final script = File('$execroot/failing_test.sh');
    script.writeAsStringSync('''#!/bin/sh
exit 1
''');
    if (Platform.isLinux || Platform.isMacOS) {
      Process.runSync('chmod', ['+x', script.path]);
    }

    final spawn = SpawnRecord(
      commandArgs: ['/bin/sh', script.path, 'TestRunner'],
      environmentVariables: {},
      inputs: [],
      listedOutputs: ['bazel-out/testlogs/test.log'],
      actualOutputs: [],
      runner: 'local',
      exitCode: 0,
      isCached: false,
    );

    final clock = FakeChildCpuClock([0.0, 0.01]);
    final result = replayChainAndVerify(
      orderedSpawns: [spawn],
      execroot: execroot,
      verifyPaths: {},
      clock: clock,
      isTestFlow: true,
    );

    _check(!result.identical, 'Non-zero TestRunner fails replay');
    _check(result.solCpuSeconds == null, 'solCpuSeconds null on failure');
    _check(
      result.reason.contains('TestRunner failed with exit code 1'),
      'Reason reports TestRunner failure, got: ${result.reason}',
    );
  } finally {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // Best-effort cleanup.
    }
  }
}

void main() {
  _testReplayIdenticalAndRestore();
  _testReplayMismatchAndFailure();
  _testNonZeroTestRunnerFails();
  stdout.writeln('All replay tests passed.');
}
