/// Drives a running app the way a coding agent does, through the stock tool's `--machine`
/// protocol and the debug agent (`package:rules_flutter_debug_agent`):
///
///     agent_e2e [--cwd=<project>] [--screenshot=<out.png>] -- <command...>
///
/// The command is `flutter_dev run --machine ...` (or a stock `flutter run --machine ...`). Once the
/// app has started, every `ext.rules_flutter.*` command is called with `app.callServiceExtension`,
/// the widget tree is read with `ext.flutter.inspector.getRootWidgetTree`, the plugin of the example
/// answers, and the device takes a screenshot with `device.takeScreenshot` where the device can;
/// then the app is hot restarted and hot reloaded, and everything is checked again. Written for
/// `e2e/stock_dev_loop`, whose home page has the widgets it names. Prints a JSON report on stdout
/// and exits 1 when a check failed.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> argv) async {
  final int sep = argv.indexOf('--');
  if (sep < 0 || sep == argv.length - 1) {
    stderr.writeln(
      'usage: agent_e2e [--cwd=<dir>] [--screenshot=<out.png>] -- <flutter_dev run --machine ...>',
    );
    exitCode = 64;
    return;
  }
  String? cwd;
  String? screenshot;
  for (final String a in argv.sublist(0, sep)) {
    if (a.startsWith('--cwd=')) cwd = a.substring('--cwd='.length);
    if (a.startsWith('--screenshot=')) {
      screenshot = a.substring('--screenshot='.length);
    }
  }
  cwd ??=
      Platform.environment['BUILD_WORKING_DIRECTORY'] ?? Directory.current.path;
  final report = _Report();
  final _App app = await _App.start(argv.sublist(sep + 1), cwd);
  try {
    final started = Stopwatch()..start();
    await app.started.timeout(const Duration(minutes: 10));
    report.timings['app.started'] = started.elapsedMilliseconds;
    await _round(app, report, 'launch', screenshot);
    for (final (String phase, bool full) in <(String, bool)>[
      ('after restart', true),
      ('after reload', false),
    ]) {
      final watch = Stopwatch()..start();
      final Object? r = await app.request('app.restart', <String, Object?>{
        'appId': app.appId,
        'fullRestart': full,
        'reason': 'manual',
      });
      report.timings[full ? 'app.restart' : 'app.restart (reload)'] =
          watch.elapsedMilliseconds;
      report.check(
        phase,
        full ? 'app.restart' : 'hot reload',
        r is Map && r['code'] == 0,
        r,
      );
      await _round(app, report, phase, screenshot);
    }
  } on Object catch (e) {
    report.check('session', 'run', false, '$e');
  } finally {
    await app.stop();
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
  exitCode = report.failed ? 1 : 0;
}

