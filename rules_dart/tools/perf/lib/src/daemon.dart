/// A client of the stock tool's `--machine` protocol (JSON-RPC lines on
/// stdin and stdout), enough to start an app, hot reload, hot restart and
/// stop it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Decodes one `--machine` stdout line: a JSON list of messages, or nothing
/// for a plain line.
List<Map<String, Object?>> decodeMachineLine(String line) {
  final t = line.trim();
  if (!t.startsWith('[{')) return const [];
  try {
    return [
      for (final m in jsonDecode(t) as List) (m as Map).cast<String, Object?>(),
    ];
  } on FormatException {
    return const [];
  }
}

/// One `flutter run --machine` (or `flutter_dev run --machine`) session.
final class MachineSession {
  MachineSession._(this._process, this._log) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_line);
    _process.stderr
        .transform(utf8.decoder)
        .listen((s) => _log?.writeAsStringSync(s, mode: FileMode.append));
    _process.exitCode.then((c) {
      _exit = c;
      for (final w in [..._waiters]) {
        w.completer.completeError(StateError('the session exited with $c'));
      }
      _waiters.clear();
    });
  }

  final Process _process;
  final File? _log;
  final _seen = <Map<String, Object?>>[];
  final _waiters =
      <
        ({
          bool Function(Map<String, Object?>) test,
          Completer<Map<String, Object?>> completer,
        })
      >[];
  var _nextId = 1;
  int? _exit;

  /// The app id from `app.start`.
  String? appId;

  /// Starts [argv] in [cwd] with [environment].
  static Future<MachineSession> start(
    List<String> argv,
    String cwd,
    Map<String, String> environment, {
    File? log,
  }) async {
    final p = await Process.start(
      argv.first,
      argv.skip(1).toList(),
      workingDirectory: cwd,
      environment: environment,
    );
    return MachineSession._(p, log);
  }

  void _line(String line) {
    _log?.writeAsStringSync('$line\n', mode: FileMode.append);
    for (final m in decodeMachineLine(line)) {
      if (m['event'] == 'app.start') {
        appId = ((m['params'] as Map?)?['appId']) as String?;
      }
      _seen.add(m);
      for (final w in [..._waiters]) {
        if (w.test(m)) {
          _waiters.remove(w);
          w.completer.complete(m);
        }
      }
    }
  }

  /// The first message (seen or to come) that [test] accepts.
  Future<Map<String, Object?>> waitFor(
    bool Function(Map<String, Object?>) test, {
    Duration timeout = const Duration(minutes: 5),
  }) {
    for (final m in _seen) {
      if (test(m)) return Future.value(m);
    }
    if (_exit != null) {
      return Future.error(StateError('the session exited with $_exit'));
    }
    final c = Completer<Map<String, Object?>>();
    _waiters.add((test: test, completer: c));
    return c.future.timeout(timeout);
  }

  /// Waits for the event [name].
  Future<Map<String, Object?>> event(
    String name, {
    Duration timeout = const Duration(minutes: 5),
  }) => waitFor((m) => m['event'] == name, timeout: timeout);

  /// Sends [method] and returns its response; throws on an error response.
  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> params, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final id = _nextId++;
    _process.stdin.writeln(
      jsonEncode([
        {'id': id, 'method': method, 'params': params},
      ]),
    );
    final r = await waitFor(
      (m) => m['id'] == id && !m.containsKey('method'),
      timeout: timeout,
    );
    if (r['error'] != null) throw StateError('$method: ${r['error']}');
    return r;
  }

  /// Hot reload ([full] false) or hot restart; throws when the tool reports
  /// a failure.
  Future<void> restart({required bool full}) async {
    final r = await request('app.restart', {
      'appId': appId,
      'fullRestart': full,
      'pause': false,
      'reason': 'bench',
    });
    final result = r['result'];
    if (result is Map && (result['code'] ?? 0) != 0) {
      throw StateError('app.restart: ${result['message']}');
    }
  }

  /// Stops the app and the tool.
  Future<void> stop() async {
    if (_exit == null && appId != null) {
      try {
        await request('app.stop', {
          'appId': appId,
        }, timeout: const Duration(seconds: 30));
      } on Object {
        // Stopping is best effort; the process is killed below.
      }
    }
    _process.kill();
    await _process.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -9;
      },
    );
  }
}
