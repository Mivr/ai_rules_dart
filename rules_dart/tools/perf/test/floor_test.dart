/// Unit tests for toolchain floor construction and verification.
library;

import 'dart:convert';
import 'dart:io';

import 'package:perf/cpu.dart';
import 'package:perf/floor.dart';
import 'package:perf/floor_chains.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

void _createFakeSdk(Directory dir, {Set<String> skip = const {}}) {
  final exeExt = Platform.isWindows ? '.exe' : '';
  final files = <String, String>{
    'dart': 'bin/dart$exeExt',
    'dartaotruntime': 'bin/dartaotruntime$exeExt',
    'gen_snapshot': 'bin/utils/gen_snapshot$exeExt',
    'gen_kernel_aot': 'bin/snapshots/gen_kernel_aot.dart.snapshot',
    'frontend_server': 'bin/snapshots/frontend_server_aot.dart.snapshot',
    'vm_platform_product.dill': 'lib/_internal/vm_platform_product.dill',
    'vm_platform_strong.dill': 'lib/_internal/vm_platform_strong.dill',
  };
  for (final entry in files.entries) {
    if (skip.contains(entry.key)) continue;
    final f = File('${dir.path}/${entry.value}');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('fake binary');
  }
}

void _testMissingTools() {
  final requiredTools = [
    'dart',
    'dartaotruntime',
    'gen_snapshot',
    'gen_kernel_aot',
    'frontend_server',
    'vm_platform_product.dill',
    'vm_platform_strong.dill',
  ];

  for (final tool in requiredTools) {
    final tempDir = Directory.systemTemp.createTempSync('sdk_test_');
    try {
      _createFakeSdk(tempDir, skip: {tool});
      var threw = false;
      try {
        SdkTools.fromSdkDir(tempDir.path);
      } on StateError catch (e) {
        threw = true;
        _check(
          e.message.contains(tool),
          'Missing tool error for $tool names itself: "${e.message}"',
        );
      }
      _check(threw, 'SdkTools.fromSdkDir throws when $tool is missing');
    } finally {
      tempDir.deleteSync(recursive: true);
    }
  }
}

void _testChainConstruction() {
  final tempDir = Directory.systemTemp.createTempSync('sdk_test_');
  try {
    _createFakeSdk(tempDir);
    final sdk = SdkTools.fromSdkDir(tempDir.path);

    // 1. Clean / API flow: AOT chain
    final aotSpec = AppAotChainSpec(
      sdk: sdk,
      entrypoint: '/ws/app/bin/main.dart',
      outputDill: '/ws/out/app.dill',
      outputAot: '/ws/out/app.aot',
    );
    final aotSteps = buildAppAotChain(aotSpec);
    _check(aotSteps.length == 2, 'AOT chain has 2 steps');
    _check(
      aotSteps[0].executable == sdk.dartaotruntime,
      'AOT step 1 starts with dartaotruntime',
    );
    _check(
      aotSteps[0].arguments[0] == sdk.genKernelSnapshot,
      'AOT step 1 runs gen_kernel snapshot',
    );
    _check(
      aotSteps[0].arguments.contains(sdk.platformProductDill),
      'AOT step 1 uses vm_platform_product.dill',
    );
    _check(
      aotSteps[1].executable == sdk.genSnapshot,
      'AOT step 2 runs gen_snapshot',
    );
    _check(
      aotSteps[1].arguments.contains('--snapshot_kind=app-aot-elf'),
      'AOT step 2 targets app-aot-elf',
    );

    // 2. Body flow: incremental compiler step
    final incSpec = IncrementalCompilerSpec(
      sdk: sdk,
      outputDill: '/ws/out/app.dill',
    );
    final incStep = buildIncrementalCompilerStep(incSpec);
    _check(
      incStep.executable == sdk.dartaotruntime,
      'Incremental step starts with dartaotruntime',
    );
    _check(
      incStep.arguments[0] == sdk.frontendServerSnapshot,
      'Incremental step runs frontend_server snapshot',
    );
    _check(
      incStep.arguments.contains('--incremental'),
      'Incremental step specifies --incremental',
    );
    _check(
      incStep.arguments.contains('--target=vm'),
      'Incremental step targets vm',
    );

    // 3. Leaf test flow: test runner step on prebuilt dill
    final testStep = buildTestRunnerStep(
      sdk: sdk,
      testDill: '/ws/out/pkg0_test.dill',
    );
    _check(
      testStep.executable == sdk.dart,
      'Test runner step starts with dart VM',
    );
    _check(
      testStep.arguments.length == 1 &&
          testStep.arguments[0] == '/ws/out/pkg0_test.dill',
      'Test runner step runs test dill',
    );
  } finally {
    tempDir.deleteSync(recursive: true);
  }
}

