/// Low-level SDK toolchain floor execution and verification.
library;

import 'dart:convert';
import 'dart:io';

import 'cli_args.dart';
import 'cpu.dart';
import 'floor_chains.dart';
import 'result_writer.dart';

/// The result of executing a toolchain floor chain for one flow.
final class FloorResult {
  /// Creates a floor result record.
  const FloorResult({
    required this.cpuSeconds,
    required this.identical,
    required this.reason,
    required this.floorKind,
  });

  /// Timed CPU seconds measured for the floor step(s).
  final double? cpuSeconds;

  /// Whether the floor output executed cleanly and matched Bazel output.
  final bool identical;

  /// Failure reason, or "ok" if successful.
  final String reason;

  /// Floor kind: "aot" or "jit".
  final String floorKind;
}

/// Interface for executing commands in the floor environment.
abstract interface class FloorProcessRunner {
  /// Runs a process to completion synchronously.
  ProcessResult runSync(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  });
}

/// Default process runner invoking [Process.runSync].
final class DefaultFloorProcessRunner implements FloorProcessRunner {
  /// Creates a default process runner.
  const DefaultFloorProcessRunner();

  @override
  ProcessResult runSync(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    return Process.runSync(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: cleanProcessEnvironment(overlay: environment ?? const {}),
      includeParentEnvironment: false,
    );
  }
}

/// Resolves the absolute path to `incremental_driver.dart`.
String resolveIncrementalDriverPath(String workspaceDir) {
  final candidates = [
    '$workspaceDir/tools/perf/lib/incremental_driver.dart',
    '${Directory.current.path}/tools/perf/lib/incremental_driver.dart',
    '${Directory.current.path}/lib/incremental_driver.dart',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return resolveCliPath(candidate);
  }
  return resolveCliPath('$workspaceDir/tools/perf/lib/incremental_driver.dart');
}

ProcessResult _runExecutableOrAot(
  FloorProcessRunner runner,
  SdkTools sdk,
  String binaryPath,
  String workingDirectory,
) {
  try {
    return runner.runSync(
      binaryPath,
      const [],
      workingDirectory: workingDirectory,
    );
  } on ProcessException {
    return runner.runSync(sdk.dartaotruntime, [
      binaryPath,
    ], workingDirectory: workingDirectory);
  }
}

(double, String?) _executeFloorSteps(
  List<ToolchainStep> steps,
  ChildCpuClock clock,
  FloorProcessRunner runner,
) {
  var totalCpu = 0.0;
  for (final step in steps) {
    final beforeCpu = clock.getChildCpuSeconds();
    final res = runner.runSync(
      step.executable,
      step.arguments,
      workingDirectory: step.workingDirectory,
      environment: step.environment,
    );
    final afterCpu = clock.getChildCpuSeconds();
    final stepCpu = afterCpu - beforeCpu;
    if (stepCpu > 0) totalCpu += stepCpu;

    if (res.exitCode != 0) {
      return (
        totalCpu,
        'Floor tool ${step.executable} failed (exit ${res.exitCode}): ${res.stderr}',
      );
    }
  }
  return (totalCpu, null);
}

String? _verifyFloorRun({
  required FloorProcessRunner runner,
  required SdkTools sdk,
  required ProcessResult floorRun,
  required String floorLabel,
  required String bazelAppExecutable,
  required String workspaceDir,
}) {
  if (floorRun.exitCode != 0) {
    return '$floorLabel output failed to run (exit ${floorRun.exitCode}): ${floorRun.stderr}';
  }
  final bazelRun = _runExecutableOrAot(
    runner,
    sdk,
    bazelAppExecutable,
    workspaceDir,
  );
  if (bazelRun.exitCode != 0) {
    return 'Bazel app failed to run (exit ${bazelRun.exitCode}): ${bazelRun.stderr}';
  }
  if (floorRun.stdout != bazelRun.stdout) {
    return '$floorLabel output differs from Bazel output';
  }
  return null;
}

