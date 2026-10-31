/// Unit tests for /proc parsing and warm-server delta tracking.
library;

import 'dart:io';

import 'package:perf/proc.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

void _testParseProcStat() {
  const sampleLine =
      '12345 (bazel(server)) S 1000 12345 1000 0 -1 4194304 100 200 0 0 '
      '500 250 100 50 20 0 1 0 98765 12345678 1000 18446744073709551615';

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

  // Invalid line
  _check(parseProcStat('invalid text') == null, 'invalid text returns null');
}

void _testServerTreeSnapshotAndDelta() {
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
    // Worker 1: child of 100
    200: const ProcStat(
      pid: 200,
      ppid: 100,
      utime: 80,
      stime: 20,
      cutime: 0,
      cstime: 0,
      starttime: 1050,
    ),
    // Grandchild of 100 (child of worker 200)
    300: const ProcStat(
      pid: 300,
      ppid: 200,
      utime: 30,
      stime: 10,
      cutime: 0,
      cstime: 0,
      starttime: 1100,
    ),
    // Unrelated process
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

  final readerBefore = FakeProcReader(procsBefore, clockTicksPerSecond: 100);
  final snapBefore = takeServerTreeSnapshot(readerBefore, 100);

  _check(snapBefore.serverPid == 100, 'serverPid');
  _check(snapBefore.serverStarttime == 1000, 'serverStarttime');
  _check(snapBefore.serverTicks == 375, 'serverTicks = 200+100+50+25');
  _check(snapBefore.descendantPids.contains(200), 'worker 200 is descendant');
  _check(
    snapBefore.descendantPids.contains(300),
    'grandchild 300 is descendant',
  );
  _check(!snapBefore.descendantPids.contains(999), '999 is not descendant');
  _check(snapBefore.descendantTicks == 140, 'descendantTicks = 100 + 40');
  _check(snapBefore.totalTicks == 515, 'totalTicks = 375 + 140');

  // After run:
  // Server ran 50 ticks, reaped grandchild 300 (cutime increased by 40),
  // Worker 200 ran 40 ticks, grandchild 300 vanished.
  final procsAfter = <int, ProcStat>{
    100: const ProcStat(
      pid: 100,
      ppid: 1,
      utime: 230,
      stime: 120,
      cutime: 90,
      cstime: 25,
      starttime: 1000,
    ),
    200: const ProcStat(
      pid: 200,
      ppid: 100,
      utime: 110,
      stime: 30,
      cutime: 0,
      cstime: 0,
      starttime: 1050,
    ),
    // 300 vanished
  };

  final readerAfter = FakeProcReader(procsAfter, clockTicksPerSecond: 100);
  final snapAfter = takeServerTreeSnapshot(readerAfter, 100);

  _check(!snapAfter.descendantPids.contains(300), '300 vanished cleanly');
  _check(snapAfter.serverTicks == 465, 'serverTicks after = 230+120+90+25');
  _check(snapAfter.descendantTicks == 140, 'worker 200 ticks after = 110+30');
  _check(snapAfter.totalTicks == 605, 'totalTicks after = 465 + 140');

  final deltaCpu = computeWarmServerCpuDelta(
    before: snapBefore,
    after: snapAfter,
    clockTicksPerSecond: 100,
  );
  // (605 - 515) / 100 = 0.90 seconds
  _check(
    (deltaCpu - 0.90).abs() < 1e-4,
    'deltaCpu matches expected 0.90s, got $deltaCpu',
  );
}

void _testFailClosedCases() {
  // Case 1: Server PID missing
  final emptyReader = FakeProcReader(const {});
  var missingCaught = false;
  try {
    takeServerTreeSnapshot(emptyReader, 100);
  } catch (_) {
    missingCaught = true;
  }
  _check(missingCaught, 'Fails closed when server PID is missing');

  // Case 2: Starttime mismatch (server restarted under same PID)
  final snapBefore = const ServerTreeSnapshot(
    serverPid: 100,
    serverStarttime: 1000,
    serverTicks: 200,
    descendantPids: {},
    descendantTicks: 0,
  );
  final snapAfter = const ServerTreeSnapshot(
    serverPid: 100,
    serverStarttime: 2000, // changed!
    serverTicks: 50,
    descendantPids: {},
    descendantTicks: 0,
  );

  var mismatchCaught = false;
  try {
    computeWarmServerCpuDelta(
      before: snapBefore,
      after: snapAfter,
      clockTicksPerSecond: 100,
    );
  } catch (_) {
    mismatchCaught = true;
  }
  _check(mismatchCaught, 'Fails closed on server starttime mismatch');
}

void main() {
  _testParseProcStat();
  _testServerTreeSnapshotAndDelta();
  _testFailClosedCases();
  stdout.writeln('All proc tests passed.');
}
