/// Measures one scale size with Bazel's own counters (no replay).
library;

import 'dart:convert';
import 'dart:io';

import 'cli_args.dart';
import 'cpu.dart';
import 'proc.dart';
import 'runner.dart';
import 'scale_report.dart';
import 'spawn_log.dart';

/// CPU seconds, wall seconds and result of one measured Bazel command.
typedef _Timed = ({ProcessResult result, double cpu, double wall});

/// Where one size's Bazel work happens.
final class ScalePaths {
  /// Creates the paths for one size.
  const ScalePaths({
    required this.workspace,
    required this.outputBase,
    required this.logsDir,
    required this.profileFile,
  });

  /// Writable copy of the generated workspace.
  final String workspace;

  /// Bazel output base of the measured server.
  final String outputBase;

  /// Directory holding execution logs.
  final String logsDir;

  /// Where `--starlark_cpu_profile` is written for the analysis pass.
  final String profileFile;
}

/// Runs the flows for one size against a generated workspace.
final class ScaleMeasurer {
  /// Creates a measurer reading `ws-<n>` directories under [workspaceRoot].
  ScaleMeasurer({
    required this.workspaceRoot,
    required this.tempRoot,
    required this.profileDir,
    this.clock = const LinuxChildCpuClock(),
    this.procReader = const LinuxProcReader(),
  });

  /// Directory holding one generated `ws-<n>` workspace per size.
  final String workspaceRoot;

  /// Scratch directory for workspace copies and output bases.
  final String tempRoot;

  /// Directory receiving the Starlark CPU profiles.
  final String profileDir;

  /// Child CPU clock.
  final ChildCpuClock clock;

  /// Proc reader for the Bazel server tree.
  final ProcReader procReader;

  /// Measures every flow at [libraries]; a flow that throws is recorded failed.
  SizeMeasurements call(int libraries) {
    final source = Directory('$workspaceRoot/ws-$libraries');
    if (!source.existsSync()) {
      final missing = FlowMeasurement.failed('missing ${source.path}');
      return {for (final flow in scaleFlows) flow: missing};
    }
    final root = '$tempRoot/size_$libraries';
    final paths = ScalePaths(
      workspace: '$root/ws',
      outputBase: '$root/outbase',
      logsDir: '$root/logs',
      profileFile: '$profileDir/dart-scale-starlark-$libraries.pprof',
    );
    forceDeleteDirectorySync(Directory(root));
    Directory(paths.logsDir).createSync(recursive: true);
    Directory(profileDir).createSync(recursive: true);
    copyDirectorySync(source, Directory(paths.workspace));
    try {
      return _measureAll(paths);
    } finally {
      _bazel(paths.workspace, paths.outputBase, ['shutdown']);
      forceDeleteDirectorySync(Directory(root));
    }
  }

  SizeMeasurements _measureAll(ScalePaths paths) {
    final results = <String, FlowMeasurement>{};
    String? leafTarget;
    try {
      leafTarget = _lockfilePass(paths);
    } on Object catch (e) {
      stderr.writeln('Scale lockfile pass error: $e');
      final failed = FlowMeasurement.failed('lockfile pass failed: $e');
      return {for (final flow in scaleFlows) flow: failed};
    }
    final steps = <String, FlowMeasurement Function()>{
      'dart-app-clean': () => _clean(paths),
      'dart-app-body': () => _edit(paths, applyLayer0BodyEdit),
      'dart-app-api': () => _edit(paths, applyLayer0ApiEdit),
      'dart-test-leaf': () => _leafTest(paths, leafTarget!),
      'dart-analysis': () => _analysis(paths),
    };
    for (final entry in steps.entries) {
      try {
        results[entry.key] = entry.value();
      } on Object catch (e) {
        stderr.writeln('Scale flow ${entry.key} error: $e');
        results[entry.key] = FlowMeasurement.failed('$e');
      }
    }
    return results;
  }

  ProcessResult _bazel(String ws, String base, List<String> args) {
    return Process.runSync(
      'bazel',
      ['--max_idle_secs=600', '--output_base=$base', ...args],
      workingDirectory: ws,
      environment: cleanProcessEnvironment(),
      includeParentEnvironment: false,
    );
  }

  ProcessResult _bazelOk(ScalePaths p, List<String> args) {
    final res = _bazel(p.workspace, p.outputBase, args);
    if (res.exitCode != 0) {
      throw StateError('bazel ${args.join(' ')} failed: ${res.stderr}');
    }
    return res;
  }

  /// Commits the lockfile on a scratch base and returns the leaf test target.
  String _lockfilePass(ScalePaths p) {
    final scratch = '${p.outputBase}_scratch';
    final query = _bazel(p.workspace, scratch, [
      'query',
      'kind(dart_test, //...)',
    ]);
    final tests =
        (query.stdout as String)
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList()
          ..sort();
    if (query.exitCode != 0 || tests.isEmpty) {
      throw StateError('no dart_test targets: ${query.stderr}');
    }
    final res = _bazel(p.workspace, scratch, [
      'build',
      '--nobuild',
      '--lockfile_mode=update',
      '//app:app',
      ...tests,
    ]);
    _bazel(p.workspace, scratch, ['shutdown']);
    forceDeleteDirectorySync(Directory(scratch));
    if (res.exitCode != 0) throw StateError('${res.stderr}');
    return tests.first;
  }

