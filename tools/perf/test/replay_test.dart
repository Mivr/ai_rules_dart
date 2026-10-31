/// Unit tests for chain replay, side-effect sweeping and output verification.
library;

import 'dart:io';

import 'package:perf/cpu.dart';
import 'package:perf/replay.dart';
import 'package:perf/spawn_log.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

void _cleanupDir(Directory dir) {
  try {
    dir.deleteSync(recursive: true);
  } on FileSystemException catch (e) {
    stderr.writeln('Temp directory cleanup skipped (${dir.path}): $e');
  }
}

List<SpawnRecord> _setupMultiStepExecroot(String execroot) {
  Directory('$execroot/src').createSync(recursive: true);
  File('$execroot/src/keep.dart').writeAsStringSync('// keep\n');

  final kmodDir = Directory('$execroot/bazel-out/pkg0.kmod')
    ..createSync(recursive: true);
  File('${kmodDir.path}/module.dill').writeAsStringSync('KMOD_BYTES_V1');
  File('$execroot/bazel-out/app.dill').writeAsStringSync('KMOD_BYTES_V1_OK');

  final step1Script = File('$execroot/src/step1.dart')
    ..writeAsStringSync('''
import 'dart:io';

void main() {
  Directory('bazel-out/pkg0.kmod').createSync(recursive: true);
  File('bazel-out/pkg0.kmod/module.dill').writeAsStringSync('KMOD_BYTES_V1');
  File('bazel-out/undeclared.tmp').writeAsStringSync('LEAKED_FILE');
  Directory('undeclared_dir').createSync(recursive: true);
  File('undeclared_dir/leak.txt').writeAsStringSync('LEAKED_DIR_FILE');
}
''');

  final step2Script = File('$execroot/src/step2.dart')
    ..writeAsStringSync('''
import 'dart:io';

void main() {
  final mod = File('bazel-out/pkg0.kmod/module.dill').readAsStringSync();
  final envTag = Platform.environment['REPLAY_TAG'] ?? '';
  File('bazel-out/app.dill').writeAsStringSync('\${mod}_\$envTag');
}
''');

  return [
    SpawnRecord(
      commandArgs: [Platform.resolvedExecutable, step1Script.path],
      environmentVariables: const {},
      inputs: const ['src/keep.dart'],
      listedOutputs: const ['bazel-out/pkg0.kmod'],
      actualOutputs: const [],
      runner: 'local',
      exitCode: 0,
      isCached: false,
    ),
    SpawnRecord(
      commandArgs: [Platform.resolvedExecutable, step2Script.path],
      environmentVariables: const {'REPLAY_TAG': 'OK'},
      inputs: const ['bazel-out/pkg0.kmod/module.dill'],
      listedOutputs: const ['bazel-out/app.dill'],
      actualOutputs: const [],
      runner: 'worker',
      exitCode: 0,
      isCached: false,
    ),
  ];
}

void _testFileAndTreeReplayAndSideEffectSweep() {
  final tempDir = Directory.systemTemp.createTempSync('rd_replay_ok_');
  try {
    final execroot = tempDir.path;
    final spawns = _setupMultiStepExecroot(execroot);
    final clock = FakeChildCpuClock([1.0, 1.04, 1.04, 1.10]);
    final result = replayChainAndVerify(
      orderedSpawns: spawns,
      execroot: execroot,
      verifyPaths: {'bazel-out/pkg0.kmod', 'bazel-out/app.dill'},
      clock: clock,
    );

    _check(result.identical, 'Multi-step file + tree replay identical');
    _check(result.reason == 'ok', 'Reason is ok');
    _check(
      ((result.solCpuSeconds ?? 0) - 0.10).abs() < 1e-6,
      'Summed per-step CPU deltas (0.04 + 0.06 = 0.10)',
    );
    _check(
      !File('$execroot/bazel-out/undeclared.tmp').existsSync(),
      'Swept undeclared file inside bazel-out',
    );
    _check(
      !Directory('$execroot/undeclared_dir').existsSync(),
      'Swept undeclared directory in execroot',
    );
    _check(
      File('$execroot/src/keep.dart').existsSync(),
      'Preserved pre-existing source file',
    );
    _check(
      File('$execroot/bazel-out/app.dill').readAsStringSync() ==
          'KMOD_BYTES_V1_OK',
      'Restored original app.dill output',
    );
    _check(
      File('$execroot/bazel-out/pkg0.kmod/module.dill').readAsStringSync() ==
          'KMOD_BYTES_V1',
      'Restored original tree artifact output',
    );
  } finally {
    _cleanupDir(tempDir);
  }
}

