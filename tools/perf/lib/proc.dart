/// Process statistics and warm-server CPU delta tracking via Linux /proc.
library;

import 'dart:ffi';
import 'dart:io';

typedef _SysconfC = Long Function(Int32 name);
typedef _SysconfDart = int Function(int name);

int _detectClockTicksPerSecond() {
  if (!Platform.isLinux) return 100;
  try {
    final sysconf = DynamicLibrary.process()
        .lookupFunction<_SysconfC, _SysconfDart>('sysconf');
    // _SC_CLK_TCK is 2 on Linux (glibc / musl).
    final ticks = sysconf(2);
    if (ticks > 0) return ticks;
  } on ArgumentError catch (e) {
    stderr.writeln('sysconf(_SC_CLK_TCK) lookup failed: $e');
  }
  return 100;
}

/// Parsed process stat fields from `/proc/<pid>/stat`.
final class ProcStat {
  /// Creates a process stat record.
  const ProcStat({
    required this.pid,
    required this.ppid,
    required this.utime,
    required this.stime,
    required this.cutime,
    required this.cstime,
    required this.starttime,
  });

  /// Process ID.
  final int pid;

  /// Parent process ID.
  final int ppid;

  /// Time scheduled in user mode, in clock ticks.
  final int utime;

  /// Time scheduled in kernel mode, in clock ticks.
  final int stime;

  /// Waited-for children scheduled in user mode, in clock ticks.
  final int cutime;

  /// Waited-for children scheduled in kernel mode, in clock ticks.
  final int cstime;

  /// Process start time after system boot, in clock ticks.
  final int starttime;

  /// Total CPU ticks accumulated by this process and reaped children.
  int get totalTicks => utime + stime + cutime + cstime;
}

/// Parses the contents of a `/proc/<pid>/stat` line.
ProcStat? parseProcStat(String line) {
  final openParen = line.indexOf('(');
  final lastParen = line.lastIndexOf(')');
  if (openParen == -1 || lastParen == -1 || lastParen <= openParen) {
    return null;
  }

  final pidPart = line.substring(0, openParen).trim();
  final pid = int.tryParse(pidPart);
  if (pid == null) return null;

  final rest = line.substring(lastParen + 1).trim();
  final tokens = rest.split(RegExp(r'\s+'));
  if (tokens.length < 20) return null;

  final ppid = int.tryParse(tokens[1]);
  final utime = int.tryParse(tokens[11]);
  final stime = int.tryParse(tokens[12]);
  final cutime = int.tryParse(tokens[13]);
  final cstime = int.tryParse(tokens[14]);
  final starttime = int.tryParse(tokens[19]);

  if (ppid == null ||
      utime == null ||
      stime == null ||
      cutime == null ||
      cstime == null ||
      starttime == null) {
    return null;
  }

  return ProcStat(
    pid: pid,
    ppid: ppid,
    utime: utime,
    stime: stime,
    cutime: cutime,
    cstime: cstime,
    starttime: starttime,
  );
}

/// Interface for reading process stats, allowing offline unit testing.
abstract interface class ProcReader {
  /// Returns a snapshot of running processes mapped by PID.
  Map<int, ProcStat> readAllProcesses();

  /// System clock ticks per second (`SC_CLK_TCK`).
  int get clockTicksPerSecond;
}

/// Linux `/proc` reader implementation.
final class LinuxProcReader implements ProcReader {
  /// Creates a Linux `/proc` reader.
  const LinuxProcReader({int? clockTicksPerSecond})
    : _clockTicksOverride = clockTicksPerSecond;

  final int? _clockTicksOverride;

  static final int _detectedClockTicks = _detectClockTicksPerSecond();

  @override
  int get clockTicksPerSecond => _clockTicksOverride ?? _detectedClockTicks;

  @override
  Map<int, ProcStat> readAllProcesses() {
    final result = <int, ProcStat>{};
    final procDir = Directory('/proc');
    if (!procDir.existsSync()) return result;

    try {
      final entries = procDir.listSync(followLinks: false);
      for (final entry in entries) {
        if (entry is! Directory) continue;
        final name = entry.uri.pathSegments.reversed.skip(1).firstOrNull ?? '';
        final pid = int.tryParse(name);
        if (pid == null) continue;
        final stat = _readSingleStat('${entry.path}/stat');
        if (stat != null) result[pid] = stat;
      }
    } on FileSystemException catch (e) {
      stderr.writeln('Proc dir list error: $e');
    }
    return result;
  }

