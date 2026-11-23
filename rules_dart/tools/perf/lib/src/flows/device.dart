/// The Android emulator the install and dev-loop flows use, started once
/// with its own AVD, console port and adb server port (never adb's default).
library;

import 'dart:async';
import 'dart:io';

import '../flow.dart';
import '../proc.dart';

/// The emulator, started on first use and stopped by [stopEmulator].
final class Emulator {
  Emulator._(this.serial, this.env, this._process);

  /// `emulator-<port>`.
  final String serial;

  /// The stock environment with the private adb port and the serial.
  final Map<String, String> env;

  final Process? _process;
}

Emulator? _running;

/// The emulator of `--option=avd=`, `emulator_port=` and `adb_port=`,
/// creating the AVD from `system_image=` when it does not exist.
Future<Emulator> emulator(Ctx c) async {
  if (_running != null) return _running!;
  final avd = c.options['avd'];
  final port = c.options['emulator_port'];
  final adbPort = c.options['adb_port'];
  if (avd == null || port == null || adbPort == null) {
    throw const NotAvailable(
      'no emulator: pass --option=avd=, --option=emulator_port= and --option=adb_port=',
    );
  }
  if (adbPort == '5037') {
    throw const NotAvailable('adb\'s default port 5037 is not used');
  }
  final serial = 'emulator-$port';
  final env = {
    ...c.stockEnv,
    'ANDROID_ADB_SERVER_PORT': adbPort,
    'ANDROID_SERIAL': serial,
  };
  final log = c.log('emulator');
  final avdHome = env['ANDROID_AVD_HOME'] ?? '${env['ANDROID_USER_HOME']}/avd';
  if (!Directory('$avdHome/$avd.avd').existsSync()) {
    final image =
        c.options['system_image'] ?? 'system-images;android-35;aosp_atd;x86_64';
    final p = await Process.start('avdmanager', [
      'create',
      'avd',
      '-n',
      avd,
      '-k',
      image,
      '-d',
      'pixel_6',
    ], environment: env);
    p.stdin.writeln('no'); // no custom hardware profile
    await p.stdin.close();
    if (await p.exitCode != 0)
      throw StateError('avdmanager create avd $avd failed');
  }
  final booted = await runCmd(
    Cmd(
      ['adb', '-s', serial, 'shell', 'getprop', 'sys.boot_completed'],
      cwd: c.scratch,
      env: env,
    ),
  );
  Process? proc;
  if (booted.stdout.trim() != '1') {
    proc = await Process.start(
      'emulator',
      [
        '-avd',
        avd,
        '-port',
        port,
        '-no-window',
        '-no-audio',
        '-no-boot-anim',
        '-no-snapshot',
        '-gpu',
        'swiftshader_indirect',
        '-no-metrics',
      ],
      environment: env,
      mode: ProcessStartMode.detachedWithStdio,
    );
    proc.stdout.listen((b) => log.writeAsBytesSync(b, mode: FileMode.append));
    proc.stderr.listen((b) => log.writeAsBytesSync(b, mode: FileMode.append));
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (true) {
      final r = await runCmd(
        Cmd(
          ['adb', '-s', serial, 'shell', 'getprop', 'sys.boot_completed'],
          cwd: c.scratch,
          env: env,
        ),
      );
      if (r.stdout.trim() == '1') break;
      if (DateTime.now().isAfter(deadline))
        throw StateError('$serial did not boot in 5 minutes');
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }
  return _running = Emulator._(serial, env, proc);
}

/// Stops the emulator and its adb server, if this process started them.
Future<void> stopEmulator(Ctx c) async {
  final e = _running;
  if (e == null) return;
  _running = null;
  if (e._process != null) {
    await runCmd(
      Cmd(['adb', '-s', e.serial, 'emu', 'kill'], cwd: c.scratch, env: e.env),
    );
  }
  await runCmd(Cmd(['adb', 'kill-server'], cwd: c.scratch, env: e.env));
}