/// Runs the AOT compiler chain for clean or api flows and verifies output.
FloorResult runAotFloorFlow({
  required SdkTools sdk,
  required String workspaceDir,
  required String floorOutputDir,
  required String bazelAppExecutable,
  required ChildCpuClock clock,
  FloorProcessRunner runner = const DefaultFloorProcessRunner(),
}) {
  final outAot = '$floorOutputDir/app.aot';
  Directory(floorOutputDir).createSync(recursive: true);

  final spec = AppAotChainSpec(
    sdk: sdk,
    entrypoint: '$workspaceDir/app/bin/main.dart',
    outputDill: '$floorOutputDir/app.dill',
    outputAot: outAot,
    workingDirectory: workspaceDir,
  );
  final (totalCpu, stepErr) = _executeFloorSteps(
    buildAppAotChain(spec),
    clock,
    runner,
  );
  if (stepErr != null) {
    return FloorResult(
      cpuSeconds: totalCpu,
      identical: false,
      reason: stepErr,
      floorKind: 'aot',
    );
  }

  final floorRun = runner.runSync(
    sdk.dartaotruntime,
    [outAot],
    workingDirectory: workspaceDir,
  );
  final verifyErr = _verifyFloorRun(
    runner: runner,
    sdk: sdk,
    floorRun: floorRun,
    floorLabel: 'Floor AOT',
    bazelAppExecutable: bazelAppExecutable,
    workspaceDir: workspaceDir,
  );
  if (verifyErr != null) {
    return FloorResult(
      cpuSeconds: totalCpu,
      identical: false,
      reason: verifyErr,
      floorKind: 'aot',
    );
  }

  return FloorResult(
    cpuSeconds: totalCpu,
    identical: true,
    reason: 'ok',
    floorKind: 'aot',
  );
}

(Map<String, dynamic>?, String?) _runDriverProcess({
  required FloorProcessRunner runner,
  required SdkTools sdk,
  required String workspaceDir,
  required String entrypoint,
  required String outDill,
  required String editedFile,
}) {
  final driverPath = resolveIncrementalDriverPath(workspaceDir);
  final driverRes = runner.runSync(sdk.dart, [
    driverPath,
    '--sdk-root=${sdk.sdkRoot}',
    '--dartaotruntime=${sdk.dartaotruntime}',
    '--frontend-server=${sdk.frontendServerSnapshot}',
    '--platform=${sdk.platformStrongDill}',
    '--entrypoint=$entrypoint',
    '--output-dill=$outDill',
    '--edited-file=$editedFile',
    '--mode=body',
  ], workingDirectory: workspaceDir);

  if (driverRes.exitCode != 0) {
    return (
      null,
      'Incremental driver failed (exit ${driverRes.exitCode}): ${driverRes.stderr}',
    );
  }
  try {
    final data =
        jsonDecode((driverRes.stdout as String).trim()) as Map<String, dynamic>;
    if (data['status'] != 'ok') {
      return (null, data['reason'] as String? ?? 'Incremental compile error');
    }
    return (data, null);
  } on FormatException catch (e) {
    return (null, 'Malformed driver output: $e');
  }
}

