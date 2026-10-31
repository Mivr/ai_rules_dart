/// Speed-of-light runner measuring four flows across repeats.
library;

import 'dart:io';

import 'cpu.dart';
import 'proc.dart';
import 'replay.dart';
import 'result_writer.dart';
import 'spawn_log.dart';

/// Context for running a single measured repeat.
final class RepeatContext {
  /// Creates a repeat context.
  RepeatContext({
    required this.pristineWorkspace,
    required this.repeatWorkspace,
    required this.outputBase,
    required this.repeatIndex,
    required this.clock,
    required this.procReader,
  });

  /// Pristine source workspace containing MODULE.bazel.lock.
  final String pristineWorkspace;

  /// Temporary workspace copy for this repeat.
  final String repeatWorkspace;

  /// Per-repeat Bazel output base.
  final String outputBase;

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
      final text = pidFile.readAsStringSync().trim();
      final pid = int.tryParse(text);
      if (pid != null) return pid;
    }

    final res = Process.runSync('bazel', [
      '--output_base=$outputBase',
      'info',
      'server_pid',
    ], workingDirectory: repeatWorkspace);
    final pid = int.tryParse((res.stdout as String).trim());
    if (pid != null) return pid;

    throw StateError('Unable to determine Bazel server PID');
  }

  /// Shuts down the Bazel server for this output base.
  void shutdown() {
    try {
      Process.runSync('bazel', [
        '--output_base=$outputBase',
        'shutdown',
      ], workingDirectory: repeatWorkspace);
    } on ProcessException catch (e) {
      stderr.writeln('Bazel shutdown process error: $e');
    } on Exception catch (e) {
      stderr.writeln('Bazel shutdown failure: $e');
    }
  }

  /// Queries the execution root path from Bazel.
  String getExecroot() {
    final res = Process.runSync('bazel', [
      '--output_base=$outputBase',
      'info',
      'execution_root',
    ], workingDirectory: repeatWorkspace);
    if (res.exitCode != 0) {
      throw StateError('Failed to get execroot: ${res.stderr}');
    }
    return (res.stdout as String).trim();
  }

  /// Queries declared output files for a target.
  Set<String> queryTargetOutputs(String target) {
    final res = Process.runSync('bazel', [
      '--output_base=$outputBase',
      'cquery',
      '--output=files',
      target,
    ], workingDirectory: repeatWorkspace);
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
    final name = entity.uri.pathSegments.reversed.skip(1).firstOrNull ?? '';
    final destPath = '${destination.path}/$name';
    if (entity is Directory) {
      copyDirectorySync(entity, Directory(destPath));
    } else if (entity is File) {
      entity.copySync(destPath);
    }
  }
}

/// Executes all four flows for a repeat.
RepeatResult executeRepeat({
  required String pristineWorkspace,
  required int repeatIndex,
  required String tempRoot,
  ChildCpuClock? clockOverride,
  ProcReader? procReaderOverride,
}) {
  final clock = clockOverride ?? LinuxChildCpuClock();
  final procReader = procReaderOverride ?? const LinuxProcReader();

  final repeatWsDir = Directory('$tempRoot/repeat_${repeatIndex}_ws');
  final outbaseDir = Directory('$tempRoot/repeat_${repeatIndex}_outbase');

  if (repeatWsDir.existsSync()) repeatWsDir.deleteSync(recursive: true);
  if (outbaseDir.existsSync()) outbaseDir.deleteSync(recursive: true);

  copyDirectorySync(Directory(pristineWorkspace), repeatWsDir);

  final ctx = RepeatContext(
    pristineWorkspace: pristineWorkspace,
    repeatWorkspace: repeatWsDir.path,
    outputBase: outbaseDir.path,
    repeatIndex: repeatIndex,
    clock: clock,
    procReader: procReader,
  );

  final flows = <String, FlowResult>{};
  try {
    flows['dart-app-clean'] = _measureFlowAppClean(ctx);
    flows['dart-app-body'] = _measureFlowAppBody(ctx);
    flows['dart-app-api'] = _measureFlowAppApi(ctx);
    flows['dart-test-leaf'] = _measureFlowTestLeaf(ctx);
  } finally {
    ctx.shutdown();
    try {
      if (outbaseDir.existsSync()) outbaseDir.deleteSync(recursive: true);
      if (repeatWsDir.existsSync()) repeatWsDir.deleteSync(recursive: true);
    } on FileSystemException catch (e) {
      stderr.writeln('Failed to clean repeat dirs: $e');
    } on Exception catch (e) {
      stderr.writeln('Cleanup error: $e');
    }
  }

  return RepeatResult(repeatIndex: repeatIndex, flows: flows);
}

