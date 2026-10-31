/// Unit tests for `/proc/<pid>/stat` parsing and warm-server CPU delta math.
library;

import 'dart:io';

import 'package:perf/proc.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

void _expectStateError(void Function() action, String message) {
  try {
    action();
  } on StateError catch (e) {
    _check(e.message.isNotEmpty, message);
    return;
  }
  throw StateError('FAIL: $message (expected StateError)');
}

void _testParseProcStat() {
  const sampleLine =
      '12345 (bazel (jvm) server) S 1000 12345 1000 0 -1 4194304 100 200 0 0 '
      '500 250 100 50 20 -5 1 0 98765 12345678 1000 18446744073709551615';

  final stat = parseProcStat(sampleLine);
  _check(stat != null, 'parseProcStat returned non-null');
  _check(stat!.pid == 12345, 'pid == 12345');
  _check(stat.ppid == 1000, 'ppid == 1000');
  _check(stat.utime == 500, 'utime == 500');
  _check(stat.stime == 250, 'stime == 250');
  _check(stat.cutime == 100, 'cutime == 100');
  _check(stat.cstime == 50, 'cstime == 50');
  _check(stat.starttime == 98765, 'starttime == 98765');
  _check(stat.totalTicks == 900, 'totalTicks == 900');

  _check(parseProcStat('invalid text') == null, 'invalid text returns null');
  _check(
    parseProcStat('123 (short) S 1 2 3') == null,
    'truncated stat fields return null',
  );
}

ServerTreeSnapshot _buildInitialServerSnapshot() {
  final procsBefore = <int, ProcStat>{
    100: const ProcStat(
      pid: 100,
      ppid: 1,
      utime: 200,
      stime: 100,
      cutime: 50,
      cstime: 25,
      starttime: 1000,
    ),
    200: const ProcStat(
      pid: 200,
      ppid: 100,
      utime: 80,
      stime: 20,
      cutime: 0,
      cstime: 0,
      starttime: 1050,
    ),
    300: const ProcStat(
      pid: 300,
      ppid: 200,
      utime: 30,
      stime: 10,
      cutime: 0,
      cstime: 0,
      starttime: 1100,
    ),
    999: const ProcStat(
      pid: 999,
      ppid: 1,
      utime: 500,
      stime: 500,
      cutime: 0,
      cstime: 0,
      starttime: 500,
    ),
  };

  final readerBefore = FakeProcReader(procsBefore, clockTicksPerSecond: 250);
  final snap = takeServerTreeSnapshot(readerBefore, 100);
  _check(snap.serverPid == 100, 'serverPid');
  _check(snap.serverStarttime == 1000, 'serverStarttime');
  _check(snap.serverTicks == 375, 'serverTicks = 200+100+50+25');
  _check(snap.descendantPids.contains(200), 'worker 200 is descendant');
  _check(snap.descendantPids.contains(300), 'child 300 is descendant');
  _check(!snap.descendantPids.contains(999), '999 excluded');
  _check(snap.descendantTicks == 140, 'descendantTicks = 100 + 40');
  _check(snap.totalTicks == 515, 'totalTicks = 375 + 140');
  return snap;
}

void _testVanishedDescendantDelta() {
  final snapBefore = _buildInitialServerSnapshot();
  final procsAfter = <int, ProcStat>{
    100: const ProcStat(
      pid: 100,
      ppid: 1,
      utime: 255,
      stime: 130,
      cutime: 80,
      cstime: 35,
      starttime: 1000,
    ),
    200: const ProcStat(
      pid: 200,
      ppid: 100,
      utime: 120,
      stime: 45,
      cutime: 0,
      cstime: 0,
      starttime: 1050,
    ),
  };

  final readerAfter = FakeProcReader(procsAfter, clockTicksPerSecond: 250);
  final snapAfter = takeServerTreeSnapshot(readerAfter, 100);

  _check(!snapAfter.descendantPids.contains(300), '300 vanished cleanly');
  _check(snapAfter.totalTicks == 665, 'totalTicks after = 500 + 165');

  final deltaCpu = computeWarmServerCpuDelta(
    before: snapBefore,
    after: snapAfter,
    clockTicksPerSecond: readerAfter.clockTicksPerSecond,
  );
  _check(
    (deltaCpu - 0.60).abs() < 1e-6,
    'deltaCpu matches 0.60s at 250 Hz, got $deltaCpu',
  );
}

void _testFailClosedCases() {
  final emptyReader = FakeProcReader(const {});
  _expectStateError(
    () => takeServerTreeSnapshot(emptyReader, 100),
    'Fails closed when server PID is missing or vanished',
  );

  const snapBefore = ServerTreeSnapshot(
    serverPid: 100,
    serverStarttime: 1000,
    serverTicks: 200,
    descendantPids: {},
    descendantTicks: 0,
  );
  const snapRestarted = ServerTreeSnapshot(
    serverPid: 100,
    serverStarttime: 2000,
    serverTicks: 250,
    descendantPids: {},
    descendantTicks: 0,
  );
  _expectStateError(
    () => computeWarmServerCpuDelta(
      before: snapBefore,
      after: snapRestarted,
      clockTicksPerSecond: 100,
    ),
    'Fails closed on server starttime mismatch',
  );

  const snapDiffPid = ServerTreeSnapshot(
    serverPid: 101,
    serverStarttime: 1000,
    serverTicks: 250,
    descendantPids: {},
    descendantTicks: 0,
  );
  _expectStateError(
    () => computeWarmServerCpuDelta(
      before: snapBefore,
      after: snapDiffPid,
      clockTicksPerSecond: 100,
    ),
    'Fails closed on server PID mismatch',
  );

  const snapNegative = ServerTreeSnapshot(
    serverPid: 100,
    serverStarttime: 1000,
    serverTicks: 150,
    descendantPids: {},
    descendantTicks: 0,
  );
  _expectStateError(
    () => computeWarmServerCpuDelta(
      before: snapBefore,
      after: snapNegative,
      clockTicksPerSecond: 100,
    ),
    'Fails closed on negative tick delta',
  );
}

void main() {
  _testParseProcStat();
  _testVanishedDescendantDelta();
  _testFailClosedCases();
  stdout.writeln('All proc tests passed.');
}
