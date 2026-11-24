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

/// Runs an adb command that must succeed, and returns what it printed.
Future<String> adbOrThrow(
  String adbBinary,
  String serial,
  List<String> args,
  Map<String, String> env,
) async {
  final result = await runAdbCommand(adbBinary, serial, args, env);
  final output = '${result.stdout}\n${result.stderr}';
  if (result.exitCode != 0) {
    throw StateError(
      'adb ${args.join(' ')} failed (${result.exitCode}): $output',
    );
  }
  return output;
}

/// The SHA-256 of [bytes], in hex (FIPS 180-4; the test has no package for it).
String sha256Hex(List<int> bytes) {
  const k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  const mask = 0xffffffff;
  int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & mask;
  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  final length = bytes.length;
  final padded = <int>[...bytes, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  final bits = length * 8;
  for (var shift = 56; shift >= 0; shift -= 8) {
    padded.add((bits >> shift) & 0xff);
  }
  final w = List<int>.filled(64, 0);
  for (var block = 0; block < padded.length; block += 64) {
    for (var i = 0; i < 16; i++) {
      final at = block + 4 * i;
      w[i] =
          (padded[at] << 24) |
          (padded[at + 1] << 16) |
          (padded[at + 2] << 8) |
          padded[at + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & mask;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ ((~e & mask) & g);
      final t1 = (hh + s1 + ch + k[i] + w[i]) & mask;
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & mask;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & mask;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & mask;
    }
    final next = <int>[a, b, c, d, e, f, g, hh];
    for (var i = 0; i < 8; i++) {
      h[i] = (h[i] + next[i]) & mask;
    }
  }
  return h.map((x) => x.toRadixString(16).padLeft(8, '0')).join();
}

const _package = 'com.example.aarhost';
const _marker = 'FLUTTER_MARKER_RENDERED: AAR_HOST_MARKER_OK';

/// Installs this build's APK on a device that has none, launches the host, and passes only on a
/// signal that the Flutter module of this APK gives: the marker line the module's Dart code prints
/// after its first frame, in the log of the process this launch started, while that process lives.
///
/// Nothing an earlier run left can satisfy it: the package is removed first, the file the device
/// then holds is compared with the APK byte for byte (its SHA-256), the log is cleared (and the
/// clearing checked), and only the lines of the launched process are read.
Future<void> verifyActivityAndMarker(
  String adbBinary,
  String serial,
  Map<String, String> env,
  String apkPath,
) async {
  // 1. No earlier install: removing a package that is not there fails, and that is fine.
  await runAdbCommand(adbBinary, serial, const ['uninstall', _package], env);
  final listed = await adbOrThrow(adbBinary, serial, const [
    'shell',
    'pm',
    'list',
    'packages',
    _package,
  ], env);
  if (listed.contains('package:$_package')) {
    throw StateError('$_package is still installed after uninstall: $listed');
  }

  // 2. This build's APK, and the proof that it is what the device holds.
  final installed = await adbOrThrow(adbBinary, serial, [
    'install',
    apkPath,
  ], env);
  if (!installed.contains('Success')) {
    throw StateError('adb install $apkPath did not say Success: $installed');
  }
  final pmPath = await adbOrThrow(adbBinary, serial, const [
    'shell',
    'pm',
    'path',
    _package,
  ], env);
  final devicePath = pmPath
      .split('\n')
      .map((l) => l.trim())
      .firstWhere((l) => l.startsWith('package:'), orElse: () => '')
      .replaceFirst('package:', '');
  if (devicePath.isEmpty) {
    throw StateError('pm path $_package gave no path: $pmPath');
  }
  final deviceSum = (await adbOrThrow(adbBinary, serial, [
    'shell',
    'sha256sum',
    devicePath,
  ], env)).trim().split(RegExp(r'\s+')).first;
  final localSum = sha256Hex(File(apkPath).readAsBytesSync());
  if (deviceSum != localSum) {
    throw StateError(
      'The APK on the device ($devicePath, sha256 $deviceSum) is not the APK '
      'of this build ($apkPath, sha256 $localSum).',
    );
  }

  // 3. A log without a line from before the launch.
  await adbOrThrow(adbBinary, serial, const [
    'shell',
    'am',
    'force-stop',
    _package,
  ], env);
  await adbOrThrow(adbBinary, serial, const ['logcat', '-b', 'all', '-c'], env);
  final before = await adbOrThrow(adbBinary, serial, const [
    'logcat',
    '-d',
  ], env);
  if (before.contains(_marker)) {
    throw StateError('The log still holds the marker after it was cleared.');
  }

  // 4. The launch.
  final startOutput = await adbOrThrow(adbBinary, serial, const [
    'shell',
    'am',
    'start',
    '-W',
    '-n',
    '$_package/.MainActivity',
  ], env);
  if (startOutput.contains('Error:') ||
      startOutput.contains('Exception') ||
      startOutput.contains('Status: error')) {
    throw StateError('Failed to start MainActivity: $startOutput');
  }

  // 5. The marker, printed by the process that is alive now, which stays alive after it.
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  Future<String> pidOf() async {
    final result = await runAdbCommand(adbBinary, serial, const [
      'shell',
      'pidof',
      _package,
    ], env);
    return result.exitCode == 0 ? '${result.stdout}'.trim() : '';
  }

  var lastPid = '';
  while (DateTime.now().isBefore(deadline)) {
    final pid = await pidOf();
    if (pid.isNotEmpty && !pid.contains(' ')) {
      lastPid = pid;
      final logs = await runAdbCommand(adbBinary, serial, [
        'logcat',
        '-d',
        '--pid=$pid',
      ], env);
      if (logs.exitCode == 0 && '${logs.stdout}'.contains(_marker)) {
        if (await pidOf() == pid) {
          return;
        }
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  final dump = await runAdbCommand(adbBinary, serial, const [
    'logcat',
    '-d',
  ], env);
  throw StateError(
    'The Flutter module did not render: no marker line from the running '
    'process of $_package (last pid: ${lastPid.isEmpty ? 'none' : lastPid}) '
    'within 45 s. Logcat:\n${dump.stdout}',
  );
}

/// A console port and an adb port that nothing listens on, in the range adb scans for emulators.
///
/// A fixed pair would be shared with every other emulator test of the machine: `adb -s
/// emulator-5554` answers for whichever emulator has the port, booted or not by this test.
Future<({int consolePort, int adbPort})> freeEmulatorPorts() async {
  for (var console = 5554; console <= 5680; console += 2) {
    ServerSocket? first;
    ServerSocket? second;
    try {
      first = await ServerSocket.bind(InternetAddress.loopbackIPv4, console);
      second = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        console + 1,
      );
      return (consolePort: console, adbPort: console + 1);
    } on SocketException {
      // In use: the next pair.
    } finally {
      await first?.close();
      await second?.close();
    }
  }
  throw StateError('No free emulator port pair in 5554..5681.');
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

  final ports = await freeEmulatorPorts();
  final consolePort = ports.consolePort;
  final adbPort = ports.adbPort;
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
    // No device may answer for the serial before this test's emulator exists.
    final early = await runAdbCommand(paths.adbBinary, serial, const [
      'get-state',
    ], env);
    if (early.exitCode == 0) {
      throw StateError(
        'A device already answers as $serial (${'${early.stdout}'.trim()}) '
        'before this test started its emulator.',
      );
    }
    emuProc = await Process.start(
      paths.emulatorBinary,
      [
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
    // The device that answered is the emulator this test started: it is still running.
    final exited = await emuProc.exitCode.timeout(
      const Duration(milliseconds: 10),
      onTimeout: () => -999,
    );
    if (exited != -999) {
      throw StateError(
        'The emulator of this test exited ($exited) during the test.',
      );
    }
    // ignore: avoid_print
    print(
      "AAR host e2e test passed: this build's APK installed, the module's marker "
      'printed by the launched process, process alive.',
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