FlowResult _measureFlowAppClean(RepeatContext ctx) {
  try {
    final logFile = File(
      '${ctx.repeatWorkspace}/exec_clean_${ctx.repeatIndex}.json',
    );
    final beforeCpu = ctx.clock.getChildCpuSeconds();
    final res = Process.runSync('bazel', [
      '--batch',
      '--output_base=${ctx.outputBase}',
      'build',
      '//app:app',
      '--execution_log_json_file=${logFile.path}',
      '--materialize_param_files',
    ], workingDirectory: ctx.repeatWorkspace);
    final afterCpu = ctx.clock.getChildCpuSeconds();

    if (res.exitCode != 0) {
      return FlowResult(
        method: 'batch',
        bazelCpu: null,
        solCpu: null,
        identical: false,
        reason: 'Clean build failed: ${res.stderr}',
        chain: 0,
        workerSteps: 0,
      );
    }

    final bazelCpu = afterCpu - beforeCpu;
    return _replayAndVerifyFlow(
      ctx: ctx,
      logFile: logFile,
      method: 'batch',
      bazelCpu: bazelCpu,
      target: '//app:app',
      isTest: false,
    );
  } on Exception catch (e) {
    stderr.writeln('Flow dart-app-clean error: $e');
    return FlowResult(
      method: 'batch',
      bazelCpu: null,
      solCpu: null,
      identical: false,
      reason: e.toString(),
      chain: 0,
      workerSteps: 0,
    );
  }
}

FlowResult _measureFlowAppBody(RepeatContext ctx) {
  try {
    Process.runSync('bazel', [
      '--output_base=${ctx.outputBase}',
      'build',
      '//app:app',
    ], workingDirectory: ctx.repeatWorkspace);

    final f0 = File('${ctx.repeatWorkspace}/packages/pkg0/lib/src/f0.dart');
    if (!f0.existsSync()) throw StateError('Layer-0 f0.dart not found');
    final orig = f0.readAsStringSync();
    f0.writeAsStringSync(orig.replaceFirst('return 1;', 'return 2;'));

    final logFile = File(
      '${ctx.repeatWorkspace}/exec_body_${ctx.repeatIndex}.json',
    );
    final serverPid = ctx.getServerPid();
    final snapBefore = takeServerTreeSnapshot(ctx.procReader, serverPid);

    final clientBefore = ctx.clock.getChildCpuSeconds();
    final res = Process.runSync('bazel', [
      '--output_base=${ctx.outputBase}',
      'build',
      '//app:app',
      '--execution_log_json_file=${logFile.path}',
      '--materialize_param_files',
    ], workingDirectory: ctx.repeatWorkspace);
    final clientAfter = ctx.clock.getChildCpuSeconds();

    final snapAfter = takeServerTreeSnapshot(ctx.procReader, serverPid);
    final serverCpu = computeWarmServerCpuDelta(
      before: snapBefore,
      after: snapAfter,
      clockTicksPerSecond: ctx.procReader.clockTicksPerSecond,
    );
    final clientCpu = clientAfter - clientBefore;
    final bazelCpu = clientCpu + serverCpu;

    if (res.exitCode != 0) {
      return FlowResult(
        method: 'warm-server',
        bazelCpu: null,
        solCpu: null,
        identical: false,
        reason: 'Body edit build failed: ${res.stderr}',
        chain: 0,
        workerSteps: 0,
      );
    }

    return _replayAndVerifyFlow(
      ctx: ctx,
      logFile: logFile,
      method: 'warm-server',
      bazelCpu: bazelCpu,
      target: '//app:app',
      isTest: false,
    );
  } on Exception catch (e) {
    stderr.writeln('Flow dart-app-body error: $e');
    return FlowResult(
      method: 'warm-server',
      bazelCpu: null,
      solCpu: null,
      identical: false,
      reason: e.toString(),
      chain: 0,
      workerSteps: 0,
    );
  }
}

