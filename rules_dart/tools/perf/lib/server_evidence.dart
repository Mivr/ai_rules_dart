/// Evidence about a Bazel server that failed or vanished during a command.
///
/// Every source is read when the failure is seen, before the next command can
/// start a server on the same output base and replace its logs. A source that
/// cannot be read is named in the text with the error; none is skipped.
library;

import 'dart:io';

/// Number of log lines kept from each server log and from stderr.
const int evidenceTailLines = 40;

/// Where the host-level evidence lives; tests point these at fixtures.
final class EvidenceSources {
  /// Creates the sources, defaulting to the Linux locations.
  const EvidenceSources({
    this.meminfoPath = '/proc/meminfo',
    this.cgroupEventsPath = linuxCgroupEventsPath,
  });

  /// File with the `MemAvailable` line.
  final String meminfoPath;

  /// Maps a server PID to its cgroup's `memory.events` file.
  final String Function(int pid) cgroupEventsPath;
}

/// Resolves `/sys/fs/cgroup/<path>/memory.events` for [pid] (cgroup v2).
///
/// Throws a [FileSystemException] when `/proc/<pid>/cgroup` cannot be read and
/// a [StateError] when the process has no cgroup v2 entry.
String linuxCgroupEventsPath(int pid) {
  final lines = File('/proc/$pid/cgroup').readAsLinesSync();
  for (final line in lines) {
    if (line.startsWith('0::')) {
      final path = line.substring(3).trim();
      return '/sys/fs/cgroup${path == '/' ? '' : path}/memory.events';
    }
  }
  throw StateError('/proc/$pid/cgroup has no cgroup v2 line');
}

/// Last [count] lines of [text].
String tailLines(String text, {int count = evidenceTailLines}) {
  final lines = text.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines.skip(lines.length > count ? lines.length - count : 0).join('\n');
}

/// The `oom_kill` counter of one cgroup, or why it could not be read.
final class OomReading {
  /// Creates a reading of [count] taken from [path].
  const OomReading.value(this.count, this.path) : error = null;

  /// Creates a reading that failed with [error].
  const OomReading.failed(String this.error) : count = null, path = null;

  /// The counter, or null when unreadable.
  final int? count;

  /// The `memory.events` file read.
  final String? path;

  /// Why the counter is unknown, or null.
  final String? error;
}

/// Reads `oom_kill` from the `memory.events` of [pid]'s cgroup.
///
/// Never throws: an unreadable source is returned as a failed reading that
/// says what failed.
OomReading readOomKill(EvidenceSources sources, int pid) {
  try {
    final path = sources.cgroupEventsPath(pid);
    for (final line in File(path).readAsLinesSync()) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length == 2 && parts[0] == 'oom_kill') {
        return OomReading.value(int.parse(parts[1]), path);
      }
    }
    return OomReading.failed('$path has no oom_kill line');
  } on FileSystemException catch (e) {
    return OomReading.failed('cgroup memory.events unreadable: $e');
  } on StateError catch (e) {
    return OomReading.failed('cgroup memory.events unreadable: ${e.message}');
  } on FormatException catch (e) {
    return OomReading.failed('cgroup memory.events malformed: ${e.message}');
  }
}

/// `MemAvailable` from the meminfo file, as text; names the error if unread.
String readMemAvailable(EvidenceSources sources) {
  try {
    for (final line in File(sources.meminfoPath).readAsLinesSync()) {
      if (line.startsWith('MemAvailable:')) {
        return line.substring('MemAvailable:'.length).trim();
      }
    }
    return 'unreadable: ${sources.meminfoPath} has no MemAvailable line';
  } on FileSystemException catch (e) {
    return 'unreadable: $e';
  }
}

/// The tail of [path] under a heading, or the error that stopped the read.
String describeTail(String heading, String path) {
  try {
    return '$heading ($path), last $evidenceTailLines lines:\n'
        '${tailLines(File(path).readAsStringSync())}';
  } on FileSystemException catch (e) {
    return '$heading unreadable: $e';
  } on FormatException catch (e) {
    return '$heading unreadable: ${e.message}';
  }
}

/// The newest `java.log.*` file of [outputBase], or null when there is none.
///
/// Files with the same modification time are ordered by name.
///
/// Bazel writes them to the output base itself, with a `java.log` link to the
/// latest; the link is skipped so the dated file is named.
File? newestJavaLog(String outputBase) {
  File? newest;
  DateTime? newestTime;
  for (final entity in Directory(outputBase).listSync(followLinks: false)) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (entity is! File || !name.startsWith('java.log.')) continue;
    final time = entity.statSync().modified;
    final newer =
        newestTime == null ||
        time.isAfter(newestTime) ||
        (time == newestTime && entity.path.compareTo(newest!.path) > 0);
    if (newer) {
      newest = entity;
      newestTime = time;
    }
  }
  return newest;
}

String _describeJavaLog(String outputBase) {
  try {
    final log = newestJavaLog(outputBase);
    if (log == null) return 'java.log unreadable: no java.log.* in $outputBase';
    return describeTail('java.log', log.path);
  } on FileSystemException catch (e) {
    return 'java.log unreadable: $e';
  }
}

/// Describes the server's death or restart, read now.
///
/// [oomBefore] is the counter read before the command started.
String describeServerLoss({
  required String outputBase,
  required int pid,
  required OomReading oomBefore,
  required EvidenceSources sources,
}) {
  final oomAfter = readOomKill(sources, pid);
  final String oom;
  if (oomBefore.count != null && oomAfter.count != null) {
    oom =
        'oom_kill before=${oomBefore.count} after=${oomAfter.count} '
        'delta=${oomAfter.count! - oomBefore.count!} (${oomAfter.path})';
  } else {
    oom =
        'oom_kill unknown: before: ${oomBefore.error ?? oomBefore.count}; '
        'after: ${oomAfter.error ?? oomAfter.count}';
  }
  return [
    oom,
    'MemAvailable: ${readMemAvailable(sources)}',
    describeTail('jvm.out', '$outputBase/server/jvm.out'),
    _describeJavaLog(outputBase),
  ].join('\n');
}

/// The failure text for a measured command that exited non-zero.
String describeCommandFailure({
  required List<String> args,
  required int exitCode,
  required String stderrText,
}) =>
    'bazel ${args.join(' ')} exited with code $exitCode; last '
    '$evidenceTailLines lines of stderr:\n${tailLines(stderrText)}';