/// Every scripted command, once. The counts are read back rather than assumed, so a round can run
/// at any state of the app.
Future<void> _round(
  _App app,
  _Report report,
  String phase,
  String? screenshot,
) async {
  Future<Map<String, Object?>> ext(
    String name,
    Map<String, String> params,
  ) async {
    final watch = Stopwatch()..start();
    try {
      final Object? r = await app.request(
        'app.callServiceExtension',
        <String, Object?>{
          'appId': app.appId,
          'methodName': name.startsWith('ext.')
              ? name
              : 'ext.rules_flutter.$name',
          'params': params,
        },
      );
      report.timings['$phase $name'] = watch.elapsedMilliseconds;
      return (r as Map<Object?, Object?>?)?.cast<String, Object?>() ??
          const <String, Object?>{};
    } on _RpcError catch (e) {
      return <String, Object?>{'rpcError': e.message};
    }
  }

  void check(String name, bool ok, Object? detail) =>
      report.check(phase, name, ok, detail);

  int? count(Map<String, Object?> r) {
    final Match? m = RegExp(r'^count (\d+)').firstMatch('${r['text']}');
    return m == null ? null : int.parse(m.group(1)!);
  }

  Map<String, Object?> r = await ext('renderState', const <String, String>{});
  check('renderState', r['firstFrameBuilt'] == true, r);
  r = await ext('waitFor', const <String, String>{'key': 'count'});
  check('waitFor', r['rpcError'] == null, r);
  r = await ext('getText', const <String, String>{'key': 'count'});
  final int? before = count(r);
  check('getText', before != null, r);

  r = await ext('tap', const <String, String>{'tooltip': 'Increment'});
  final int? afterTap = count(
    await ext('getText', const <String, String>{'key': 'count'}),
  );
  check(
    'tap',
    before != null && afterTap == before + 1,
    <String, Object?>{'reply': r, 'before': before, 'after': afterTap},
  );
  r = await ext('doubleTap', const <String, String>{'tooltip': 'Increment'});
  final int? afterDouble = count(
    await ext('getText', const <String, String>{'key': 'count'}),
  );
  check(
    'doubleTap',
    afterTap != null && afterDouble != null && afterDouble > afterTap,
    <String, Object?>{'reply': r, 'before': afterTap, 'after': afterDouble},
  );
  r = await ext('longPress', const <String, String>{'tooltip': 'Increment'});
  check('longPress', r['rpcError'] == null, r);

  r = await ext('getRect', const <String, String>{'key': 'name'});
  check('getRect', r['rpcError'] == null && '$r'.contains('width'), r);
  r = await ext('enterText', const <String, String>{
    'key': 'name',
    'text': 'agent',
  });
  final Map<String, Object?> greeting = await ext(
    'getText',
    const <String, String>{'key': 'greeting'},
  );
  check(
    'enterText',
    greeting['text'] == 'hello agent',
    <String, Object?>{'reply': r, 'greeting': greeting},
  );
  r = await ext('pressKey', const <String, String>{
    'code': 'KeyX',
    'text': 'x',
  });
  final Map<String, Object?> typed = await ext(
    'getText',
    const <String, String>{'key': 'greeting'},
  );
  check(
    'pressKey',
    typed['text'] == 'hello agentx',
    <String, Object?>{'reply': r, 'greeting': typed},
  );

  r = await ext('hover', const <String, String>{'key': 'details'});
  check('hover', r['rpcError'] == null, r);
  r = await ext('hoverExit', const <String, String>{});
  check('hoverExit', r['rpcError'] == null, r);
  r = await ext('drag', const <String, String>{
    'key': 'count',
    'dx': '0',
    'dy': '20',
  });
  check('drag', r['rpcError'] == null, r);
  r = await ext('scrollIntoView', const <String, String>{'key': 'details'});
  check('scrollIntoView', r['rpcError'] == null, r);
  r = await ext('setWindowActive', const <String, String>{'active': 'false'});
  final Map<String, Object?> back = await ext(
    'setWindowActive',
    const <String, String>{'active': 'true'},
  );
  check(
    'setWindowActive',
    r['lifecycleState'] == 'inactive' && back['lifecycleState'] == 'resumed',
    <String, Object?>{'inactive': r, 'resumed': back},
  );
  r = await ext('settle', const <String, String>{});
  check('settle', r['settled'] == 'yes', r);

  r = await ext('tap', const <String, String>{'key': 'details'});
  final Map<String, Object?> shown = await ext(
    'waitFor',
    const <String, String>{'key': 'details_page'},
  );
  check('waitFor (pushed page)', shown['rpcError'] == null, shown);
  r = await ext('pageBack', const <String, String>{});
  check('pageBack', r['popped'] == true, r);
  r = await ext('waitForAbsent', const <String, String>{'key': 'details_page'});
  check('waitForAbsent', r['rpcError'] == null, r);

  r = await ext(
    'ext.flutter.inspector.getRootWidgetTree',
    const <String, String>{
      'groupName': 'agent_e2e',
      'isSummaryTree': 'true',
      'withPreviews': 'true',
    },
  );
  final String tree = jsonEncode(r);
  check(
    'widget tree',
    tree.contains('MyHomePage'),
    '${tree.length} characters',
  );
  r = await ext('ext.counter_plugin.mark', const <String, String>{});
  check('plugin answers', r['mark'] is String, r);

  if (app.deviceId case final String device) {
    try {
      final Object? shot = await app.request(
        'device.takeScreenshot',
        <String, Object?>{'deviceId': device},
      );
      // The daemon answers with the PNG itself, base64-encoded.
      final String? data = shot is String ? shot : null;
      final List<int> png = data == null ? const <int>[] : base64Decode(data);
      final bool isPng =
          png.length > 8 && png[0] == 0x89 && png[1] == 0x50 && png[2] == 0x4e;
      if (isPng && screenshot != null) {
        File(
          screenshot.replaceFirst(
            RegExp(r'\.png$'),
            '-${phase.replaceAll(' ', '_')}.png',
          ),
        ).writeAsBytesSync(png);
      }
      check('device.takeScreenshot', isPng, '${png.length} bytes');
    } on _RpcError catch (e) {
      report.unsupported(phase, 'device.takeScreenshot', e.message);
    }
  }
}

