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

/// Runs [cmd], appending its output to [log] when given.
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
  var code = timeout == null
      ? await p.exitCode
      : await p.exitCode.timeout(
          timeout,
          onTimeout: () {
            p.kill(ProcessSignal.sigkill);
            return -9;
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
