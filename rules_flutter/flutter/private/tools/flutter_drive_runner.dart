/// Host-driven test launcher for `flutter_drive_test` (Android emulator, with
/// the iOS simulator leg in `flutter_drive_ios.dart`).
///
/// Boots the pinned headless emulator the way `flutter_integration_test` does,
/// installs and launches the debug APK, finds the app's Dart VM service URI in
/// logcat, forwards it to the host, and runs the driver on the host with that
/// URI in its environment. The test's exit status is the driver's. The
/// emulator, the app and the port forward are cleaned up however the run ends,
/// and a timeout names the step that timed out.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'flutter_drive_common.dart';
import 'flutter_drive_ios.dart';
import 'flutter_integration_test_android.dart';
import 'test_support.dart';

export 'flutter_drive_common.dart';
export 'flutter_drive_ios.dart';

/// Paths to the pinned headless Android `emulator` and `adb` binaries.
typedef AndroidRuntimePaths = ({String emulator, String adb});

/// Parses the `<package>/<activity>` component from `cmd package
/// resolve-activity --brief` [output], falling back to `FlutterActivity` under
/// [packageName] when none is reported.
String parseLauncherComponent(String output, String packageName) {
  for (final String raw in output.split('\n').reversed) {
    final String line = raw.trim();
    if (line.isEmpty || line.contains(' ') || !line.contains('/')) continue;
    return line;
  }
  return '$packageName/io.flutter.embedding.android.FlutterActivity';
}

/// Everything the run reads from the test environment.
class DriveConfig {
  /// Creates a drive configuration.
  const new({
    required this.apk,
    required this.package,
    required this.runtime,
    required this.driver,
    required this.tmp,
    this.kvmPath = '/dev/kvm',
    this.budgetScale = 1.0,
  });

  /// Reads the configuration from the test [env] and runfiles [r].
  factory fromEnv(Map<String, String> env, Runfiles r) {
    String requiredValue(String key) => requiredEnv(env, key);

    final DriverCommand command = driverCommandFromEnv(env, r);
    return DriveConfig(
      apk: r.rlocation(requiredValue('FLUTTER_DRIVE_ANDROID_APK')),
      package: requiredValue('FLUTTER_DRIVE_ANDROID_PACKAGE'),
      runtime: (
        emulator: r.rlocation(requiredValue('FLUTTER_DRIVE_ANDROID_EMULATOR')),
        adb: r.rlocation(requiredValue('FLUTTER_DRIVE_ANDROID_ADB')),
      ),
      driver: command,
      tmp: env['TEST_TMPDIR'] ?? Directory.systemTemp.path,
    );
  }

  /// The debug APK under test.
  final String apk;

  /// Application ID of the APK.
  final String package;

  /// Pinned Android emulator and `adb` binaries.
  final AndroidRuntimePaths runtime;

  /// Host command that runs the driver.
  final DriverCommand driver;

  /// Scratch parent directory.
  final String tmp;

  /// Device node whose read/write access gates the emulator boot.
  final String kvmPath;

  /// Factor applied to every step time budget; `1.0` keeps the real budgets.
  final double budgetScale;

  /// [base] scaled by [budgetScale].
  Duration budget(Duration base) => budgetScale == 1.0
      ? base
      : Duration(microseconds: (base.inMicroseconds * budgetScale).round());
}

/// One emulator session: boot, install, launch, forward and tear down.
class DriveSession {
  /// Creates an emulator session for [config].
  new(this.config);

  /// The run's inputs.
  final DriveConfig config;

  late Map<String, String> _env;
  late String _serial;
  Directory? _scratch;
  Process? _emulator;
  Process? _logcat;
  int? _hostPort;
  bool _disposed = false;

