/// iOS simulator leg of `flutter_drive_test`.
///
/// Boots (or reuses) a simulator the way `flutter_integration_test` does,
/// installs the debug `.ipa`, launches it and reads the app's Dart VM service
/// URI from the launch console or, started before the launch, the simulator's
/// unified log (whichever announces it first). The simulator shares the host's
/// loopback, so the URI is usable as printed. The driver runs on the host with that URI and
/// the test's exit status is the driver's. The app is terminated and a
/// simulator this run booted is shut down however the run ends; a timeout
/// names the step that timed out.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'flutter_drive_common.dart';
import 'flutter_integration_test_ios.dart';
import 'test_support.dart';

/// Running `simctl launch --console-pty` child process.
class ConsoleProcess {
  /// Wraps output streams, [exitCode] and [kill] of a launched console child.
  const new({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.kill,
  });

  /// Spawns a real OS process with [Process.start].
  static Future<ConsoleProcess> start(
    String executable,
    List<String> args,
  ) async {
    final Process p = await Process.start(executable, args);
    return ConsoleProcess(
      stdout: p.stdout,
      stderr: p.stderr,
      exitCode: p.exitCode,
      kill: () => p.kill(ProcessSignal.sigkill),
    );
  }

  /// Standard output byte stream.
  final Stream<List<int>> stdout;

  /// Standard error byte stream.
  final Stream<List<int>> stderr;

  /// Exit code future of the child process.
  final Future<int> exitCode;

  /// Terminates the console child process.
  final void Function() kill;
}

/// Callback that starts an `xcrun simctl launch --console-pty` child.
typedef ConsoleStarter = Future<ConsoleProcess> Function(
  String executable,
  List<String> args,
);

/// Callback that executes the host driver and returns its exit code.
typedef DriverRunner = Future<int> Function(
  DriverCommand command,
  String scratch,
  Map<String, String> extraEnv,
);

final RegExp _xmlBundleId = RegExp(
  r'<key>\s*CFBundleIdentifier\s*</key>\s*<string>\s*([^<\s]+)\s*</string>',
);

/// Everything the iOS run reads from the test environment.
class IosDriveConfig {
  /// Creates an iOS drive configuration.
  const new({
    required this.app,
    required this.bundleId,
    required this.driver,
    required this.tmp,
  });

  /// Reads the configuration from the test [env] and runfiles [r].
  factory fromEnv(Map<String, String> env, Runfiles r) => IosDriveConfig(
    app: r.rlocation(requiredEnv(env, 'FLUTTER_DRIVE_IOS_APP')),
    bundleId: (env['FLUTTER_DRIVE_IOS_BUNDLE_ID'] ?? '').trim(),
    driver: driverCommandFromEnv(env, r),
    tmp: env['TEST_TMPDIR'] ?? Directory.systemTemp.path,
  );

  /// The simulator `.ipa` (or `.app` directory) under test.
  final String app;

  /// Bundle identifier override; when empty, read from `Info.plist` at launch.
  final String bundleId;

  /// Host command that runs the driver.
  final DriverCommand driver;

  /// Scratch parent directory.
  final String tmp;
}

/// Lines of console and unified-log output kept for timeout diagnostics.
const int _tailLines = 40;

const String _logPredicate =
    'eventMessage contains "Observatory" or '
    'eventMessage contains "Dart VM service"';

/// One simulator session: boot, install, launch and tear down.
class IosDriveSession {
  /// Creates a simulator session for [config].
  new(
    this.config, {
    CommandSpawner? spawner,
    this.consoleStarter = ConsoleProcess.start,
    this.waitVmTimeout = const Duration(seconds: 300),
  }) : spawner = spawner ?? ProcessCommandSpawner();

  /// The run's inputs.
  final IosDriveConfig config;

  /// How `xcrun` children are started.
  final CommandSpawner spawner;

  /// How `simctl launch --console-pty` is started.
  final ConsoleStarter consoleStarter;

  /// Time budget to wait for the Dart VM service line on the launch console.
  final Duration waitVmTimeout;