  int _serverPid(ScalePaths p) {
    final res = _bazelOk(p, ['info', 'server_pid']);
    return int.parse((res.stdout as String).trim());
  }

  _Timed _timed(ScalePaths p, List<String> args) {
    final pid = _serverPid(p);
    final before = takeServerTreeSnapshot(procReader, pid);
    final clientBefore = clock.getChildCpuSeconds();
    final watch = Stopwatch()..start();
    final result = _bazel(p.workspace, p.outputBase, args);
    watch.stop();
    final clientDelta = clock.getChildCpuSeconds() - clientBefore;
    final server = computeWarmServerCpuDelta(
      before: before,
      after: takeServerTreeSnapshot(procReader, pid),
      clockTicksPerSecond: procReader.clockTicksPerSecond,
    );
    return (
      result: result,
      cpu: (clientDelta > 0 ? clientDelta : 0.0) + server,
      wall: watch.elapsedMicroseconds / 1e6,
    );
  }

  FlowMeasurement _fromLog(_Timed t, File log, {bool reproducible = true}) {
    if (t.result.exitCode != 0) {
      return FlowMeasurement.failed('${t.result.stderr}');
    }
    final spawns = parseExecutionLog(log.readAsStringSync()).allSpawns;
    return FlowMeasurement(
      cpuSeconds: t.cpu,
      wallSeconds: t.wall,
      actionCount: spawns.length,
      maxCommandLineBytes: _largest(spawns.map((s) => s.commandArgs)),
      reproducible: reproducible,
    );
  }

  int _largest(Iterable<List<String>> commandLines) {
    var largest = 0;
    for (final args in commandLines) {
      final bytes = args.fold<int>(
        0,
        (sum, arg) => sum + utf8.encode(arg).length + 1,
      );
      if (bytes > largest) largest = bytes;
    }
    return largest;
  }

  List<String> _buildArgs(String target, File log) => [
    'build',
    target,
    '--execution_log_json_file=${log.path}',
    '--materialize_param_files',
  ];

  FlowMeasurement _clean(ScalePaths p) {
    final log = File('${p.logsDir}/exec_clean.json');
    final timed = _timed(p, _buildArgs('//app:app', log));
    if (timed.result.exitCode != 0) return _fromLog(timed, log);
    final same = _sameOutputsOnSecondBase(p);
    return _fromLog(timed, log, reproducible: same);
  }

  /// Builds `//app:app` into a second output base and compares output bytes.
  bool _sameOutputsOnSecondBase(ScalePaths p) {
    final other = ScalePaths(
      workspace: p.workspace,
      outputBase: '${p.outputBase}_repro',
      logsDir: p.logsDir,
      profileFile: p.profileFile,
    );
    try {
      _bazelOk(other, ['build', '//app:app']);
      final first = _outputBytes(p);
      final second = _outputBytes(other);
      return first.length == second.length &&
          first.entries.every((e) => _sameBytes(e.value, second[e.key]));
    } finally {
      _bazel(other.workspace, other.outputBase, ['shutdown']);
      forceDeleteDirectorySync(Directory(other.outputBase));
    }
  }

  bool _sameBytes(List<int> a, List<int>? b) {
    if (b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Map<String, List<int>> _outputBytes(ScalePaths p) {
    final execroot = (_bazelOk(p, ['info', 'execution_root']).stdout as String)
        .trim();
    final files =
        (_bazelOk(p, ['cquery', '--output=files', '//app:app']).stdout
                as String)
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty);
    return {for (final f in files) f: File('$execroot/$f').readAsBytesSync()};
  }

  FlowMeasurement _edit(ScalePaths p, void Function(String) apply) {
    apply(p.workspace);
    final log = File('${p.logsDir}/exec_edit.json');
    return _fromLog(_timed(p, _buildArgs('//app:app', log)), log);
  }

  FlowMeasurement _leafTest(ScalePaths p, String target) {
    _bazelOk(p, ['test', target]);
    applyLeafBodyEdit(
      p.workspace,
      target.split(':').first.replaceFirst('//packages/', ''),
    );
    final log = File('${p.logsDir}/exec_test.json');
    final timed = _timed(p, [
      'test',
      target,
      '--execution_log_json_file=${log.path}',
      '--materialize_param_files',
    ]);
    return _fromLog(timed, log);
  }

  /// `build --nobuild` on a freshly started server over the warm output base.
  FlowMeasurement _analysis(ScalePaths p) {
    _bazelOk(p, ['shutdown']);
    final timed = _timed(p, [
      'build',
      '--nobuild',
      '//app:app',
      '--starlark_cpu_profile=${p.profileFile}',
    ]);
    if (timed.result.exitCode != 0) {
      return FlowMeasurement.failed('${timed.result.stderr}');
    }
    final aquery = _bazelOk(p, ['aquery', '--output=jsonproto', '//app:app']);
    final actions =
        (jsonDecode(aquery.stdout as String) as Map<String, dynamic>)['actions']
            as List<dynamic>? ??
        const [];
    return FlowMeasurement(
      cpuSeconds: timed.cpu,
      wallSeconds: timed.wall,
      actionCount: actions.length,
      maxCommandLineBytes: _largest([
        for (final a in actions.cast<Map<String, dynamic>>())
          [...(a['arguments'] as List<dynamic>? ?? const []).cast<String>()],
      ]),
    );
  }
}