  Future<ProcessResult> _adb(
    List<String> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final Process p = await Process.start(
      config.runtime.adb,
      args,
      environment: _env,
      includeParentEnvironment: false,
    );
    final Future<String> out = p.stdout.transform(utf8.decoder).join();
    final Future<String> err = p.stderr.transform(utf8.decoder).join();
    final int code = await p.exitCode.timeout(
      timeout,
      onTimeout: () {
        p.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    return ProcessResult(p.pid, code, await out, await err);
  }

  Future<ProcessResult> _adbOrThrow(
    List<String> args, {
    Duration? timeout,
  }) async {
    final ProcessResult r = await _adb(
      <String>['-s', _serial, ...args],
      timeout: timeout ?? const Duration(seconds: 30),
    );
    if (r.exitCode != 0) {
      throw StateError(
        'adb ${args.join(' ')} failed (${r.exitCode}):\n'
        '${r.stdout}\n${r.stderr}',
      );
    }
    return r;
  }

  /// Boots the emulator and waits for it to finish booting.
  Future<void> boot() async {
    verifyKvmAvailable(config.kvmPath);
    final String sdkRoot = File(config.runtime.emulator).parent.parent.path;
    final scratch = Directory(
      '${config.tmp}/drive_${pid}_${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    _scratch = scratch;
    final avdHome = Directory('${scratch.path}/.android/avd')
      ..createSync(recursive: true);
    final avdDir = Directory('${avdHome.path}/test.avd')
      ..createSync(recursive: true);
    for (final d in <String>['.config', '.cache', 'xdg-runtime']) {
      Directory('${scratch.path}/$d').createSync(recursive: true);
    }
    File('${avdHome.path}/test.ini')
        .writeAsStringSync(buildAndroidAvdIniContent(avdDir: avdDir.path));
    File('${avdDir.path}/config.ini')
        .writeAsStringSync(buildAndroidAvdConfigContent());
    final ({int adbPort, int adbServerPort, int consolePort}) ports =
        await allocateAndroidEmulatorPorts();
    _env = buildAndroidRuntimeEnvironment(
      sdkRoot: sdkRoot,
      sysrootDir: '${Directory(sdkRoot).parent.path}/sysroot',
      scratchDir: scratch.path,
      avdHomeDir: avdHome.path,
      adbServerPort: ports.adbServerPort,
      forwarding: EnvForwarding(tz: Platform.environment['TZ']),
    );
    _serial = 'emulator-${ports.consolePort}';
    await runStep(
      'start adb server',
      config.budget(const Duration(seconds: 30)),
      () async {
        await _adb(const <String>['start-server']);
      },
    );
    _emulator = await Process.start(
      config.runtime.emulator,
      buildAndroidEmulatorArguments(
        avdName: 'test',
        consolePort: ports.consolePort,
        adbPort: ports.adbPort,
      ),
      workingDirectory: scratch.path,
      environment: _env,
      includeParentEnvironment: false,
    );
    unawaited(_emulator!.stdout.drain<void>());
    unawaited(_emulator!.stderr.drain<void>());
    await runStep(
      'emulator boot',
      config.budget(const Duration(seconds: 180)),
      _waitBooted,
    );
  }

  Future<void> _waitBooted() async {
    while (!_disposed) {
      final ProcessResult r = await _adb(<String>[
        '-s',
        _serial,
        'shell',
        'getprop',
        'sys.boot_completed',
      ]);
      if (r.exitCode == 0 && '${r.stdout}'.trim() == '1') return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<String> _resolveComponent() async {
    final ProcessResult r = await _adb(<String>[
      '-s',
      _serial,
      'shell',
      'cmd',
      'package',
      'resolve-activity',
      '--brief',
      '-c',
      'android.intent.category.LAUNCHER',
      config.package,
    ]);
    final out = r.exitCode == 0 ? '${r.stdout}' : '';
    return parseLauncherComponent(out, config.package);
  }

  /// Installs the APK, launches it and returns the host VM service URI.
  Future<String> launchApp() async {
    await runStep(
      'install apk',
      config.budget(const Duration(seconds: 90)),
      () async {
        await _adbOrThrow(<String>['install', '-r', config.apk]);
      },
    );
    await _adbOrThrow(const <String>['logcat', '-b', 'all', '-c']);
    final Process logcat = await Process.start(
      config.runtime.adb,
      <String>[
        '-s',
        _serial,
        'logcat',
        '-v',
        'raw',
        'flutter:V',
        'DartVM:V',
        '*:S',
      ],
      environment: _env,
      includeParentEnvironment: false,
    );
    _logcat = logcat;
    unawaited(logcat.stderr.drain<void>());
    final Future<({int port, String path})> found = logcat.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map(parseVmServiceLine)
        .where((m) => m != null)
        .map((m) => m!)
        .first;
    final String component = await _resolveComponent();
    await runStep(
      'launch app',
      config.budget(const Duration(seconds: 60)),
      () async {
        final ProcessResult r = await _adbOrThrow(<String>[
          'shell',
          'am',
          'start',
          '-W',
          '-n',
          component,
        ]);
        if ('${r.stdout}'.contains('Error:')) {
          throw StateError('am start $component failed:\n${r.stdout}');
        }
      },
    );
    final ({int port, String path}) svc = await runStep(
      'wait for VM service',
      config.budget(const Duration(seconds: 90)),
      () => found,
    );
    await runStep(
      'forward VM service port',
      config.budget(const Duration(seconds: 30)),
      () {
        return _forward(svc.port);
      },
    );
    return 'http://127.0.0.1:$_hostPort${svc.path}';
  }

  Future<void> _forward(int devicePort) async {
    final ProcessResult r = await _adbOrThrow(<String>[
      'forward',
      'tcp:0',
      'tcp:$devicePort',
    ]);
    final int? assigned = int.tryParse('${r.stdout}'.trim());
    if (assigned != null && assigned > 0) {
      _hostPort = assigned;
      return;
    }
    final ServerSocket s = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int hostPort = s.port;
    await s.close();
    await _adbOrThrow(<String>['forward', 'tcp:$hostPort', 'tcp:$devicePort']);
    _hostPort = hostPort;
  }

  /// Removes the forward, stops the app and the emulator, drops the scratch.
  Future<void> dispose() async {
    _disposed = true;
    final int? hostPort = _hostPort;
    if (hostPort != null) {
      await teardownQuietly(() async {
        await _adb(<String>[
          '-s',
          _serial,
          'forward',
          '--remove',
          'tcp:$hostPort',
        ]);
      });
    }
    if (_emulator != null) {
      await teardownQuietly(() async {
        await _adb(<String>[
          '-s',
          _serial,
          'shell',
          'am',
          'force-stop',
          config.package,
        ]);
      });
    }
    _logcat?.kill(ProcessSignal.sigkill);
    _emulator?.kill(ProcessSignal.sigkill);
    await teardownQuietly(() async {
      await _emulator?.exitCode.timeout(const Duration(seconds: 5));
    });
    await teardownQuietly(() async {
      await _adb(
        const <String>['kill-server'],
        timeout: const Duration(seconds: 3),
      );
    });
    final Directory? dir = _scratch;
    if (dir != null && dir.existsSync()) {
      cleanupQuietly(() => dir.deleteSync(recursive: true));
    }
  }

  /// The serial of the emulator the app runs on.
  String get serial => _serial;

  /// The session scratch directory, or [DriveConfig.tmp] before boot.
  String get scratchPath => _scratch?.path ?? config.tmp;
}

/// Runs the driver on the host against [uri]; returns its exit code.
Future<int> runDriver(DriveConfig config, DriveSession s, String uri) =>
    runDriverProcess(config.driver, s.scratchPath, <String, String>{
      'PATH': File(config.runtime.adb).parent.path,
      vmServiceEnv: uri,
      'FLUTTER_DRIVE_VM_SERVICE_URI': uri,
      'FLUTTER_DRIVE_ANDROID_SERIAL': s.serial,
      'FLUTTER_DRIVE_PACKAGE': config.package,
    });

/// Boots, launches and drives; always cleans up. Returns the exit status.
Future<int> runDrive(DriveConfig config) async {
  final session = DriveSession(config);
  try {
    await session.boot();
    final String uri = await session.launchApp();
    return await runDriver(config, session, uri);
  } on Object catch (e) {
    stderr.writeln('flutter_drive_test: $e');
    return 1;
  } finally {
    await session.dispose();
  }
}

Future<void> main() async {
  final Map<String, String> env = Platform.environment;
  final runfiles = Runfiles.create();
  final bool ios = (env['FLUTTER_DRIVE_IOS_APP'] ?? '').isNotEmpty;
  try {
    exit(
      ios
          ? await runIosDrive(IosDriveConfig.fromEnv(env, runfiles))
          : await runDrive(DriveConfig.fromEnv(env, runfiles)),
    );
  } on FormatException catch (e) {
    stderr.writeln('flutter_drive_test: ${e.message}');
    exit(2);
  }
}
