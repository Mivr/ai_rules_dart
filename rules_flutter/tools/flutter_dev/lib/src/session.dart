/// Runs the stock tool and, once the app has started, asks it for one hot restart.
///
/// Why the restart: the app starts with the kernel Bazel compiled, whose libraries have
/// `org-dartlang-app:///` URIs that no file on disk matches, so a debugger's breakpoints cannot
/// bind. After one hot restart the app runs the stock tool's own compile, with `file:` URIs.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The id of the request the tool injects; its response never reaches the client.
const String restartRequestId = 'flutter_dev.restart';

/// Sits between a `--machine` client (an IDE, a script) and the stock tool.
///
/// Every line passes through unchanged, with two exceptions: the `app.started` event is held back
/// until the injected restart has finished, so the client sees the app as started once it runs
/// the code the stock tool compiled; and the response to that restart is dropped.
class MachineProxy {
  /// A proxy writing to the tool with [toTool] and to the client with [toClient].
  new({
    required this.toTool,
    required this.toClient,
    required this.restart,
    this.log,
  });

  /// Writes a line to the stock tool's stdin.
  final void Function(String line) toTool;

  /// Writes a line to the client.
  final void Function(String line) toClient;

  /// Whether to restart after the launch.
  final bool restart;

  /// Progress messages (stderr).
  final void Function(String message)? log;

  String? _heldStarted;
  bool _sent = false;
  final Stopwatch _clock = Stopwatch();

  /// Handles one line the stock tool printed.
  void fromTool(String line) {
    final List<Map<String, Object?>>? messages = _decode(line);
    if (messages == null) {
      toClient(line);
      return;
    }
    if (_sent &&
        _heldStarted != null &&
        messages.any((Map<String, Object?> m) => m['id'] == restartRequestId)) {
      final Map<String, Object?> response = messages.firstWhere(
        (Map<String, Object?> m) => m['id'] == restartRequestId,
      );
      final Object? error =
          response['error'] ??
          ((response['result'] as Map<String, Object?>?)?['code'] == 0
              ? null
              : response['result']);
      log?.call(
        error == null
            ? 'flutter_dev: hot restart after launch took ${_clock.elapsedMilliseconds} ms'
            : 'flutter_dev: the hot restart after launch failed: $error',
      );
      final String held = _heldStarted!;
      _heldStarted = null;
      toClient(held);
      return;
    }
    if (restart && !_sent) {
      for (final Map<String, Object?> m in messages) {
        if (m['event'] != 'app.started') continue;
        final Object? appId = (m['params'] as Map<String, Object?>?)?['appId'];
        if (appId == null) break;
        _sent = true;
        _heldStarted = line;
        _clock.start();
        log?.call(
          'flutter_dev: hot restart after launch, so that breakpoints bind',
        );
        toTool(
          jsonEncode(<Object?>[
            <String, Object?>{
              'id': restartRequestId,
              'method': 'app.restart',
              'params': <String, Object?>{
                'appId': appId,
                'fullRestart': true,
                'pause': false,
                'reason': 'flutter_dev',
              },
            },
          ]),
        );
        return;
      }
    }
    toClient(line);
  }

  /// The messages of a protocol line (`[{...}]`), or null for any other output.
  static List<Map<String, Object?>>? _decode(String line) {
    final String t = line.trim();
    if (!t.startsWith('[{') || !t.endsWith('}]')) return null;
    try {
      return (jsonDecode(t) as List<Object?>)
          .whereType<Map<String, Object?>>()
          .toList();
    } on FormatException {
      return null;
    }
  }
}

/// Runs the stock tool in `--machine` mode through a [MachineProxy]; returns its exit code.
///
/// [input] and [output] default to this process's stdin and stdout.
Future<int> runMachine(
  String executable,
  List<String> args, {
  required String workingDirectory,
  required bool restart,
  required Map<String, String> environment,
  Stream<List<int>>? input,
  IOSink? output,
}) async {
  stderr.writeln('flutter_dev: $executable ${args.join(' ')}');
  final Process tool = await Process.start(
    executable,
    args,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: false,
  );
  final List<StreamSubscription<ProcessSignal>> signals = _forwardTermination(
    tool,
  );
  var toolInputOpen = true;
  final proxy = MachineProxy(
    toTool: (String line) {
      if (toolInputOpen) tool.stdin.writeln(line);
    },
    toClient: (String line) => (output ?? stdout).writeln(line),
    restart: restart,
    log: stderr.writeln,
  );
  final StreamSubscription<List<int>> forwarding = (input ?? stdin).listen(
    tool.stdin.add,
    onDone: () {
      toolInputOpen = false;
      tool.stdin.close().ignore();
    },
  );
  await Future.wait(<Future<void>>[
    tool.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(proxy.fromTool),
    tool.stderr.forEach(stderr.add),
  ]);
  final int code = await tool.exitCode;
  await forwarding.cancel();
  await (output ?? stdout).flush();
  for (final s in signals) {
    await s.cancel();
  }
  return code;
}

/// Runs the stock tool on the user's terminal. With [pidFile] and [restart], sends it SIGUSR2
/// (its hot restart signal) once it has written the file, which it does when the app is up.
Future<int> runTerminal(
  String executable,
  List<String> args, {
  required String workingDirectory,
  required bool restart,
  required Map<String, String> environment,
  String? pidFile,
}) async {
  stderr.writeln('flutter_dev: $executable ${args.join(' ')}');
  final Process tool = await Process.start(
    executable,
    args,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
    environment: environment,
    includeParentEnvironment: false,
  );
  final List<StreamSubscription<ProcessSignal>> signals = _forwardTermination(
    tool,
  );
  var exited = false;
  final Future<int> code = tool.exitCode.whenComplete(() => exited = true);
  if (restart && pidFile != null) {
    unawaited(_restartWhenUp(pidFile, () => exited));
  }
  final int result = await code;
  for (final s in signals) {
    await s.cancel();
  }
  return result;
}

Future<void> _restartWhenUp(String pidFile, bool Function() exited) async {
  final file = File(pidFile);
  while (!exited()) {
    if (file.existsSync()) {
      final int? pid = int.tryParse(file.readAsStringSync().trim());
      if (pid != null) {
        stderr.writeln(
          'flutter_dev: hot restart after launch, so that breakpoints bind',
        );
        Process.killPid(pid, ProcessSignal.sigusr2);
        return;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// Ctrl-C reaches the stock tool from the terminal, which cleans up and exits; this process waits
/// for it. A SIGTERM (an IDE stopping the session) is passed on.
/// The subscriptions end when the tool has exited.
List<StreamSubscription<ProcessSignal>> _forwardTermination(Process tool) {
  if (Platform.isWindows) return const <StreamSubscription<ProcessSignal>>[];
  return <StreamSubscription<ProcessSignal>>[
    ProcessSignal.sigint.watch().listen((_) {}),
    ProcessSignal.sigterm.watch().listen((_) => tool.kill()),
  ];
}