final class _FakeClock implements ChildCpuClock {
  const _FakeClock(this.cpu);
  final double cpu;

  @override
  double getChildCpuSeconds() => cpu;
}

final class _MockProcessRunner implements FloorProcessRunner {
  const _MockProcessRunner({
    this.exitCode = 0,
    this.stdoutText = 'Result: 42\n',
    this.stderrText = '',
  });

  final int exitCode;
  final String stdoutText;
  final String stderrText;

  @override
  ProcessResult runSync(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    return ProcessResult(0, exitCode, stdoutText, stderrText);
  }
}

void _testAotOutputChecks(String root, SdkTools sdk, ChildCpuClock clock) {
  final okRunner = _MockProcessRunner(stdoutText: 'Result: 100\n');
  var res = runAotFloorFlow(
    sdk: sdk,
    workspaceDir: root,
    floorOutputDir: '$root/out',
    bazelAppExecutable: '$root/bazel_app',
    clock: clock,
    runner: okRunner,
  );
  _check(res.identical, 'Matching stdout is identical');
  _check(res.reason == 'ok', 'Matching reason is ok');
  _check(res.floorKind == 'aot', 'Clean/API floor kind is aot');

  final diffRunner = _DynamicRunner((exe, args) {
    if (exe == sdk.dartaotruntime && args.contains('$root/out/app.aot')) {
      return ProcessResult(1, 0, 'Result: 100\n', '');
    }
    return ProcessResult(2, 0, 'Result: 200\n', '');
  });
  res = runAotFloorFlow(
    sdk: sdk,
    workspaceDir: root,
    floorOutputDir: '$root/out',
    bazelAppExecutable: '$root/bazel_app',
    clock: clock,
    runner: diffRunner,
  );
  _check(!res.identical, 'Differing stdout is not identical');
  _check(res.reason.contains('differs'), 'Differing reason explains mismatch');

  final failRunner = _MockProcessRunner(
    exitCode: 1,
    stderrText: 'Compile failed',
  );
  res = runAotFloorFlow(
    sdk: sdk,
    workspaceDir: root,
    floorOutputDir: '$root/out',
    bazelAppExecutable: '$root/bazel_app',
    clock: clock,
    runner: failRunner,
  );
  _check(!res.identical, 'Failed process is not identical');
  _check(res.reason != 'ok', 'Failed process reason is non-ok');

  final crashOutputRunner = _DynamicRunner((exe, args) {
    if (exe == sdk.dartaotruntime && args.contains('$root/out/app.aot')) {
      throw const ProcessException('dartaotruntime', [], 'exec format error');
    }
    return ProcessResult(1, 0, 'Result: 100\n', '');
  });
  res = runAotFloorFlow(
    sdk: sdk,
    workspaceDir: root,
    floorOutputDir: '$root/out',
    bazelAppExecutable: '$root/bazel_app',
    clock: clock,
    runner: crashOutputRunner,
  );
  _check(!res.identical, 'Non-runnable floor output is not identical');
  _check(
    res.reason.contains('Floor AOT output failed'),
    'Non-runnable floor output reason explains failure',
  );
}

