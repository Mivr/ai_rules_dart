/// Tests for the failure evidence of the scale bench and its heap figures.
library;

import 'dart:convert';
import 'dart:io';

import 'package:perf/proc.dart';
import 'package:perf/scale_measure.dart';
import 'package:perf/scale_report.dart';
import 'package:perf/server_evidence.dart';
import 'package:perf/server_heap.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

void _contains(String text, String part, String message) {
  _check(text.contains(part), '$message: missing "$part" in:\n$text');
}

const _pid = 4242;

ProcStat _server(int starttime) => ProcStat(
  pid: _pid,
  ppid: 1,
  utime: 10,
  stime: 5,
  cutime: 0,
  cstime: 0,
  starttime: starttime,
);

/// Serves the scripted process tables in turn; the last one repeats.
final class _ScriptedReader implements ProcReader {
  _ScriptedReader(this.tables);

  final List<Map<int, ProcStat>> tables;
  int _reads = 0;

  @override
  int get clockTicksPerSecond => 100;

  @override
  int get pageSizeBytes => 4096;

  @override
  Map<int, ProcStat> readAllProcesses() =>
      tables[_reads < tables.length ? _reads++ : tables.length - 1];
}

/// What the fake `bazel` does for the measured build.
typedef _OnBuild = ProcessResult Function(String outputBase);

ProcessResult _result(int code, {String out = '', String err = ''}) =>
    ProcessResult(1, code, out, err);

BazelRunner _fakeBazel(_OnBuild onBuild) =>
    (ws, base, args) => switch (args) {
      ['query', ...] => _result(0, out: '//packages/a:t\n'),
      ['shutdown'] => _result(0),
      ['info', 'server_pid'] => _result(0, out: '$_pid\n'),
      ['build', '--nobuild', ...] => _result(0),
      _ => onBuild(base),
    };

String _numbered(String prefix, int count) =>
    [for (var i = 1; i <= count; i++) '$prefix$i'].join('\n');

/// Fixture files for the host evidence, plus the output base logs.
final class _Fixture {
  _Fixture() : dir = Directory.systemTemp.createTempSync('rd_evidence_') {
    Directory('${dir.path}/ws-32').createSync();
    File('${dir.path}/ws-32/BUILD').writeAsStringSync('x');
    cgroup.writeAsStringSync('populated 1\noom_kill 1\n');
    File(
      '${dir.path}/meminfo',
    ).writeAsStringSync('MemTotal: 8000 kB\nMemAvailable: 123456 kB\n');
  }

  final Directory dir;

  File get cgroup => File('${dir.path}/memory.events');

  EvidenceSources sources({bool meminfo = true}) => EvidenceSources(
    meminfoPath: '${dir.path}/${meminfo ? 'meminfo' : 'no-meminfo'}',
    cgroupEventsPath: (_) => cgroup.path,
  );

  /// Writes the server logs of [outputBase]; [javaLog] false leaves it out.
  void writeLogs(String outputBase, {bool javaLog = true}) {
    Directory('$outputBase/server').createSync(recursive: true);
    File('$outputBase/server/jvm.out').writeAsStringSync(_numbered('jvm', 60));
    if (javaLog) {
      File('$outputBase/java.log.host.user.1').writeAsStringSync('old\n');
      File(
        '$outputBase/java.log.host.user.2',
      ).writeAsStringSync(_numbered('jlog', 60));
    }
  }

  /// Runs the 32-library size, returning the error of `dart-app-clean`.
  String cleanError({
    required BazelRunner runner,
    required ProcReader reader,
    EvidenceSources? evidence,
  }) {
    final measurements = ScaleMeasurer(
      workspaceRoot: dir.path,
      tempRoot: '${dir.path}/tmp',
      profileDir: '${dir.path}/profiles',
      procReader: reader,
      bazelRunner: runner,
      evidenceSources: evidence ?? sources(),
    ).call(32);
    final error = measurements['dart-app-clean']!.error;
    _check(error != null, 'dart-app-clean failed');
    return error!;
  }

  void delete() => dir.deleteSync(recursive: true);
}

void _testCommandFailureFirst() {
  final f = _Fixture();
  try {
    final alive = {_pid: _server(7)};
    final error = f.cleanError(
      reader: _ScriptedReader([alive]),
      runner: _fakeBazel(
        (_) => _result(1, err: '${_numbered('err', 50)}\nboom: no space'),
      ),
    );
    _contains(error, 'exited with code 1', 'exit code');
    _contains(error, 'build //app:app', 'command named');
    _contains(error, 'boom: no space', 'stderr tail');
    _contains(error, 'err12', 'stderr keeps 40 lines');
    _check(!error.contains('err11\n'), 'stderr tail drops older lines');
    _check(!error.contains('missing from /proc'), 'no PID error: $error');
    _check(!error.contains('jvm.out'), 'live server needs no server logs');
  } finally {
    f.delete();
  }
}

