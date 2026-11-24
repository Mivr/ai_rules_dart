/// Runs one command and times it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A command line with where and how it runs.
final class Cmd {
  /// A command [argv] run in [cwd] with [env] added to the environment.
  const Cmd(this.argv, {required this.cwd, this.env = const {}});

  /// The program and its arguments.
  final List<String> argv;

  /// The working directory.
  final String cwd;

  /// Variables set on top of the harness's environment.
  final Map<String, String> env;

  /// The command as one line, for notes and logs.
  String get display => [
    ...env.entries.map((e) => '${e.key}=${e.value}'),
    ...argv.map(_quote),
  ].join(' ');

  static String _quote(String a) => RegExp(r'^[\w@%+=:,./-]+$').hasMatch(a)
      ? a
      : "'${a.replaceAll("'", r"'\''")}'";
}

/// What one command did.
final class Done {
  /// A finished command.
  const Done(this.cmd, this.exitCode, this.seconds, this.stdout, this.stderr);

  /// The command.
  final Cmd cmd;

  /// Its exit code.
  final int exitCode;

  /// Wall-clock seconds from start to exit.
  final double seconds;

  /// Everything it wrote to stdout.
  final String stdout;

  /// Everything it wrote to stderr.
  final String stderr;

  /// Whether it exited with 0.
  bool get ok => exitCode == 0;

  /// The last [n] lines of stderr and stdout, for a failure note.
  String tail([int n = 15]) {
    final lines = '$stdout\n$stderr'
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    return lines.skip(lines.length > n ? lines.length - n : 0).join('\n');
  }
}

/// The longest one command may run, unless a call gives its own timeout;
/// null for no limit. `bench run --command-limit=MINUTES` sets it.
Duration? commandLimit;

/// A command that ran longer than its limit and was killed, with every
/// process below it. A flow that meets it is recorded as exceeded: that is
/// its result.
final class Exceeded implements Exception {
  /// [cmd] exceeded [limit].
  const Exceeded(this.cmd, this.limit);

  /// The command.
  final Cmd cmd;

  /// The limit it exceeded.
  final Duration limit;

  @override
  String toString() =>
      'exceeded ${limit.inMinutes} minutes: ${cmd.argv.join(' ')}';
}

/// Kills [root] and every process below it (from `/proc`), children first
/// found, so none is left holding the output pipes.
void killTree(int root) {
  final children = <int, List<int>>{};
  try {
    for (final e in Directory('/proc').listSync(followLinks: false)) {
      final pid = int.tryParse(
        e.uri.pathSegments.lastWhere((p) => p.isNotEmpty),
      );
      if (pid == null) continue;
      try {
        final stat = File('/proc/$pid/stat').readAsStringSync();
        final ppid = int.parse(
          stat.substring(stat.lastIndexOf(')') + 2).split(' ')[1],
        );
        (children[ppid] ??= []).add(pid);
      } on Object {
        // Gone already.
      }
    }
  } on FileSystemException {
    // A process left while listing: kill what was found.
  }
  final all = <int>[];
  final todo = [root];
  while (todo.isNotEmpty) {
    final pid = todo.removeLast();
    all.add(pid);
    todo.addAll(children[pid] ?? const []);
  }
  for (final pid in all) {
    Process.killPid(pid, ProcessSignal.sigkill);
  }
}

/// Runs [cmd], appending its output to [log] when given. A command that
/// runs longer than [timeout] (default [commandLimit]) is killed with its
/// process tree and throws [Exceeded].
Future<Done> runCmd(
  Cmd cmd, {
  void Function(int pid)? started,
  File? log,
  Duration? timeout,
}) async {
  final watch = Stopwatch()..start();
  final p = await Process.start(
    cmd.argv.first,
    cmd.argv.skip(1).toList(),
    workingDirectory: cmd.cwd,
    environment: cmd.env,
  );
  started?.call(p.pid);
  final out = StringBuffer();
  final err = StringBuffer();
  final a = p.stdout.transform(utf8.decoder).listen(out.write).asFuture<void>();
  final b = p.stderr.transform(utf8.decoder).listen(err.write).asFuture<void>();
  final limit = timeout ?? commandLimit;
  var exceeded = false;
  final code = limit == null
      ? await p.exitCode
      : await p.exitCode.timeout(
          limit,
          onTimeout: () {
            exceeded = true;
            killTree(p.pid);
            return p.exitCode;
          },
        );
  await Future.wait([a, b]);
  watch.stop();
  final done = Done(
    cmd,
    code,
    watch.elapsedMicroseconds / 1e6,
    out.toString(),
    err.toString(),
  );
  log?.writeAsStringSync(
    '\$ (cd ${cmd.cwd} && ${cmd.display})\n'
    '# exit ${done.exitCode} after ${done.seconds.toStringAsFixed(3)} s\n'
    '${done.stdout}${done.stderr}\n',
    mode: FileMode.append,
  );
  if (exceeded) throw Exceeded(cmd, limit!);
  return done;
}

/// Runs [cmd] and throws when it fails: for untimed set-up steps.
Future<Done> must(Cmd cmd, {File? log, Duration? timeout}) async {
  final done = await runCmd(cmd, log: log, timeout: timeout);
  if (!done.ok) {
    throw StateError(
      'set-up step failed (exit ${done.exitCode}): ${cmd.display}\n'
      'in ${cmd.cwd}\n${done.tail()}',
    );
  }
  return done;
}