  String? _udid;
  String? _bundleId;
  bool _bootedHere = false;
  bool _launched = false;
  Directory? _scratch;
  ConsoleProcess? _console;
  ConsoleProcess? _logStream;
  final List<String> _consoleTail = <String>[];
  final List<String> _logTail = <String>[];

  /// The booted simulator's UDID, or an empty string before boot.
  String get udid => _udid ?? '';

  /// Resolved bundle identifier of the launched app.
  String get bundleId => _bundleId ?? config.bundleId;

  /// The session scratch directory, or [IosDriveConfig.tmp] before boot.
  String get scratchPath => _scratch?.path ?? config.tmp;

  Future<void> _simctl(String step, List<String> args, Duration limit) async {
    final CommandResult r;
    try {
      r = await runSimctl(
        spawner,
        <String>['simctl', ...args],
        timeout: limit,
      );
    } on BootFailure catch (e) {
      if (e.reason.contains('timed out')) throw StepTimeout(step, limit);
      throw StateError('$step: ${e.reason}');
    }
    if (r.exitCode != 0) {
      throw StateError(
        'simctl ${args.first} failed (${r.exitCode}): ${r.stderrText.trim()}',
      );
    }
  }

  /// Boots or reuses a simulator, remembering whether this run booted it.
  Future<void> boot() async {
    _scratch = Directory(
      '${config.tmp}/drive_ios_${pid}_${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    final SimulatorChoice choice = await runStep(
      'simulator boot',
      const Duration(seconds: 900),
      () => bootSimulator(
        BootOptions(
          spawner: spawner,
          bootstatusTimeout: const Duration(seconds: 600),
          log: print,
        ),
      ),
    );
    _udid = choice.device.udid;
    _bootedHere = !choice.wasBooted;
  }

  Future<String> _resolveBundleId(String appDir) async {
    if (config.bundleId.isNotEmpty) return config.bundleId;
    final plist = File('$appDir/Info.plist');
    if (!plist.existsSync()) {
      throw StateError('Info.plist missing in "$appDir"; set bundle_id.');
    }
    final String raw = latin1.decode(plist.readAsBytesSync());
    final RegExpMatch? xml = _xmlBundleId.firstMatch(raw);
    if (xml != null) return xml.group(1)!;
    final SpawnedCommand cmd = await spawner.start('/usr/bin/plutil', <String>[
      '-extract',
      'CFBundleIdentifier',
      'raw',
      '-o',
      '-',
      plist.path,
    ]);
    final int code = await cmd.exitCode;
    final String out = (await cmd.stdoutText).trim();
    if (code == 0 && out.isNotEmpty) return out;
    throw StateError(
      'Could not read CFBundleIdentifier from "${plist.path}"; set bundle_id.',
    );
  }

  /// Installs the app, launches it and returns the VM service URI it prints.
  Future<String> launchApp() async {
    final String appDir = _resolveApp();
    final String resolvedBundle = await _resolveBundleId(appDir);
    _bundleId = resolvedBundle;
    await _simctl('install app', <String>[
      'install',
      udid,
      appDir,
    ], const Duration(seconds: 180));
    // The log stream starts before the launch so no announcement is missed.
    _logStream = await consoleStarter('xcrun', _logStreamArgs(udid));
    // SIMCTL_CHILD_* variables reach the launched app; this one makes the
    // engine's os_log output also reach the console.
    final ConsoleProcess console = await consoleStarter(
      '/usr/bin/env',
      <String>[
        'SIMCTL_CHILD_OS_ACTIVITY_DT_MODE=enable',
        'xcrun',
        'simctl',
        'launch',
        '--console-pty',
        '--terminate-running-process',
        udid,
        resolvedBundle,
      ],
    );
    _console = console;
    _launched = true;
    final Future<({int port, String path})> found = _vmServiceLines(
      console,
      _logStream!,
    );
    try {
      final ({int port, String path}) svc = await runStep(
        'wait for VM service',
        waitVmTimeout,
        () => found,
      );
      return 'http://127.0.0.1:${svc.port}${svc.path}';
    } on StepTimeout catch (e) {
      throw StepTimeout(e.step, e.limit, detail: _tailReport());
    } finally {
      _logStream?.kill();
    }
  }

