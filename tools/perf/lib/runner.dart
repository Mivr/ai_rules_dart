/// Speed-of-light runner measuring four flows across repeats.
library;

import 'dart:io';

import 'cli_args.dart';
import 'cpu.dart';
import 'proc.dart';
import 'replay.dart';
import 'result_writer.dart';
import 'spawn_log.dart';

void _replaceHookReturn(File file, int fromVal, int toVal, String label) {
  if (!file.existsSync()) {
    throw StateError('$label source file not found: ${file.path}');
  }
  final orig = file.readAsStringSync();
  final pattern = RegExp('^( +)return $fromVal;\$', multiLine: true);
  final match = pattern.firstMatch(orig);
  if (match == null) {
    throw StateError(
      'Expected $label body hook marker not found in ${file.path}',
    );
  }
  final indent = match.group(1)!;
  file.writeAsStringSync(
    orig.replaceFirst('${indent}return $fromVal;', '${indent}return $toVal;'),
  );
}

/// Applies the deterministic layer-0 method-body edit in [workspacePath].
void applyLayer0BodyEdit(String workspacePath) {
  _replaceHookReturn(
    File('$workspacePath/packages/pkg0/lib/src/f0.dart'),
    1,
    2,
    'Layer-0',
  );
}

/// Applies the deterministic layer-0 public-API edit in [workspacePath].
void applyLayer0ApiEdit(String workspacePath) {
  final entry = File('$workspacePath/packages/pkg0/lib/pkg0.dart');
  if (!entry.existsSync()) {
    throw StateError('Layer-0 entry file not found: ${entry.path}');
  }
  final orig = entry.readAsStringSync();
  const target = 'int pkg0Entry(int x) {\n  var acc = x;';
  const replacement =
      'int pkg0Entry(int x, [int bonus = 0]) {\n  var acc = x + bonus;';
  if (!orig.contains(target)) {
    throw StateError('Expected pkg0Entry signature not found in pkg0.dart');
  }
  entry.writeAsStringSync(orig.replaceFirst(target, replacement));
}

/// Applies the deterministic leaf method-body edit for [pkgName].
void applyLeafBodyEdit(String workspacePath, String pkgName) {
  _replaceHookReturn(
    File('$workspacePath/packages/$pkgName/lib/src/f0.dart'),
    10,
    20,
    'Leaf',
  );
}

ProcessResult _runBazel(String workingDirectory, List<String> args) {
  return Process.runSync(
    'bazel',
    ['--max_idle_secs=600', ...args],
    workingDirectory: workingDirectory,
    environment: cleanProcessEnvironment(),
    includeParentEnvironment: false,
  );
}

