import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Paths to dependencies resolved via runfiles.
class AarHostTestPaths {
  /// Creates an [AarHostTestPaths] bundle.
  const AarHostTestPaths({
    required this.apkPath,
    required this.emulatorBinary,
    required this.adbBinary,
    required this.sdkRoot,
    required this.sysrootDir,
  });

  /// Path to the host application APK.
  final String apkPath;

  /// Path to the hermetic Android emulator executable.
  final String emulatorBinary;

  /// Path to the hermetic adb executable.
  final String adbBinary;

  /// Path to the Android SDK root directory.
  final String sdkRoot;

  /// Path to the sysroot containing runtime shared libraries.
  final String sysrootDir;
}

/// Verifies that hardware virtualization (/dev/kvm) is available.
void checkKvm(String kvmPath) {
  final file = File(kvmPath);
  if (!file.existsSync()) {
    throw StateError(
      'KVM acceleration required at "$kvmPath" for Android emulator.',
    );
  }
}

/// Resolves required runfiles paths.
AarHostTestPaths resolvePaths(Runfiles runfiles) {
  final apkRlocs = (Platform.environment['HOST_APK_RLOCATIONS'] ?? '')
      .split(' ')
      .where((s) => s.isNotEmpty)
      .toList();
  final apkRloc = apkRlocs.firstWhere(
    (p) => p.endsWith('.apk') && !p.endsWith('_unsigned.apk'),
    orElse: () => apkRlocs.isNotEmpty ? apkRlocs.first : '',
  );
  final emuRloc = Platform.environment['EMULATOR_RLOCATION'] ?? '';
  final adbRloc = Platform.environment['ADB_RLOCATION'] ?? '';

  String locate(String rloc) {
    if (rloc.isEmpty) {
      throw StateError('Missing required runfile environment variable.');
    }
    var resolved = runfiles.rlocation(rloc);
    if (!File(resolved).existsSync() && rloc.startsWith('_main/')) {
      resolved = runfiles.rlocation(
        'rules_flutter_aar_host/${rloc.substring(6)}',
      );
    }
    if (!File(resolved).existsSync()) {
      throw StateError('Runfile not found: $rloc -> $resolved');
    }
    return resolved;
  }

  final apk = locate(apkRloc);
  final emu = locate(emuRloc);
  final adb = locate(adbRloc);
  final sdkRoot = File(emu).parent.parent.path;
  final sysroot = '${Directory(sdkRoot).parent.path}/sysroot';

  return AarHostTestPaths(
    apkPath: apk,
    emulatorBinary: emu,
    adbBinary: adb,
    sdkRoot: sdkRoot,
    sysrootDir: sysroot,
  );
}

