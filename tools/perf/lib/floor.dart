/// Low-level SDK toolchain floor execution and verification.
library;

import 'dart:convert';
import 'dart:io';

import 'cli_args.dart';
import 'cpu.dart';
import 'floor_chains.dart';
import 'floor_layout.dart';
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

  final layout = FloorLayout.fromApp(
    appExecutable: bazelAppExecutable,
    workspaceDir: workspaceDir,
  );
  final spec = AppAotChainSpec(
    sdk: sdk,
    entrypoint: layout.entrypoint,
    outputDill: '$floorOutputDir/app.dill',
    outputAot: outAot,
    packageConfig: layout.packageConfig,
    workingDirectory: layout.workingDirectory,
    filesystemScheme: layout.scheme,
    filesystemRoots: layout.roots,
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

  final floorRun = runner.runSync(sdk.dartaotruntime, [
    outAot,
  ], workingDirectory: workspaceDir);
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

List<String> _driverFlags({
  required SdkTools sdk,
  required FloorLayout layout,
  required String outDill,
  required String editedFile,
  required String preEditFile,
  String mode = 'body',
}) {
  return [
    '--sdk-root=${sdk.sdkRoot}',
    '--dartaotruntime=${sdk.dartaotruntime}',
    '--frontend-server=${sdk.frontendServerSnapshot}',
    '--platform=${sdk.platformStrongDill}',
    '--entrypoint=${layout.entrypoint}',
    if (layout.packageConfig != null) '--packages=${layout.packageConfig}',
    if (layout.scheme != null) ...[
      '--filesystem-scheme=${layout.scheme}',
      '--filesystem-roots=${layout.roots.join(',')}',
    ],
    '--output-dill=$outDill',
    '--edited-file=$editedFile',
    '--edited-uri=${layout.uriFor(editedFile)}',
    if (preEditFile.isNotEmpty) '--pre-edit-file=$preEditFile',
    '--mode=$mode',
  ];
}

(Map<String, dynamic>?, String?) _runDriverProcess({
  required FloorProcessRunner runner,
  required FloorLayout layout,
  required List<String> flags,
}) {
  final (driverExe, driverArgs) = incrementalDriverCommand(flags);
  final driverRes = runner.runSync(
    driverExe,
    driverArgs,
    workingDirectory: layout.workingDirectory,
  );

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

/// The edit and Bazel-built app the body floor recompiles and checks against.
final class BodyFloorEdit {
  /// Creates a body floor edit description.
  const BodyFloorEdit({
    required this.editedFile,
    required this.bazelAppExecutable,
    this.preEditFile = '',
  });

  /// Source file the body edit changed.
  final String editedFile;

  /// The Bazel-built app whose stdout the floor output must equal.
  final String bazelAppExecutable;

  /// Pre-edit copy of [editedFile], when the edit is applied by the driver.
  final String preEditFile;
}

/// Runs the incremental JIT compiler floor for body edit and verifies output.
FloorResult runIncrementalBodyFloorFlow({
  required SdkTools sdk,
  required String workspaceDir,
  required String floorOutputDir,
  required BodyFloorEdit edit,
  FloorProcessRunner runner = const DefaultFloorProcessRunner(),
}) {
  final editedFile = edit.editedFile;
  final preEditFile = edit.preEditFile;
  final bazelAppExecutable = edit.bazelAppExecutable;
  final outDill = '$floorOutputDir/app.dill';
  Directory(floorOutputDir).createSync(recursive: true);

  final layout = FloorLayout.fromApp(
    appExecutable: bazelAppExecutable,
    workspaceDir: workspaceDir,
  );
  final (driverData, driverErr) = _runDriverProcess(
    runner: runner,
    layout: layout,
    flags: _driverFlags(
      sdk: sdk,
      layout: layout,
      outDill: outDill,
      editedFile: editedFile,
      preEditFile: preEditFile,
    ),
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

  final floorRun = runner.runSync(sdk.dart, [
    finalDill,
  ], workingDirectory: workspaceDir);
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

/// Rebuilds the leaf test's kernel with the incremental compiler.
///
/// The kernel Bazel leaves in `bazel-bin` is the test's entry module only;
/// the floor compiles the test bootstrap whole, from the same sources and
/// package config, and lays it out where the runner looks for it. Returns the
/// path of that kernel, or the reason it could not be built.
(String?, String?) _rebuildTestKernel({
  required SdkTools sdk,
  required String workspaceDir,
  required String bazelDill,
  required String floorOutputDir,
  required FloorProcessRunner runner,
}) {
  final parts = splitPrecompiledDill(bazelDill)!;
  final layout = FloorLayout.fromTest(
    testExecutable: parts.precompiled.substring(
      0,
      parts.precompiled.length - '.precompiled'.length,
    ),
    workspaceDir: workspaceDir,
  );
  Directory(floorOutputDir).createSync(recursive: true);
  final built = '$floorOutputDir/test.dill';
  final (data, err) = _runDriverProcess(
    runner: runner,
    layout: layout,
    flags: _driverFlags(
      sdk: sdk,
      layout: layout,
      outDill: built,
      editedFile: '',
      preEditFile: '',
      mode: 'compile-only',
    ),
  );
  if (err != null || data == null) return (null, err);
  final placed = File(
    '$floorOutputDir/test.precompiled/${parts.testPath}.vm_test.vm.app.dill',
  );
  placed.parent.createSync(recursive: true);
  File(data['outputDill'] as String? ?? built).copySync(placed.path);
  return (placed.path, null);
}

/// Runs the leaf test runner floor on a prebuilt test dill and verifies it passes.
FloorResult runTestLeafFloorFlow({
  required SdkTools sdk,
  required String workspaceDir,
  required String testDillPath,
  required ChildCpuClock clock,
  String floorOutputDir = '',
  FloorProcessRunner runner = const DefaultFloorProcessRunner(),
}) {
  var dill = testDillPath;
  if (splitPrecompiledDill(testDillPath) != null) {
    final (rebuilt, err) = _rebuildTestKernel(
      sdk: sdk,
      workspaceDir: workspaceDir,
      bazelDill: testDillPath,
      floorOutputDir: floorOutputDir,
      runner: runner,
    );
    if (rebuilt == null) {
      return FloorResult(
        cpuSeconds: null,
        identical: false,
        reason: 'Floor test kernel rebuild failed: $err',
        floorKind: 'aot',
      );
    }
    dill = rebuilt;
  }
  final step = buildTestRunnerStep(sdk: sdk, testDill: dill);
  final pubGet = runner.runSync(sdk.dart, const [
    'pub',
    'get',
  ], workingDirectory: workspaceDir);
  if (pubGet.exitCode != 0) {
    return FloorResult(
      cpuSeconds: null,
      identical: false,
      reason: 'Floor test setup (dart pub get) failed: ${pubGet.stderr}',
      floorKind: 'aot',
    );
  }
  final beforeCpu = clock.getChildCpuSeconds();
  final testRun = runner.runSync(
    step.executable,
    step.arguments,
    workingDirectory: workspaceDir,
    environment: step.environment,
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

/// Marks only the floor fields of [replay] failed, leaving `sol` as it is.
FlowResult attachFloorError(FlowResult replay, String reason, String kind) {
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
    return attachFloorError(
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
    return attachFloorError(replayFlow, e.toString(), 'aot');
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
  String preEditFile = '',
}) {
  final sdk = ctx.sdk;
  if (sdk == null) {
    return attachFloorError(
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
      edit: BodyFloorEdit(
        editedFile: editedFile,
        preEditFile: preEditFile,
        bazelAppExecutable: bazelAppExecutable,
      ),
      runner: ctx.runner,
    );
    return _combineReplayAndFloor(replayFlow, floorRes);
  } on Object catch (e) {
    stderr.writeln('Body floor execution error: $e');
    return attachFloorError(replayFlow, e.toString(), 'jit');
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
    return attachFloorError(
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
      floorOutputDir: ctx.outputDir,
      clock: ctx.clock,
      runner: ctx.runner,
    );
    return _combineReplayAndFloor(replayFlow, floorRes);
  } on Object catch (e) {
    stderr.writeln('Leaf test floor execution error: $e');
    return attachFloorError(replayFlow, e.toString(), 'aot');
  }
}