void _testVanishedServerEvidence() {
  final f = _Fixture();
  try {
    final error = f.cleanError(
      reader: _ScriptedReader([
        {_pid: _server(7)},
        <int, ProcStat>{},
      ]),
      runner: _fakeBazel((base) {
        f.writeLogs(base);
        f.cgroup.writeAsStringSync('populated 1\noom_kill 3\n');
        return _result(0);
      }),
    );
    _contains(error, 'Bazel server PID $_pid is missing from /proc', 'pid');
    _contains(error, 'oom_kill before=1 after=3 delta=2', 'oom delta');
    _contains(error, 'MemAvailable: 123456 kB', 'meminfo');
    _contains(error, 'jvm60', 'jvm.out tail');
    _contains(error, 'jvm21', 'jvm.out keeps 40 lines');
    _check(!error.contains('jvm20\n'), 'jvm.out tail drops older lines');
    _contains(error, 'jlog60', 'newest java.log tail');
    _check(!error.contains('old'), 'older java.log ignored: $error');
  } finally {
    f.delete();
  }
}

void _testRestartedServerEvidence() {
  final f = _Fixture();
  try {
    final error = f.cleanError(
      reader: _ScriptedReader([
        {_pid: _server(7)},
        {_pid: _server(99)},
      ]),
      runner: _fakeBazel((base) {
        f.writeLogs(base);
        return _result(0);
      }),
    );
    _contains(error, 'starttime changed for PID $_pid: 7 -> 99', 'restart');
    _contains(error, 'oom_kill before=1 after=1 delta=0', 'oom delta');
    _contains(error, 'jvm60', 'jvm.out tail');
    _contains(error, 'jlog60', 'java.log tail');
  } finally {
    f.delete();
  }
}

void _testUnreadableSourcesAreNamed() {
  final f = _Fixture();
  try {
    final error = f.cleanError(
      reader: _ScriptedReader([
        {_pid: _server(7)},
        <int, ProcStat>{},
      ]),
      evidence: EvidenceSources(
        meminfoPath: '${f.dir.path}/no-meminfo',
        cgroupEventsPath: (_) => '${f.dir.path}/no-cgroup/memory.events',
      ),
      runner: _fakeBazel((base) {
        Directory('$base/server').createSync(recursive: true);
        return _result(0);
      }),
    );
    _contains(error, 'oom_kill unknown', 'cgroup named');
    _contains(error, 'memory.events unreadable', 'cgroup error');
    _contains(error, 'MemAvailable: unreadable', 'meminfo named');
    _contains(error, 'jvm.out unreadable', 'jvm.out named');
    _contains(error, 'java.log unreadable', 'java.log named');
  } finally {
    f.delete();
  }
}

void _testHeapParsing() {
  final heap = parseServerHeap(
    'max-heap-size: 4294967296\nused-heap-size-after-gc: 512MB\n',
  );
  _check(heap.maxHeapBytes == 4294967296, 'max heap in bytes');
  _check(heap.usedAfterGcBytes == 512 * 1024 * 1024, 'MB suffix scaled');
  try {
    parseServerHeap('max-heap-size: 1\n');
  } on FormatException catch (e) {
    _contains(e.message, 'used-heap-size-after-gc', 'missing key named');
    return;
  }
  throw StateError('FAIL: a missing heap figure is an error');
}

SizeMeasurements _measured(int libraries, {ServerHeap? heap}) => {
  for (final flow in scaleFlows)
    flow: FlowMeasurement(
      cpuSeconds: libraries * 2.0,
      wallSeconds: libraries * 2.0,
      actionCount: libraries,
      maxCommandLineBytes: libraries,
      serverHeap: heap,
    ),
};

Map<String, Object?> _report(Map<int, SizeMeasurements> bySize) =>
    buildScaleReport(
      bySize: bySize,
      ceilings: {for (final flow in scaleFlows) flow: 1.5},
      seed: 3,
    ).report;

void _testReportHeapKey() {
  const heap = ServerHeap(maxHeapBytes: 4096, usedAfterGcBytes: 1024);
  final plain = _report({32: _measured(32), 1000: _measured(1000)});
  final withHeap = _report({
    32: _measured(32, heap: heap),
    1000: _measured(1000, heap: heap),
  });
  final shared = {...withHeap}..remove('server_heap');
  _check(
    jsonEncode(shared) == jsonEncode({...plain}..remove('server_heap')),
    'every other key is what a run without heap figures writes',
  );
  _check(
    plain.keys.join(',') == 'schema,seed,sizes,flows,problems,server_heap',
    'keys and order: ${plain.keys}',
  );
  _check(plain['schema'] == 1, 'schema stays 1');
  _check((plain['server_heap']! as Map).isEmpty, 'no heap, no entries');
  final perSize = withHeap['server_heap']! as Map<String, Object?>;
  _check(perSize.keys.join(',') == '32,1000', 'heap per size');
  for (final size in perSize.values) {
    final perFlow = size! as Map<String, Object?>;
    _check(perFlow.keys.join(',') == scaleFlows.join(','), 'heap per flow');
    _check(
      jsonEncode(perFlow['dart-app-clean']) ==
          '{"max_heap_bytes":4096,"used_heap_after_gc_bytes":1024}',
      'heap figures: ${perFlow['dart-app-clean']}',
    );
  }
}

void main() {
  _testCommandFailureFirst();
  _testVanishedServerEvidence();
  _testRestartedServerEvidence();
  _testUnreadableSourcesAreNamed();
  _testHeapParsing();
  _testReportHeapKey();
  stdout.writeln('Server evidence tests passed.');
}