/// Creates temporary scratch directory and initializes headless AVD configuration.
({Directory scratchDir, Directory avdDir}) createAvdScratch(String basePath) {
  final scratch = Directory(
    '$basePath/aar_host_${pid}_${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  final avdParent = Directory('${scratch.path}/.android/avd')
    ..createSync(recursive: true);
  final avdDir = Directory('${avdParent.path}/test.avd')
    ..createSync(recursive: true);

  File('${avdParent.path}/test.ini').writeAsStringSync(
    'avd.ini.encoding=UTF-8\npath=${avdDir.path}\npath.rel=avd/test.avd\ntarget=android-35\n',
  );
  File('${avdDir.path}/config.ini').writeAsStringSync(
    'AvdId=test\n'
    'PlayStore.enabled=false\n'
    'abi.type=x86_64\n'
    'avd.ini.displayname=test\n'
    'avd.ini.encoding=UTF-8\n'
    'disk.dataPartition.size=4096M\n'
    'fastboot.forceColdBoot=yes\n'
    'hw.accelerometer=yes\n'
    'hw.arc=false\n'
    'hw.audioInput=no\n'
    'hw.audioOutput=no\n'
    'hw.battery=yes\n'
    'hw.camera.back=none\n'
    'hw.camera.front=none\n'
    'hw.cpu.arch=x86_64\n'
    'hw.cpu.ncore=4\n'
    'hw.dPad=no\n'
    'hw.gps=no\n'
    'hw.gpu.enabled=yes\n'
    'hw.gpu.mode=swiftshader_indirect\n'
    'hw.initialOrientation=Portrait\n'
    'hw.keyboard=yes\n'
    'hw.lcd.density=160\n'
    'hw.lcd.height=800\n'
    'hw.lcd.width=480\n'
    'hw.mainKeys=no\n'
    'hw.ramSize=2048\n'
    'hw.sdCard=no\n'
    'hw.sensors.orientation=yes\n'
    'hw.sensors.proximity=yes\n'
    'hw.trackBall=no\n'
    'image.sysdir.1=system-images/android-35/aosp_atd/x86_64/\n'
    'runtime.network.latency=none\n'
    'runtime.network.speed=full\n'
    'showDeviceFrame=no\n'
    'tag.display=AOSP ATD\n'
    'tag.id=aosp_atd\n'
    'vm.heapSize=256\n',
  );
  return (scratchDir: scratch, avdDir: avdDir);
}

/// Builds the runtime environment variables for emulator and adb.
Map<String, String> buildEmulatorEnv(
  AarHostTestPaths paths,
  String scratchPath,
  int adbPort,
) {
  final libDirs = <String>[
    '${paths.sdkRoot}/emulator/lib64',
    '${paths.sdkRoot}/emulator/lib64/gles_swiftshader',
    '${paths.sysrootDir}/usr/lib/x86_64-linux-gnu',
    '${paths.sysrootDir}/lib/x86_64-linux-gnu',
  ];
  return <String, String>{
    'PATH': '${paths.sdkRoot}/platform-tools:${paths.sdkRoot}/emulator',
    'LD_LIBRARY_PATH': libDirs.join(':'),
    'HOME': scratchPath,
    'TMPDIR': scratchPath,
    'USER': 'android',
    'ANDROID_SDK_ROOT': paths.sdkRoot,
    'ANDROID_HOME': paths.sdkRoot,
    'ANDROID_AVD_HOME': '$scratchPath/.android/avd',
    'ANDROID_EMULATOR_HOME': '$scratchPath/.android',
    'ANDROID_USER_HOME': '$scratchPath/.android',
    'ANDROID_ADB_SERVER_PORT': '$adbPort',
    'ADB_VENDOR_KEYS': '$scratchPath/.android',
    'XDG_CONFIG_HOME': '$scratchPath/.config',
    'XDG_CACHE_HOME': '$scratchPath/.cache',
  };
}

/// Executes an adb command with target device serial.
Future<ProcessResult> runAdbCommand(
  String adbBinary,
  String serial,
  List<String> args,
  Map<String, String> env,
) async {
  final fullArgs = <String>['-s', serial, ...args];
  return Process.run(
    adbBinary,
    fullArgs,
    environment: env,
    includeParentEnvironment: false,
  );
}

/// Waits for `sys.boot_completed` property to become `1`.
Future<void> waitForBoot(
  String adbBinary,
  String serial,
  Map<String, String> env,
  Process emuProc,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 120));
  var booted = false;
  while (DateTime.now().isBefore(deadline)) {
    final exit = await emuProc.exitCode.timeout(
      const Duration(milliseconds: 10),
      onTimeout: () => -999,
    );
    if (exit != -999) {
      throw StateError('Emulator died prematurely during boot with exit $exit');
    }
    final result = await runAdbCommand(adbBinary, serial, const [
      'shell',
      'getprop',
      'sys.boot_completed',
    ], env);
    if (result.exitCode == 0 && '${result.stdout}'.trim() == '1') {
      booted = true;
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  if (!booted) {
    throw TimeoutException('Timed out waiting for emulator boot on $serial');
  }
}

/// Installs the APK, launches MainActivity, and asserts FlutterActivity and marker.
Future<void> verifyActivityAndMarker(
  String adbBinary,
  String serial,
  Map<String, String> env,
  String apkPath,
) async {
  final installResult = await runAdbCommand(adbBinary, serial, [
    'install',
    '-r',
    apkPath,
  ], env);
  if (installResult.exitCode != 0) {
    throw StateError(
      'Failed to install APK $apkPath: ${installResult.stdout}\n${installResult.stderr}',
    );
  }

  await runAdbCommand(adbBinary, serial, const ['logcat', '-c'], env);

  final startResult = await runAdbCommand(
    adbBinary,
    serial,
    const [
      'shell',
      'am',
      'start',
      '-W',
      '-n',
      'com.example.aarhost/.MainActivity',
    ],
    env,
  );
  final startOutput = '${startResult.stdout}\n${startResult.stderr}';
  if (startResult.exitCode != 0 ||
      startOutput.contains('Error:') ||
      startOutput.contains('Exception') ||
      startOutput.contains('Status: error')) {
    throw StateError('Failed to start FlutterActivity: $startOutput');
  }

  final deadline = DateTime.now().add(const Duration(seconds: 45));
  var markerFound = false;
  var processAlive = false;

  while (DateTime.now().isBefore(deadline)) {
    final pidResult = await runAdbCommand(
      adbBinary,
      serial,
      const ['shell', 'pidof', 'com.example.aarhost'],
      env,
    );
    final pidStr = '${pidResult.stdout}'.trim();
    if (pidResult.exitCode == 0 && pidStr.isNotEmpty) {
      processAlive = true;
    }

    final logcatResult = await runAdbCommand(
      adbBinary,
      serial,
      const ['logcat', '-d'],
      env,
    );
    final logs = '${logcatResult.stdout}';
    if (logs.contains('FLUTTER_MARKER_RENDERED: AAR_HOST_MARKER_OK')) {
      markerFound = true;
    }

    if (processAlive && markerFound) {
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  if (!processAlive) {
    throw StateError('Host app process com.example.aarhost is not alive');
  }
  if (!markerFound) {
    final dump = await runAdbCommand(adbBinary, serial, const [
      'logcat',
      '-d',
    ], env);
    throw StateError(
      'Flutter marker not rendered within timeout. Logcat dump:\n${dump.stdout}',
    );
  }
}

Future<void> main() async {
  checkKvm('/dev/kvm');

  final runfiles = Runfiles.create();
  final paths = resolvePaths(runfiles);

  final baseTmp =
      Platform.environment['TEST_TMPDIR'] ?? Directory.systemTemp.path;
  final scratch = createAvdScratch(baseTmp);

  final adbServerSock = await ServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  final adbServerPort = adbServerSock.port;
  await adbServerSock.close();

  const consolePort = 5554;
  const adbPort = 5555;
  final serial = 'emulator-$consolePort';

  final env = buildEmulatorEnv(paths, scratch.scratchDir.path, adbServerPort);

  final startAdb = await Process.run(
    paths.adbBinary,
    const ['start-server'],
    environment: env,
    includeParentEnvironment: false,
  );
  if (startAdb.exitCode != 0) {
    throw StateError('Failed to start adb server: ${startAdb.stderr}');
  }

  Process? emuProc;
  try {
    emuProc = await Process.start(
      paths.emulatorBinary,
      const [
        '-avd',
        'test',
        '-no-window',
        '-no-audio',
        '-no-boot-anim',
        '-no-snapshot',
        '-no-snapshot-save',
        '-no-snapshot-load',
        '-wipe-data',
        '-gpu',
        'swiftshader_indirect',
        '-accel',
        'on',
        '-ports',
        '$consolePort,$adbPort',
        '-no-metrics',
      ],
      workingDirectory: scratch.scratchDir.path,
      environment: env,
      includeParentEnvironment: false,
    );

    await waitForBoot(paths.adbBinary, serial, env, emuProc);
    await verifyActivityAndMarker(paths.adbBinary, serial, env, paths.apkPath);
    // ignore: avoid_print
    print(
      'AAR host e2e test passed: FlutterActivity launched, marker rendered, process alive.',
    );
  } finally {
    try {
      await runAdbCommand(paths.adbBinary, serial, const ['emu', 'kill'], env);
    } catch (_) {
      // Ignore cleanup error if emulator already terminated.
    }
    emuProc?.kill(ProcessSignal.sigkill);
    try {
      await Process.run(
        paths.adbBinary,
        const ['kill-server'],
        environment: env,
        includeParentEnvironment: false,
      );
    } catch (_) {
      // Ignore cleanup error for adb server shutdown.
    }
    try {
      scratch.scratchDir.deleteSync(recursive: true);
    } catch (_) {
      // Ignore scratch directory cleanup error.
    }
  }
}