  ProcStat? _readSingleStat(String statPath) {
    try {
      final statFile = File(statPath);
      if (!statFile.existsSync()) return null;
      return parseProcStat(statFile.readAsStringSync());
    } on FileSystemException catch (e) {
      stderr.writeln('Transient /proc stat read skipped ($statPath): $e');
      return null;
    }
  }
}

/// Test proc reader using an in-memory process map.
final class FakeProcReader implements ProcReader {
  /// Creates an in-memory process reader with the given processes.
  FakeProcReader(this.processes, {this.clockTicksPerSecond = 100});

  /// In-memory map of PID to ProcStat.
  final Map<int, ProcStat> processes;

  @override
  final int clockTicksPerSecond;

  @override
  Map<int, ProcStat> readAllProcesses() => Map.of(processes);
}

/// Snapshot of the Bazel server and its live descendant processes.
final class ServerTreeSnapshot {
  /// Creates a server tree snapshot.
  const ServerTreeSnapshot({
    required this.serverPid,
    required this.serverStarttime,
    required this.serverTicks,
    required this.descendantPids,
    required this.descendantTicks,
  });

  /// The Bazel server PID.
  final int serverPid;

  /// The server's starttime tick count.
  final int serverStarttime;

  /// Server's own `utime + stime + cutime + cstime`.
  final int serverTicks;

  /// Set of live descendant PIDs at snapshot time.
  final Set<int> descendantPids;

  /// Total ticks across live descendants.
  final int descendantTicks;

  /// Combined ticks across server and live descendants.
  int get totalTicks => serverTicks + descendantTicks;
}

/// Samples the Bazel server tree and calculates total CPU ticks.
ServerTreeSnapshot takeServerTreeSnapshot(ProcReader reader, int serverPid) {
  final procs = reader.readAllProcesses();
  final server = procs[serverPid];
  if (server == null) {
    throw StateError('Bazel server PID $serverPid is missing from /proc');
  }

  final childrenMap = <int, List<int>>{};
  for (final p in procs.values) {
    childrenMap.putIfAbsent(p.ppid, () => <int>[]).add(p.pid);
  }

  final descendants = <int>{};
  final queue = <int>[serverPid];
  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    final children = childrenMap[current] ?? const <int>[];
    for (final child in children) {
      if (child != serverPid && descendants.add(child)) {
        queue.add(child);
      }
    }
  }

  var descTicks = 0;
  for (final dPid in descendants) {
    final d = procs[dPid];
    if (d != null) {
      descTicks += d.totalTicks;
    }
  }

  return ServerTreeSnapshot(
    serverPid: serverPid,
    serverStarttime: server.starttime,
    serverTicks: server.totalTicks,
    descendantPids: descendants,
    descendantTicks: descTicks,
  );
}

/// Computes warm-server CPU seconds between two snapshots.
double computeWarmServerCpuDelta({
  required ServerTreeSnapshot before,
  required ServerTreeSnapshot after,
  required int clockTicksPerSecond,
}) {
  if (clockTicksPerSecond <= 0) {
    throw ArgumentError.value(
      clockTicksPerSecond,
      'clockTicksPerSecond',
      'must be positive',
    );
  }
  if (before.serverPid != after.serverPid) {
    throw StateError(
      'Server PID mismatch: ${before.serverPid} != ${after.serverPid}',
    );
  }
  if (before.serverStarttime != after.serverStarttime) {
    throw StateError(
      'Server starttime changed for PID ${before.serverPid}: '
      '${before.serverStarttime} -> ${after.serverStarttime}',
    );
  }

  final deltaTicks = after.totalTicks - before.totalTicks;
  if (deltaTicks < 0) {
    throw StateError(
      'Negative server CPU tick delta for PID ${before.serverPid}: '
      '${before.totalTicks} -> ${after.totalTicks}',
    );
  }
  return deltaTicks / clockTicksPerSecond;
}