class _Report {
  final List<Map<String, Object?>> checks = <Map<String, Object?>>[];
  final List<Map<String, Object?>> unsupportedOn = <Map<String, Object?>>[];
  final Map<String, int> timings = <String, int>{};

  bool get failed => checks.any((Map<String, Object?> c) => c['ok'] != true);

  void check(String phase, String name, bool ok, Object? detail) {
    checks.add(<String, Object?>{
      'phase': phase,
      'command': name,
      'ok': ok,
      if (!ok) 'detail': detail,
    });
    stderr.writeln(
      'agent_e2e: ${ok ? 'ok  ' : 'FAIL'} $phase: $name${ok ? '' : ' $detail'}',
    );
  }

  void unsupported(String phase, String name, String why) {
    unsupportedOn.add(<String, Object?>{
      'phase': phase,
      'command': name,
      'why': why,
    });
    stderr.writeln('agent_e2e: n/a  $phase: $name ($why)');
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'passed': !failed,
    'checks': checks,
    'unsupported': unsupportedOn,
    'timingsMs': timings,
  };
}

class _RpcError implements Exception {
  new(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The `--machine` session of one app.
class _App {
  new _(this._process) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_line, onDone: _done);
    _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String l) => stderr.writeln('  | $l'));
  }

  static Future<_App> start(List<String> command, String cwd) async => _App._(
    await Process.start(
      command.first,
      command.sublist(1),
      workingDirectory: cwd,
      environment: Platform.environment,
      includeParentEnvironment: false,
    ),
  );

  final Process _process;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  final Completer<void> _started = Completer<void>();
  var _id = 0;

  /// The id the stock tool gave the app, from `app.start`.
  String? appId;

  /// The device the app runs on, from `app.start`.
  String? deviceId;

  /// Completes on `app.started`.
  Future<void> get started => _started.future;

  void _line(String line) {
    if (!line.startsWith('[{') || !line.endsWith('}]')) return;
    final List<Object?> messages;
    try {
      messages = jsonDecode(line) as List<Object?>;
    } on FormatException {
      return;
    }
    for (final Map<String, Object?> m
        in messages.cast<Map<String, Object?>>()) {
      final Object? id = m['id'];
      if (id is int && _pending.containsKey(id) && m['event'] == null) {
        final Completer<Object?> c = _pending.remove(id)!;
        if (m.containsKey('error')) {
          c.completeError(_RpcError('${m['error']}'));
        } else {
          c.complete(m['result']);
        }
        continue;
      }
      final Map<String, Object?> params =
          (m['params'] as Map<String, Object?>?) ?? const <String, Object?>{};
      switch (m['event']) {
        case 'app.start':
          appId = params['appId'] as String?;
          deviceId = params['deviceId'] as String?;
        case 'app.started':
          if (!_started.isCompleted) _started.complete();
        case 'app.log':
          final log = '${params['log']}';
          if (log.contains('rdf-')) stderr.writeln('  app: $log');
      }
    }
  }

  void _done() {
    if (!_started.isCompleted) {
      _started.completeError(StateError('the tool exited before app.started'));
    }
    for (final Completer<Object?> c in _pending.values) {
      c.completeError(_RpcError('the tool exited'));
    }
    _pending.clear();
  }

  /// Sends [method] and returns its result; throws an [_RpcError] for an error reply.
  Future<Object?> request(String method, Map<String, Object?> params) {
    final int id = ++_id;
    final Completer<Object?> c = _pending[id] = Completer<Object?>();
    _process.stdin.writeln(
      jsonEncode(<Object?>[
        <String, Object?>{'id': id, 'method': method, 'params': params},
      ]),
    );
    return c.future.timeout(
      const Duration(minutes: 2),
      onTimeout: () => throw _RpcError('$method: no reply in 2 minutes'),
    );
  }

  /// Stops the app and waits for the tool to exit.
  Future<void> stop() async {
    if (appId != null) {
      try {
        await request('app.stop', <String, Object?>{'appId': appId});
      } on Object {
        // Already gone.
      }
    }
    await _process.stdin.close();
    await _process.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _process.kill();
        return -1;
      },
    );
  }
}