FlowResult _measureFlowAppApi(RepeatContext ctx) {
  try {
    final entry = File('${ctx.repeatWorkspace}/packages/pkg0/lib/pkg0.dart');
    if (!entry.existsSync()) throw StateError('Layer-0 pkg0.dart not found');
    final orig = entry.readAsStringSync();
    entry.writeAsStringSync(
      '$orig\n/// Added public API.\nint extraApiFunction() => 42;\n',
    );

    final logFile = File(
      '${ctx.repeatWorkspace}/exec_api_${ctx.repeatIndex}.json',
    );
    final serverPid = ctx.getServerPid();
    final snapBefore = takeServerTreeSnapshot(ctx.procReader, serverPid);

    final clientBefore = ctx.clock.getChildCpuSeconds();
    final res = Process.runSync('bazel', [
      '--output_base=${ctx.outputBase}',
      'build',
      '//app:app',
      '--execution_log_json_file=${logFile.path}',
      '--materialize_param_files',
    ], workingDirectory: ctx.repeatWorkspace);
    final clientAfter = ctx.clock.getChildCpuSeconds();

    final snapAfter = takeServerTreeSnapshot(ctx.procReader, serverPid);
    final serverCpu = computeWarmServerCpuDelta(
      before: snapBefore,
      after: snapAfter,
      clockTicksPerSecond: ctx.procReader.clockTicksPerSecond,
    );
    final clientCpu = clientAfter - clientBefore;
    final bazelCpu = clientCpu + serverCpu;

    if (res.exitCode != 0) {
      return FlowResult(
        method: 'warm-server',
        bazelCpu: null,
        solCpu: null,
        identical: false,
        reason: 'API edit build failed: ${res.stderr}',
        chain: 0,
        workerSteps: 0,
      );
    }

    return _replayAndVerifyFlow(
      ctx: ctx,
      logFile: logFile,
      method: 'warm-server',
      bazelCpu: bazelCpu,
      target: '//app:app',
      isTest: false,
    );
  } on Exception catch (e) {
    stderr.writeln('Flow dart-app-api error: $e');
    return FlowResult(
      method: 'warm-server',
      bazelCpu: null,
      solCpu: null,
      identical: false,
      reason: e.toString(),
      chain: 0,
      workerSteps: 0,
    );
  }
}