String _entityBasename(String path) {
  final norm = path.replaceAll(r'\', '/');
  final stripped = norm.endsWith('/') && norm.length > 1
      ? norm.substring(0, norm.length - 1)
      : norm;
  final slash = stripped.lastIndexOf('/');
  return slash == -1 ? stripped : stripped.substring(slash + 1);
}

/// Makes [dir] writable and deletes it recursively if present.
void forceDeleteDirectorySync(Directory dir) {
  if (!dir.existsSync()) return;
  makeBazelOutWritable(dir.path);
  try {
    if (Platform.isLinux || Platform.isMacOS) {
      Process.runSync(
        'chmod',
        ['-R', 'u+w', dir.path],
        environment: cleanProcessEnvironment(),
        includeParentEnvironment: false,
      );
    }
  } on ProcessException catch (e) {
    stderr.writeln('chmod before delete failed (${dir.path}): $e');
  }
  dir.deleteSync(recursive: true);
}

final class _FlowReplaySpec {
  const _FlowReplaySpec({
    required this.method,
    required this.bazelCpu,
    required this.target,
    required this.isTest,
  });

  final String method;
  final double bazelCpu;
  final String target;
  final bool isTest;
}

/// Context for running a single measured repeat.
final class RepeatContext {
  /// Creates a repeat context.
  RepeatContext({
    required this.repeatWorkspace,
    required this.outputBase,
    required this.logsDir,
    required this.repeatIndex,
    required this.clock,
    required this.procReader,
  });

  /// Temporary workspace copy for this repeat.
  final String repeatWorkspace;

  /// Per-repeat Bazel output base.
  final String outputBase;

  /// Directory outside the workspace holding execution logs.
  final String logsDir;

  /// 1-based repeat index.
  final int repeatIndex;

  /// CPU clock.
  final ChildCpuClock clock;

  /// Proc reader.
  final ProcReader procReader;

  /// Retrieves the Bazel server PID for this output base.
  int getServerPid() {
    final pidFile = File('$outputBase/server/server.pid.txt');
    if (pidFile.existsSync()) {
      final pid = int.tryParse(pidFile.readAsStringSync().trim());
      if (pid != null) return pid;
    }

    final res = _runBazel(repeatWorkspace, [
      '--output_base=$outputBase',
      'info',
      'server_pid',
    ]);
    if (res.exitCode == 0) {
      final pid = int.tryParse((res.stdout as String).trim());
      if (pid != null) return pid;
    }

    throw StateError('Unable to determine Bazel server PID');
  }

  /// Shuts down the Bazel server for this output base.
  void shutdown() {
    try {
      _runBazel(repeatWorkspace, ['--output_base=$outputBase', 'shutdown']);
    } on ProcessException catch (e) {
      stderr.writeln('Bazel shutdown process error: $e');
    }
  }

  /// Queries the execution root path from Bazel.
  String getExecroot() {
    final res = _runBazel(repeatWorkspace, [
      '--output_base=$outputBase',
      'info',
      'execution_root',
    ]);
    if (res.exitCode != 0) {
      throw StateError('Failed to get execroot: ${res.stderr}');
    }
    return (res.stdout as String).trim();
  }

  /// Queries declared output files for a target.
  Set<String> queryTargetOutputs(String target) {
    final res = _runBazel(repeatWorkspace, [
      '--output_base=$outputBase',
      'cquery',
      '--output=files',
      target,
    ]);
    if (res.exitCode != 0) {
      throw StateError('Failed to query target outputs: ${res.stderr}');
    }
    return (res.stdout as String)
        .split('\n')
        .map((s) => s.trim().replaceAll(r'\', '/'))
        .where((s) => s.isNotEmpty)
        .toSet();
  }
}

/// Recursively copies a directory tree.
void copyDirectorySync(Directory source, Directory destination) {
  if (!destination.existsSync()) destination.createSync(recursive: true);
  for (final entity in source.listSync(followLinks: false)) {
    final itemName = _entityBasename(entity.path);
    if (itemName.isEmpty) continue;
    final destPath = '${destination.path}/$itemName';
    if (entity is Directory) {
      copyDirectorySync(entity, Directory(destPath));
    } else if (entity is Link) {
      Link(destPath).createSync(entity.targetSync());
    } else if (entity is File) {
      entity.copySync(destPath);
    }
  }
}

FlowResult _failedFlow(String method, String reason) {
  return FlowResult(
    method: method,
    bazelCpu: null,
    solCpu: null,
    identical: false,
    reason: reason,
    chain: buildChainObject(identical: false, solCpu: null, reason: reason),
    workerSteps: const {},
  );
}

/// Executes all four flows for a repeat.
RepeatResult executeRepeat({
  required String pristineWorkspace,
  required int repeatIndex,
  required String tempRoot,
  ChildCpuClock? clockOverride,
  ProcReader? procReaderOverride,
}) {
  final clock = clockOverride ?? const LinuxChildCpuClock();
  final procReader = procReaderOverride ?? const LinuxProcReader();
  final resolvedPristine = resolveCliPath(pristineWorkspace);
  final resolvedTemp = resolveCliPath(tempRoot);

  final repeatWsDir = Directory('$resolvedTemp/repeat_${repeatIndex}_ws');
  final outbaseDir = Directory('$resolvedTemp/repeat_${repeatIndex}_outbase');
  final logsDir = Directory('$resolvedTemp/repeat_${repeatIndex}_logs');

  for (final dir in [repeatWsDir, outbaseDir, logsDir]) {
    forceDeleteDirectorySync(dir);
  }
  logsDir.createSync(recursive: true);
  copyDirectorySync(Directory(resolvedPristine), repeatWsDir);

  final ctx = RepeatContext(
    repeatWorkspace: repeatWsDir.path,
    outputBase: outbaseDir.path,
    logsDir: logsDir.path,
    repeatIndex: repeatIndex,
    clock: clock,
    procReader: procReader,
  );

  final flows = <String, FlowResult>{};
  try {
    flows['dart-app-clean'] = _measureFlowAppClean(ctx);
    final bodyRes = _measureFlowAppBody(ctx);
    flows['dart-app-body'] = bodyRes;
    flows['dart-app-api'] = _measureFlowAppApi(
      ctx,
      needsWarmup: !bodyRes.identical,
    );
    flows['dart-test-leaf'] = _measureFlowTestLeaf(ctx);
  } finally {
    ctx.shutdown();
    for (final dir in [outbaseDir, repeatWsDir, logsDir]) {
      try {
        forceDeleteDirectorySync(dir);
      } on FileSystemException catch (e) {
        stderr.writeln('Failed to clean repeat dir ${dir.path}: $e');
      }
    }
  }

  return RepeatResult(repeatIndex: repeatIndex, flows: flows);
}

FlowResult _measureFlowAppClean(RepeatContext ctx) {
  try {
    final logFile = File('${ctx.logsDir}/exec_clean_${ctx.repeatIndex}.json');
    final beforeCpu = ctx.clock.getChildCpuSeconds();
    final res = _runBazel(ctx.repeatWorkspace, [
      '--batch',
      '--output_base=${ctx.outputBase}',
      'build',
      '//app:app',
      '--execution_log_json_file=${logFile.path}',
      '--materialize_param_files',
    ]);
    final afterCpu = ctx.clock.getChildCpuSeconds();

    if (res.exitCode != 0) {
      return _failedFlow('batch', 'Clean build failed: ${res.stderr}');
    }

    return _replayAndVerifyFlow(
      ctx,
      logFile,
      _FlowReplaySpec(
        method: 'batch',
        bazelCpu: afterCpu - beforeCpu,
        target: '//app:app',
        isTest: false,
      ),
    );
  } on Object catch (e) {
    stderr.writeln('Flow dart-app-clean error: $e');
    return _failedFlow('batch', e.toString());
  }
}

(ProcessResult, double) _runMeasuredWarmCommand(
  RepeatContext ctx,
  List<String> bazelArgs,
) {
  final serverPid = ctx.getServerPid();
  final snapBefore = takeServerTreeSnapshot(ctx.procReader, serverPid);
  final clientBefore = ctx.clock.getChildCpuSeconds();

  final res = _runBazel(ctx.repeatWorkspace, [
    '--output_base=${ctx.outputBase}',
    ...bazelArgs,
  ]);

  final clientAfter = ctx.clock.getChildCpuSeconds();
  final snapAfter = takeServerTreeSnapshot(ctx.procReader, serverPid);
  final serverCpu = computeWarmServerCpuDelta(
    before: snapBefore,
    after: snapAfter,
    clockTicksPerSecond: ctx.procReader.clockTicksPerSecond,
  );
  final clientDelta = clientAfter - clientBefore;
  final totalCpu = (clientDelta > 0 ? clientDelta : 0.0) + serverCpu;
  return (res, totalCpu);
}

void _warmBuildApp(RepeatContext ctx) {
  final warmupLog = File('${ctx.logsDir}/warmup_app_${ctx.repeatIndex}.json');
  final res = _runBazel(ctx.repeatWorkspace, [
    '--output_base=${ctx.outputBase}',
    'build',
    '//app:app',
    '--execution_log_json_file=${warmupLog.path}',
    '--materialize_param_files',
  ]);
  if (res.exitCode != 0) {
    throw StateError('Warm-up build of //app:app failed: ${res.stderr}');
  }
}

FlowResult _measureFlowAppBody(RepeatContext ctx) {
  try {
    _warmBuildApp(ctx);
    applyLayer0BodyEdit(ctx.repeatWorkspace);

    final logFile = File('${ctx.logsDir}/exec_body_${ctx.repeatIndex}.json');
    final (res, bazelCpu) = _runMeasuredWarmCommand(ctx, [
      'build',
      '//app:app',
      '--execution_log_json_file=${logFile.path}',
      '--materialize_param_files',
    ]);

    if (res.exitCode != 0) {
      return _failedFlow(
        'warm-server',
        'Body edit build failed: ${res.stderr}',
      );
    }

    return _replayAndVerifyFlow(
      ctx,
      logFile,
      _FlowReplaySpec(
        method: 'warm-server',
        bazelCpu: bazelCpu,
        target: '//app:app',
        isTest: false,
      ),
    );
  } on Object catch (e) {
    stderr.writeln('Flow dart-app-body error: $e');
    return _failedFlow('warm-server', e.toString());
  }
}

FlowResult _measureFlowAppApi(RepeatContext ctx, {required bool needsWarmup}) {
  try {
    if (needsWarmup) _warmBuildApp(ctx);
    applyLayer0ApiEdit(ctx.repeatWorkspace);

    final logFile = File('${ctx.logsDir}/exec_api_${ctx.repeatIndex}.json');
    final (res, bazelCpu) = _runMeasuredWarmCommand(ctx, [
      'build',
      '//app:app',
      '--execution_log_json_file=${logFile.path}',
      '--materialize_param_files',
    ]);

    if (res.exitCode != 0) {
      return _failedFlow('warm-server', 'API edit build failed: ${res.stderr}');
    }

    return _replayAndVerifyFlow(
      ctx,
      logFile,
      _FlowReplaySpec(
        method: 'warm-server',
        bazelCpu: bazelCpu,
        target: '//app:app',
        isTest: false,
      ),
    );
  } on Object catch (e) {
    stderr.writeln('Flow dart-app-api error: $e');
    return _failedFlow('warm-server', e.toString());
  }
}

String _selectLeafTestTarget(RepeatContext ctx) {
  final qRes = _runBazel(ctx.repeatWorkspace, [
    '--output_base=${ctx.outputBase}',
    'query',
    'kind(dart_test, //...)',
  ]);
  if (qRes.exitCode != 0) {
    throw StateError('Failed querying dart_test targets: ${qRes.stderr}');
  }
  final testTargets =
      (qRes.stdout as String)
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList()
        ..sort();
  if (testTargets.isEmpty) throw StateError('No leaf test target found');
  return testTargets.first;
}

FlowResult _measureFlowTestLeaf(RepeatContext ctx) {
  try {
    final leafTarget = _selectLeafTestTarget(ctx);
    final warmRes = _runBazel(ctx.repeatWorkspace, [
      '--output_base=${ctx.outputBase}',
      'test',
      leafTarget,
      '--materialize_param_files',
    ]);
    if (warmRes.exitCode != 0) {
      throw StateError('Warm-up test $leafTarget failed: ${warmRes.stderr}');
    }

    final pkgName = leafTarget.split(':').first.replaceFirst('//packages/', '');
    applyLeafBodyEdit(ctx.repeatWorkspace, pkgName);

    final logFile = File('${ctx.logsDir}/exec_test_${ctx.repeatIndex}.json');
    final (res, bazelCpu) = _runMeasuredWarmCommand(ctx, [
      'test',
      leafTarget,
      '--execution_log_json_file=${logFile.path}',
      '--materialize_param_files',
    ]);

    if (res.exitCode != 0) {
      return _failedFlow('warm-server', 'Leaf test failed: ${res.stderr}');
    }

    return _replayAndVerifyFlow(
      ctx,
      logFile,
      _FlowReplaySpec(
        method: 'warm-server',
        bazelCpu: bazelCpu,
        target: leafTarget,
        isTest: true,
      ),
    );
  } on Object catch (e) {
    stderr.writeln('Flow dart-test-leaf error: $e');
    return _failedFlow('warm-server', e.toString());
  }
}

FlowResult _replayFailure(
  _FlowReplaySpec spec,
  String reason,
  Map<String, int> workerSteps, {
  String? orderingFailed,
  Map<String, dynamic> steps = const {},
}) => FlowResult(
  method: spec.method,
  bazelCpu: spec.bazelCpu,
  solCpu: null,
  identical: false,
  reason: reason,
  chain: buildChainObject(
    identical: false,
    solCpu: null,
    reason: reason,
    orderingFailed: orderingFailed,
    steps: steps,
  ),
  workerSteps: workerSteps,
);

(List<SpawnRecord>?, Map<String, int>, FlowResult?) _resolveAndOrderSpawns(
  File logFile,
  _FlowReplaySpec spec,
) {
  if (!logFile.existsSync()) {
    return (
      null,
      const {},
      _replayFailure(spec, 'Execution log not generated', const {}),
    );
  }

  final parsed = parseExecutionLog(logFile.readAsStringSync());
  if (parsed.chainSpawns.isEmpty) {
    return (
      null,
      parsed.workerSteps,
      _replayFailure(
        spec,
        'No chain spawns extracted from log',
        parsed.workerSteps,
      ),
    );
  }

  try {
    final ordered = orderChainSpawns(
      parsed.chainSpawns,
      blockedOutputs: parsed.blockedOutputs,
    );
    return (ordered, parsed.workerSteps, null);
  } on Object catch (e) {
    stderr.writeln('Chain spawn ordering failed: $e');
    return (
      null,
      parsed.workerSteps,
      _replayFailure(
        spec,
        'Spawn ordering failed: $e',
        parsed.workerSteps,
        orderingFailed: e.toString(),
        steps: chainStepsFromSpawns(parsed.chainSpawns),
      ),
    );
  }
}

FlowResult _replayAndVerifyFlow(
  RepeatContext ctx,
  File logFile,
  _FlowReplaySpec spec,
) {
  final (ordered, workerSteps, failure) = _resolveAndOrderSpawns(logFile, spec);
  if (failure != null || ordered == null) return failure!;

  final String execroot;
  final Set<String> verifyPaths;
  try {
    execroot = ctx.getExecroot();
    verifyPaths = spec.isTest
        ? selectLeafTestVerifyPaths(ordered)
        : ctx.queryTargetOutputs(spec.target);
  } on Object catch (e) {
    stderr.writeln('Failed preparing replay verification: $e');
    return _replayFailure(
      spec,
      e.toString(),
      workerSteps,
      steps: chainStepsFromSpawns(ordered),
    );
  }
  if (verifyPaths.isEmpty) {
    return _replayFailure(
      spec,
      'No declared outputs to verify for ${spec.target}',
      workerSteps,
      steps: chainStepsFromSpawns(ordered),
    );
  }

  final replayRes = replayChainAndVerify(
    orderedSpawns: ordered,
    execroot: execroot,
    verifyPaths: verifyPaths,
    clock: ctx.clock,
    isTestFlow: spec.isTest,
  );

  return FlowResult(
    method: spec.method,
    bazelCpu: spec.bazelCpu,
    solCpu: replayRes.solCpuSeconds,
    identical: replayRes.identical,
    reason: replayRes.reason,
    chain: buildChainObject(
      identical: replayRes.identical,
      solCpu: replayRes.solCpuSeconds,
      reason: replayRes.reason,
      steps: chainStepsFromSpawns(ordered),
    ),
    workerSteps: workerSteps,
  );
}
