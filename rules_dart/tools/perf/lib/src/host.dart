/// What the host says while a flow runs: load, other Bazel servers, the
/// measured server's persistent workers and its killed-worker count, and the
/// resident memory of a process tree.
library;

import 'dart:async';
import 'dart:io';

/// Reads files under `/proc`; tests point it at a fixture directory.
final class Host {
  /// A host whose process table is at [procRoot].
  const Host({this.procRoot = '/proc'});

  /// Where the process table is.
  final String procRoot;

  /// The 1-minute load average, or null where `/proc/loadavg` is missing.
  double? load1() {
    try {
      final text = File('$procRoot/loadavg').readAsStringSync();
      return double.parse(text.split(' ').first);
    } on Object {
      return null;
    }
  }

  /// The process ids in the table.
  List<int> pids() {
    final dir = Directory(procRoot);
    if (!dir.existsSync()) return const [];
    // A process that exits while the table is listed makes the listing
    // fail; the next listing does not see it.
    for (var attempt = 0; ; attempt++) {
      try {
        return [
          for (final e in dir.listSync(followLinks: false))
            if (int.tryParse(e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
                case final int pid)
              pid,
        ];
      } on FileSystemException {
        if (attempt == 4) rethrow;
      }
    }
  }

  /// The command line of [pid], or null when it has gone.
  List<String>? cmdline(int pid) {
    try {
      final raw = File('$procRoot/$pid/cmdline').readAsStringSync();
      if (raw.isEmpty) return null;
      final parts = raw.split('\u0000');
      if (parts.last.isEmpty) parts.removeLast();
      return parts;
    } on Object {
      return null;
    }
  }

  /// The parent of [pid], or null.
  int? parent(int pid) {
    try {
      final stat = File('$procRoot/$pid/stat').readAsStringSync();
      // The command name is in parentheses and may hold spaces.
      final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
      return int.parse(fields[1]);
    } on Object {
      return null;
    }
  }

  /// Resident set of [pid] in bytes, or 0.
  int rssBytes(int pid) {
    try {
      final statm = File('$procRoot/$pid/statm').readAsStringSync();
      return int.parse(statm.split(' ')[1]) * 4096;
    } on Object {
      return 0;
    }
  }

  /// Output bases of every running Bazel server, by server pid.
  Map<int, String> bazelServers() {
    final servers = <int, String>{};
    for (final pid in pids()) {
      final args = cmdline(pid);
      if (args == null || !args.any((a) => a.endsWith('A-server.jar'))) {
        continue;
      }
      final base = args.firstWhere(
        (a) => a.startsWith('--output_base='),
        orElse: () => '--output_base=?',
      );
      servers[pid] = base.substring('--output_base='.length);
    }
    return servers;
  }

  /// The number of Bazel servers running for an output base other than
  /// [outputBase] (all of them when it is null).
  int otherBazelServers(String? outputBase) =>
      bazelServers().values.where((b) => b != outputBase).length;

  /// [root] and every process below it.
  Set<int> tree(int root) {
    final children = <int, List<int>>{};
    for (final pid in pids()) {
      final p = parent(pid);
      if (p != null) (children[p] ??= []).add(pid);
    }
    final out = <int>{};
    final todo = [root];
    while (todo.isNotEmpty) {
      final pid = todo.removeLast();
      if (out.add(pid)) todo.addAll(children[pid] ?? const []);
    }
    return out;
  }

  /// Persistent workers under the server [serverPid].
  Set<int> workers(int serverPid) => {
    for (final pid in tree(serverPid))
      if (pid != serverPid &&
          (cmdline(pid)?.contains('--persistent_worker') ?? false))
        pid,
  };
}

/// Lines in the server's `java.log` files that say a worker was destroyed
/// because the server could not tell its state (the failure that kept every
/// worker on this machine cold until 2026-11-23).
int killedUnknown(String outputBase) {
  var n = 0;
  final dir = Directory(outputBase);
  if (!dir.existsSync()) return 0;
  for (final e in dir.listSync(followLinks: false)) {
    final name = e.uri.pathSegments.last;
    if (e is! File || !name.startsWith('java.log.')) continue;
    try {
      for (final line in e.readAsLinesSync()) {
        if (line.contains('KILLED_UNKNOWN')) n++;
      }
    } on FileSystemException {
      // A log rotated away between listing and reading.
    }
  }
  return n;
}

/// The pid of the server of [outputBase], or null when none runs.
int? serverPid(String outputBase) {
  try {
    final pid = int.parse(
      File('$outputBase/server/server.pid.txt').readAsStringSync().trim(),
    );
    return Directory('/proc/$pid').existsSync() ? pid : null;
  } on Object {
    return null;
  }
}

/// Samples the summed resident set of a process tree until stopped.
final class RssSampler {
  /// Samples the tree under the pid [root] returns, every [every].
  RssSampler(
    this._root, {
    this.host = const Host(),
    this.every = const Duration(milliseconds: 200),
  });

  final int? Function() _root;

  /// The process table.
  final Host host;

  /// The sampling interval.
  final Duration every;

  Timer? _timer;
  int _peak = 0;

  /// Starts sampling.
  void start() {
    _sample();
    _timer = Timer.periodic(every, (_) => _sample());
  }

  void _sample() {
    final root = _root();
    if (root == null) return;
    var sum = 0;
    for (final pid in host.tree(root)) {
      sum += host.rssBytes(pid);
    }
    if (sum > _peak) _peak = sum;
  }

  /// Stops sampling and returns the peak in MB.
  double stop() {
    _timer?.cancel();
    _sample();
    return _peak / (1 << 20);
  }
}