  /// `simctl spawn <udid> log stream` arguments; the predicate is the one
  /// `tools/dev_tool` uses for the same announcement.
  static List<String> _logStreamArgs(String udid) => <String>[
    'simctl',
    'spawn',
    udid,
    'log',
    'stream',
    '--style',
    'compact',
    '--predicate',
    _logPredicate,
  ];

  String _tailReport() =>
      'last ${_consoleTail.length} console lines:\n'
      '${_consoleTail.join('\n')}\n'
      'last ${_logTail.length} unified-log lines:\n${_logTail.join('\n')}';

  /// Completes with the first VM service announcement on the launch console
  /// or the unified log; fails if the console exits first.
  Future<({int port, String path})> _vmServiceLines(
    ConsoleProcess console,
    ConsoleProcess logStream,
  ) {
    final result = Completer<({int port, String path})>();
    void watch(ConsoleProcess p, List<String> tail, {required bool isConsole}) {
      var open = 2;
      final merged = StreamController<List<int>>();
      void done() {
        if (--open == 0) unawaited(merged.close());
      }

      p.stdout.listen(merged.add, onDone: done);
      p.stderr.listen(merged.add, onDone: done);
      unawaited(() async {
        await for (final String line
            in merged.stream
                .transform(const Utf8Decoder(allowMalformed: true))
                .transform(const LineSplitter())) {
          if (tail.length == _tailLines) tail.removeAt(0);
          tail.add(line);
          final ({int port, String path})? parsed = parseVmServiceLine(line);
          if (parsed != null && !result.isCompleted) result.complete(parsed);
        }
        if (!isConsole || result.isCompleted) return;
        final int code = await p.exitCode;
        result.completeError(
          StateError(
            'simctl launch exited ($code) before announcing the Dart VM '
            'service:\n${tail.join('\n')}',
          ),
        );
      }());
    }

    watch(console, _consoleTail, isConsole: true);
    watch(logStream, _logTail, isConsole: false);
    return result.future;
  }

  String _resolveApp() {
    if (Directory(config.app).existsSync()) return config.app;
    if (!File(config.app).existsSync()) {
      throw StateError('iOS simulator app not found at "${config.app}".');
    }
    return extractIpaApp(
      ipaBytes: File(config.app).readAsBytesSync(),
      destDir: Directory('$scratchPath/app')..createSync(recursive: true),
    );
  }

  /// Terminates the app, shuts down a simulator this run booted and drops the
  /// scratch; never throws.
  Future<void> dispose() async {
    _console?.kill();
    _logStream?.kill();
    final String id = udid;
    final String appBundle = bundleId;
    if (id.isNotEmpty && _launched && appBundle.isNotEmpty) {
      await teardownQuietly(
        () => _simctl('terminate app', <String>[
          'terminate',
          id,
          appBundle,
        ], const Duration(seconds: 60)),
      );
    }
    if (id.isNotEmpty && _bootedHere) {
      await teardownQuietly(
        () => _simctl('shut down simulator', <String>[
          'shutdown',
          id,
        ], const Duration(seconds: 120)),
      );
    }
    final Directory? dir = _scratch;
    if (dir != null && dir.existsSync()) {
      cleanupQuietly(() => dir.deleteSync(recursive: true));
    }
  }
}

/// Boots, launches and drives on the simulator; always cleans up. Returns the
/// exit status.
Future<int> runIosDrive(
  IosDriveConfig config, {
  IosDriveSession? session,
  DriverRunner runDriver = runDriverProcess,
}) async {
  final IosDriveSession activeSession = session ?? IosDriveSession(config);
  try {
    await activeSession.boot();
    final String uri = await activeSession.launchApp();
    return await runDriver(
      config.driver,
      activeSession.scratchPath,
      <String, String>{
        'PATH': '/usr/bin:/bin',
        vmServiceEnv: uri,
        'FLUTTER_DRIVE_VM_SERVICE_URI': uri,
        'FLUTTER_DRIVE_IOS_UDID': activeSession.udid,
        'FLUTTER_DRIVE_PACKAGE': activeSession.bundleId,
      },
    );
  } on Object catch (e) {
    stderr.writeln('flutter_drive_test: $e');
    return 1;
  } finally {
    await activeSession.dispose();
  }
}