/// Runs the incremental JIT compiler floor for body edit and verifies output.
FloorResult runIncrementalBodyFloorFlow({
  required SdkTools sdk,
  required String workspaceDir,
  required String floorOutputDir,
  required String editedFile,
  required String bazelAppExecutable,
  FloorProcessRunner runner = const DefaultFloorProcessRunner(),
}) {
  final outDill = '$floorOutputDir/app.dill';
  Directory(floorOutputDir).createSync(recursive: true);

  final (driverData, driverErr) = _runDriverProcess(
    runner: runner,
    sdk: sdk,
    workspaceDir: workspaceDir,
    entrypoint: '$workspaceDir/app/bin/main.dart',
    outDill: outDill,
    editedFile: editedFile,
  );
  if (driverErr != null || driverData == null) {
    return FloorResult(
      cpuSeconds: null,
      identical: false,
      reason: driverErr ?? 'Incremental driver failed',
      floorKind: 'jit',
    );
  }

  final finalDill = driverData['outputDill'] as String? ?? outDill;
  final cpuSeconds = (driverData['cpuSeconds'] as num?)?.toDouble() ?? 0.0;

  final floorRun = runner.runSync(
    sdk.dart,
    [finalDill],
    workingDirectory: workspaceDir,
  );
  final verifyErr = _verifyFloorRun(
    runner: runner,
    sdk: sdk,
    floorRun: floorRun,
    floorLabel: 'Floor incremental',
    bazelAppExecutable: bazelAppExecutable,
    workspaceDir: workspaceDir,
  );
  if (verifyErr != null) {
    return FloorResult(
      cpuSeconds: cpuSeconds,
      identical: false,
      reason: verifyErr,
      floorKind: 'jit',
    );
  }

  return FloorResult(
    cpuSeconds: cpuSeconds,
    identical: true,
    reason: 'ok',
    floorKind: 'jit',
  );
}

/// Runs the leaf test runner floor on a prebuilt test dill and verifies it passes.
FloorResult runTestLeafFloorFlow({
  required SdkTools sdk,
  required String workspaceDir,
  required String testDillPath,
  required ChildCpuClock clock,
  FloorProcessRunner runner = const DefaultFloorProcessRunner(),
}) {
  final step = buildTestRunnerStep(sdk: sdk, testDill: testDillPath);
  final beforeCpu = clock.getChildCpuSeconds();
  final testRun = runner.runSync(
    step.executable,
    step.arguments,
    workingDirectory: workspaceDir,
  );
  final afterCpu = clock.getChildCpuSeconds();
  final totalCpu = afterCpu - beforeCpu;

  if (testRun.exitCode != 0) {
    return FloorResult(
      cpuSeconds: totalCpu > 0 ? totalCpu : 0.0,
      identical: false,
      reason:
          'Floor leaf test failed with exit code ${testRun.exitCode}: ${testRun.stderr}',
      floorKind: 'aot',
    );
  }

  return FloorResult(
    cpuSeconds: totalCpu > 0 ? totalCpu : 0.0,
    identical: true,
    reason: 'ok',
    floorKind: 'aot',
  );
}

/// Execution context for attaching floor results to a flow.
final class FloorFlowContext {
  /// Creates a floor flow execution context.
  const FloorFlowContext({
    required this.sdk,
    required this.workspaceDir,
    required this.outputDir,
    required this.clock,
    this.runner = const DefaultFloorProcessRunner(),
  });

  /// Resolved SDK tools.
  final SdkTools? sdk;

  /// Workspace directory.
  final String workspaceDir;

  /// Output directory for intermediate floor artifacts.
  final String outputDir;

  /// CPU clock.
  final ChildCpuClock clock;

  /// Process runner.
  final FloorProcessRunner runner;
}

FlowResult _combineReplayAndFloor(FlowResult replay, FloorResult floor) {
  return FlowResult.withFloor(
    method: replay.method,
    bazelCpu: replay.bazelCpu,
    replay: FlowReplayData(
      solCpu: replay.solCpu,
      identical: replay.identical,
      reason: replay.reason,
      chain: replay.chain,
      workerSteps: replay.workerSteps,
    ),
    floor: FlowFloorData(
      cpuSeconds: floor.cpuSeconds,
      reason: floor.reason,
      floorKind: floor.floorKind,
      identical: floor.identical,
      enabled: true,
    ),
  );
}