FlowResult _measureFlowTestLeaf(RepeatContext ctx) {
  try {
    final qRes = Process.runSync('bazel', [
      '--output_base=${ctx.outputBase}',
      'query',
      'kind(dart_test, //...)',
    ], workingDirectory: ctx.repeatWorkspace);
    final testTargets = (qRes.stdout as String)
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (testTargets.isEmpty) throw StateError('No leaf test target found');
    final leafTarget = testTargets.first;

    Process.runSync('bazel', [
      '--output_base=${ctx.outputBase}',
      'test',
      leafTarget,
    ], workingDirectory: ctx.repeatWorkspace);

    final pkgName = leafTarget.split(':').first.replaceFirst('//packages/', '');
    final f0 = File('${ctx.repeatWorkspace}/packages/$pkgName/lib/src/f0.dart');
    if (f0.existsSync()) {
      final orig = f0.readAsStringSync();
      f0.writeAsStringSync(orig.replaceFirst('return 10;', 'return 20;'));
    }

    final logFile = File(
      '${ctx.repeatWorkspace}/exec_test_${ctx.repeatIndex}.json',
    );
    final serverPid = ctx.getServerPid();
    final snapBefore = takeServerTreeSnapshot(ctx.procReader, serverPid);

    final clientBefore = ctx.clock.getChildCpuSeconds();
    final res = Process.runSync('bazel', [
      '--output_base=${ctx.outputBase}',
      'test',
      leafTarget,
      '--execution_log_json_file=${logFile.path}',
      '--materialize_param_files',
    ], workingDirectory: ctx.repeatWorkspace);
    final clientAfter = ctx.clock.getChildCpuSeconds();

    final snapAfter = takeServerTreeSnapshot(ctx.procReader, serverPid);
    final serverCpu = computeWarmServerCpuDelta(
      before: snapBefore,
      after: snapAfter,
      clockTicksPerSecond: ctx.procReader.clockTicksPerSecond,
    );
    final clientCpu = clientAfter - clientBefore;
    final bazelCpu = clientCpu + serverCpu;

    if (res.exitCode != 0) {
      return FlowResult(
        method: 'warm-server',
        bazelCpu: null,
        solCpu: null,
        identical: false,
        reason: 'Test failed: ${res.stderr}',
        chain: 0,
        workerSteps: 0,
      );
    }

    return _replayAndVerifyFlow(
      ctx: ctx,
      logFile: logFile,
      method: 'warm-server',
      bazelCpu: bazelCpu,
      target: leafTarget,
      isTest: true,
    );
  } on Exception catch (e) {
    stderr.writeln('Flow dart-test-leaf error: $e');
    return FlowResult(
      method: 'warm-server',
      bazelCpu: null,
      solCpu: null,
      identical: false,
      reason: e.toString(),
      chain: 0,
      workerSteps: 0,
    );
  }
}

FlowResult _replayAndVerifyFlow({
  required RepeatContext ctx,
  required File logFile,
  required String method,
  required double bazelCpu,
  required String target,
  required bool isTest,
}) {
  if (!logFile.existsSync()) {
    return FlowResult(
      method: method,
      bazelCpu: bazelCpu,
      solCpu: null,
      identical: false,
      reason: 'Execution log not generated',
      chain: 0,
      workerSteps: 0,
    );
  }

  final parsed = parseExecutionLog(logFile.readAsStringSync());
  if (parsed.chainSpawns.isEmpty) {
    return FlowResult(
      method: method,
      bazelCpu: bazelCpu,
      solCpu: null,
      identical: false,
      reason: 'No chain spawns extracted from log',
      chain: 0,
      workerSteps: parsed.workerSteps,
    );
  }

  List<SpawnRecord> ordered;
  try {
    ordered = orderChainSpawns(parsed.chainSpawns);
  } on Exception catch (e) {
    stderr.writeln('Chain spawn ordering failed: $e');
    return FlowResult(
      method: method,
      bazelCpu: bazelCpu,
      solCpu: null,
      identical: false,
      reason: 'Spawn ordering failed: $e',
      chain: parsed.chainSpawns.length,
      workerSteps: parsed.workerSteps,
    );
  }

  final execroot = ctx.getExecroot();
  final Set<String> verifyPaths;
  if (isTest) {
    verifyPaths = selectLeafTestVerifyPaths(ordered);
  } else {
    verifyPaths = ctx.queryTargetOutputs(target);
  }

  final replayRes = replayChainAndVerify(
    orderedSpawns: ordered,
    execroot: execroot,
    verifyPaths: verifyPaths,
    clock: ctx.clock,
    isTestFlow: isTest,
  );

  return FlowResult(
    method: method,
    bazelCpu: bazelCpu,
    solCpu: replayRes.solCpuSeconds,
    identical: replayRes.identical,
    reason: replayRes.reason,
    chain: ordered.length,
    workerSteps: parsed.workerSteps,
  );
}