void _testBodyAndTestChecks(String root, SdkTools sdk, ChildCpuClock clock) {
  final passTest = runTestLeafFloorFlow(
    sdk: sdk,
    workspaceDir: root,
    testDillPath: '$root/test.dill',
    clock: clock,
    runner: _MockProcessRunner(exitCode: 0),
  );
  _check(passTest.identical, 'Passing test is identical');
  _check(passTest.reason == 'ok', 'Passing test reason is ok');

  final failTest = runTestLeafFloorFlow(
    sdk: sdk,
    workspaceDir: root,
    testDillPath: '$root/test.dill',
    clock: clock,
    runner: _MockProcessRunner(exitCode: 1, stderrText: '1 test failed'),
  );
  _check(!failTest.identical, 'Failing test is not identical');
  _check(failTest.reason != 'ok', 'Failing test reason is non-ok');

  final bodyPassRunner = _DynamicRunner((exe, args) {
    if (args.any((a) => a.contains('incremental_driver'))) {
      return ProcessResult(
        1,
        0,
        jsonEncode({
          'status': 'ok',
          'cpuSeconds': 0.08,
          'outputDill': '$root/out/app.dill.incremental.dill',
        }),
        '',
      );
    }
    return ProcessResult(2, 0, 'Result: 2048\n', '');
  });
  final bodyPass = runIncrementalBodyFloorFlow(
    sdk: sdk,
    workspaceDir: root,
    floorOutputDir: '$root/out',
    edit: BodyFloorEdit(
      editedFile: '$root/f0.dart',
      bazelAppExecutable: '$root/bazel_app',
    ),
    runner: bodyPassRunner,
  );
  _check(bodyPass.identical, 'Body floor is identical when stdout matches');
  _check(bodyPass.reason == 'ok', 'Body floor reason is ok');
  _check(bodyPass.floorKind == 'jit', 'Body floor kind is jit');
  _check(bodyPass.cpuSeconds == 0.08, 'Body floor cpuSeconds matches driver');

  final bodyDiffRunner = _DynamicRunner((exe, args) {
    if (args.any((a) => a.contains('incremental_driver'))) {
      return ProcessResult(
        1,
        0,
        jsonEncode({
          'status': 'ok',
          'cpuSeconds': 0.08,
          'outputDill': '$root/out/app.dill',
        }),
        '',
      );
    }
    if (args.contains('$root/out/app.dill')) {
      return ProcessResult(2, 0, 'Result: 1\n', '');
    }
    return ProcessResult(3, 0, 'Result: 2\n', '');
  });
  final bodyDiff = runIncrementalBodyFloorFlow(
    sdk: sdk,
    workspaceDir: root,
    floorOutputDir: '$root/out',
    edit: BodyFloorEdit(
      editedFile: '$root/f0.dart',
      bazelAppExecutable: '$root/bazel_app',
    ),
    runner: bodyDiffRunner,
  );
  _check(!bodyDiff.identical, 'Body floor differs when stdout differs');
  _check(
    bodyDiff.reason.contains('differs'),
    'Body floor failure explains diff',
  );
}

void _testOutputChecks() {
  final tempDir = Directory.systemTemp.createTempSync('sdk_test_');
  try {
    _createFakeSdk(tempDir);
    final sdk = SdkTools.fromSdkDir(tempDir.path);
    final root = tempDir.path.replaceAll(r'\', '/');
    const clock = _FakeClock(1.5);
    _testAotOutputChecks(root, sdk, clock);
    _testBodyAndTestChecks(root, sdk, clock);
  } finally {
    tempDir.deleteSync(recursive: true);
  }
}

final class _DynamicRunner implements FloorProcessRunner {
  _DynamicRunner(this.handler);
  final ProcessResult Function(String exe, List<String> args) handler;

  @override
  ProcessResult runSync(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) => handler(executable, arguments);
}

void main() {
  _testMissingTools();
  _testChainConstruction();
  _testOutputChecks();
  stdout.writeln('All floor tests passed.');
}