FlowResult _combineReplayAndFloorError(
  FlowResult replay,
  String reason,
  String kind,
) {
  return FlowResult.withFloor(
    method: replay.method,
    bazelCpu: replay.bazelCpu,
    replay: FlowReplayData(
      solCpu: replay.solCpu,
      identical: replay.identical,
      reason: replay.reason,
      chain: replay.chain,
      workerSteps: replay.workerSteps,
    ),
    floor: FlowFloorData(
      cpuSeconds: null,
      reason: reason,
      floorKind: kind,
      identical: false,
      enabled: true,
    ),
  );
}

FlowResult _attachAotFloor(
  FloorFlowContext ctx,
  FlowResult replayFlow,
  String bazelAppExecutable,
  String flowLabel,
) {
  final sdk = ctx.sdk;
  if (sdk == null) {
    return _combineReplayAndFloorError(
      replayFlow,
      'Could not locate workspace Dart SDK',
      'aot',
    );
  }
  try {
    final floorRes = runAotFloorFlow(
      sdk: sdk,
      workspaceDir: ctx.workspaceDir,
      floorOutputDir: ctx.outputDir,
      bazelAppExecutable: bazelAppExecutable,
      clock: ctx.clock,
      runner: ctx.runner,
    );
    return _combineReplayAndFloor(replayFlow, floorRes);
  } on Object catch (e) {
    stderr.writeln('$flowLabel floor execution error: $e');
    return _combineReplayAndFloorError(replayFlow, e.toString(), 'aot');
  }
}

/// Executes clean flow AOT floor and attaches results to [replayFlow].
FlowResult attachCleanFloor(
  FloorFlowContext ctx,
  FlowResult replayFlow,
  String bazelAppExecutable,
) => _attachAotFloor(ctx, replayFlow, bazelAppExecutable, 'Clean');

/// Executes API flow AOT floor and attaches results to [replayFlow].
FlowResult attachApiFloor(
  FloorFlowContext ctx,
  FlowResult replayFlow,
  String bazelAppExecutable,
) => _attachAotFloor(ctx, replayFlow, bazelAppExecutable, 'API');

/// Executes body flow incremental JIT floor and attaches results to [replayFlow].
FlowResult attachBodyFloor(
  FloorFlowContext ctx,
  FlowResult replayFlow, {
  required String bazelAppExecutable,
  required String editedFile,
}) {
  final sdk = ctx.sdk;
  if (sdk == null) {
    return _combineReplayAndFloorError(
      replayFlow,
      'Could not locate workspace Dart SDK',
      'jit',
    );
  }
  try {
    final floorRes = runIncrementalBodyFloorFlow(
      sdk: sdk,
      workspaceDir: ctx.workspaceDir,
      floorOutputDir: ctx.outputDir,
      editedFile: editedFile,
      bazelAppExecutable: bazelAppExecutable,
      runner: ctx.runner,
    );
    return _combineReplayAndFloor(replayFlow, floorRes);
  } on Object catch (e) {
    stderr.writeln('Body floor execution error: $e');
    return _combineReplayAndFloorError(replayFlow, e.toString(), 'jit');
  }
}

/// Executes leaf test floor and attaches results to [replayFlow].
FlowResult attachTestLeafFloor(
  FloorFlowContext ctx,
  FlowResult replayFlow,
  String testDill,
) {
  final sdk = ctx.sdk;
  if (sdk == null) {
    return _combineReplayAndFloorError(
      replayFlow,
      'Could not locate workspace Dart SDK',
      'aot',
    );
  }
  try {
    final floorRes = runTestLeafFloorFlow(
      sdk: sdk,
      workspaceDir: ctx.workspaceDir,
      testDillPath: testDill,
      clock: ctx.clock,
      runner: ctx.runner,
    );
    return _combineReplayAndFloor(replayFlow, floorRes);
  } on Object catch (e) {
    stderr.writeln('Leaf test floor execution error: $e');
    return _combineReplayAndFloorError(replayFlow, e.toString(), 'aot');
  }
}