void _testMismatchRestoresOriginalOutputs() {
  final tempDir = Directory.systemTemp.createTempSync('rd_replay_mismatch_');
  try {
    final execroot = tempDir.path;
    Directory('$execroot/bazel-out').createSync(recursive: true);
    final outFile = File('$execroot/bazel-out/app.dill')
      ..writeAsStringSync('BAZEL_ORIGINAL_BYTES');

    final badScript = File('$execroot/bad_compile.dart')
      ..writeAsStringSync('''
import 'dart:io';

void main() {
  Directory('bazel-out').createSync(recursive: true);
  File('bazel-out/app.dill').writeAsStringSync('DRIFTED_REPLAY_BYTES');
}
''');

    final spawn = SpawnRecord(
      commandArgs: [Platform.resolvedExecutable, badScript.path],
      environmentVariables: const {},
      inputs: const [],
      listedOutputs: const ['bazel-out/app.dill'],
      actualOutputs: const [],
      runner: 'local',
      exitCode: 0,
      isCached: false,
    );

    final result = replayChainAndVerify(
      orderedSpawns: [spawn],
      execroot: execroot,
      verifyPaths: {'bazel-out/app.dill'},
      clock: FakeChildCpuClock([0.0, 0.02]),
    );

    _check(!result.identical, 'Detected byte mismatch');
    _check(result.solCpuSeconds == null, 'solCpuSeconds is null on mismatch');
    _check(result.reason.contains('Byte mismatch'), 'Reason reports mismatch');
    _check(
      outFile.readAsStringSync() == 'BAZEL_ORIGINAL_BYTES',
      'Bazel original bytes restored even after failed replay',
    );
  } finally {
    _cleanupDir(tempDir);
  }
}

SpawnRecord _makeTestFlowSpawn({
  required String mnemonic,
  required String scriptPath,
  required String output,
  List<String> inputs = const [],
}) {
  return SpawnRecord(
    mnemonic: mnemonic,
    commandArgs: [Platform.resolvedExecutable, scriptPath],
    environmentVariables: const {},
    inputs: inputs,
    listedOutputs: [output],
    actualOutputs: const [],
    runner: 'local',
    exitCode: 0,
    isCached: false,
  );
}

void _testLeafTestRunnerPassAndFail() {
  final tempDir = Directory.systemTemp.createTempSync('rd_replay_testflow_');
  try {
    final execroot = tempDir.path;
    Directory('$execroot/bazel-out/testlogs').createSync(recursive: true);
    File('$execroot/bazel-out/test.dill').writeAsStringSync('COMPILED_DILL');
    File('$execroot/bazel-out/testlogs/test.log')
        .writeAsStringSync('elapsed: 12ms\n');

    final compileScript = File('$execroot/compile_test.dart')
      ..writeAsStringSync(
        'import "dart:io"; void main() => '
        'File("bazel-out/test.dill").writeAsStringSync("COMPILED_DILL");\n',
      );
    final passScript = File('$execroot/pass_runner.dart')
      ..writeAsStringSync(
        'import "dart:io"; void main() {\n'
        '  Directory("bazel-out/testlogs").createSync(recursive: true);\n'
        '  File("bazel-out/testlogs/test.log").writeAsStringSync("99ms\\n");\n'
        '}\n',
      );
    final failScript = File('$execroot/fail_runner.dart')
      ..writeAsStringSync('import "dart:io"; void main() => exit(1);\n');

    final compileSpawn = _makeTestFlowSpawn(
      mnemonic: 'DartKernelLink',
      scriptPath: compileScript.path,
      output: 'bazel-out/test.dill',
    );
    final passSpawn = _makeTestFlowSpawn(
      mnemonic: 'TestRunner',
      scriptPath: passScript.path,
      output: 'bazel-out/testlogs/test.log',
      inputs: const ['bazel-out/test.dill'],
    );
    final passChain = [compileSpawn, passSpawn];
    final verifyPaths = selectLeafTestVerifyPaths(passChain);

    final passRes = replayChainAndVerify(
      orderedSpawns: passChain,
      execroot: execroot,
      verifyPaths: verifyPaths,
      clock: FakeChildCpuClock([0.0, 0.03, 0.03, 0.08]),
      isTestFlow: true,
    );
    _check(passRes.identical, 'Passing TestRunner with differing test.log ok');

    final failSpawn = _makeTestFlowSpawn(
      mnemonic: 'TestRunner',
      scriptPath: failScript.path,
      output: 'bazel-out/testlogs/test.log',
      inputs: const ['bazel-out/test.dill'],
    );
    final failRes = replayChainAndVerify(
      orderedSpawns: [compileSpawn, failSpawn],
      execroot: execroot,
      verifyPaths: verifyPaths,
      clock: FakeChildCpuClock([0.0, 0.03, 0.03, 0.05]),
      isTestFlow: true,
    );
    _check(!failRes.identical, 'Non-zero TestRunner fails replay');
    _check(failRes.solCpuSeconds == null, 'solCpuSeconds null on test failure');
    _check(
      failRes.reason.contains('TestRunner failed with exit code 1'),
      'Reason reports TestRunner failure: ${failRes.reason}',
    );
  } finally {
    _cleanupDir(tempDir);
  }
}

void main() {
  _testFileAndTreeReplayAndSideEffectSweep();
  _testMismatchRestoresOriginalOutputs();
  _testLeafTestRunnerPassAndFail();
  stdout.writeln('All replay tests passed.');
}
