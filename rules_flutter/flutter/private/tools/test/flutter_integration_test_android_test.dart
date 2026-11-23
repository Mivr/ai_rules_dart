@Tags(['runfiles'])
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import '../flutter_integration_test_android.dart' as android;

void main() {
  group('Android emulator, AVD & KVM helpers', () {
    test('builds hermetic Android runtime environment and emulator flags', () {
      final Map<String, String> env = android.buildAndroidRuntimeEnvironment(
        sdkRoot: '/runfiles/flutter_android_headless_runtime/sdk',
        sysrootDir: '/runfiles/flutter_android_headless_runtime/sysroot',
        scratchDir: '/tmp/android_scratch',
        avdHomeDir: '/tmp/android_scratch/.android/avd',
        adbServerPort: 15037,
      );
      expect(
        env['PATH'],
        '/runfiles/flutter_android_headless_runtime/sdk/platform-tools:'
        '/runfiles/flutter_android_headless_runtime/sdk/emulator',
      );
      expect(
        env['LD_LIBRARY_PATH'],
        '/runfiles/flutter_android_headless_runtime/sdk/emulator/lib64:'
        '/runfiles/flutter_android_headless_runtime/sdk/emulator/lib64/gles_swiftshader:'
        '/runfiles/flutter_android_headless_runtime/sysroot/usr/lib/x86_64-linux-gnu:'
        '/runfiles/flutter_android_headless_runtime/sysroot/lib/x86_64-linux-gnu',
      );
      expect(
        env['ANDROID_SDK_ROOT'],
        '/runfiles/flutter_android_headless_runtime/sdk',
      );
      expect(env['ANDROID_ADB_SERVER_PORT'], '15037');

      final List<String> args = android.buildAndroidEmulatorArguments(
        avdName: 'test',
        consolePort: 5554,
        adbPort: 5555,
      );
      expect(args, containsAllInOrder(['-avd', 'test']));
      expect(args, contains('-no-window'));
      expect(args, contains('-no-audio'));
      expect(args, contains('-no-snapshot'));
      expect(args, contains('-wipe-data'));
      expect(args, containsAllInOrder(['-gpu', 'swiftshader_indirect']));
      expect(args, containsAllInOrder(['-accel', 'on']));
      expect(args, containsAllInOrder(['-ports', '5554,5555']));

      final String avdIni = android.buildAndroidAvdIniContent(
        avdDir: '/tmp/android_scratch/.android/avd/test.avd',
      );
      expect(
        avdIni,
        contains('path=/tmp/android_scratch/.android/avd/test.avd'),
      );
      expect(avdIni, contains('target=android-35'));

      final String avdConfig = android.buildAndroidAvdConfigContent();
      expect(avdConfig, contains('abi.type=x86_64'));
      expect(avdConfig, contains('hw.gpu.mode=swiftshader_indirect'));
      expect(
        avdConfig,
        contains('image.sysdir.1=system-images/android-35/aosp_atd/x86_64/'),
      );
    });

    test('verifyKvmAvailable fails clearly when KVM device is missing', () {
      expect(
        () => android.verifyKvmAvailable(
          '/tmp/non_existent_kvm_device_${DateTime.now().microsecondsSinceEpoch}',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('KVM device not found'),
              contains('/dev/kvm'),
            ),
          ),
        ),
      );
    });

    test('verifyKvmAvailable succeeds on a readable and writable file', () {
      final Directory tmpDir = Directory.systemTemp.createTempSync(
        'kvm_check_test_',
      );
      try {
        final fakeKvm = File('${tmpDir.path}/kvm')..writeAsStringSync('');
        android.verifyKvmAvailable(fakeKvm.path);
      } finally {
        if (tmpDir.existsSync()) {
          tmpDir.deleteSync(recursive: true);
        }
      }
    });

    test(
      'allocateAndroidEmulatorPorts returns valid even/odd port pair',
      () async {
        final ({int adbPort, int adbServerPort, int consolePort}) ports =
            await android.allocateAndroidEmulatorPorts();
        expect(ports.adbServerPort, greaterThan(0));
        expect(ports.consolePort, inInclusiveRange(5554, 5680));
        expect(ports.consolePort.isEven, isTrue);
        expect(ports.adbPort, ports.consolePort + 1);
      },
    );
  });
  group('discovery diagnostics', () {
    const tmp = '/host/work/tmp';
    const android.DiscoveryPorts ports = (
      console: 5554,
      adb: 5555,
      server: 41999,
      log: ['[emu-out] control console listening on port 5554, ADB on 5555'],
    );
    const android.ProcFacts alive = (
      alive: 'yes',
      pidNs: 'pid:[4026531836]',
      netNs: 'net:[4026531992]',
    );
    const unknown = 'unavailable: process id unknown';
    const android.ProcFacts unknownProc = (
      alive: unknown,
      pidNs: unknown,
      netNs: unknown,
    );

    String build({
      String devices = 'List of devices attached',
      String dir = '$tmp/s/xdg-runtime/avd:\n  running 0B 755',
      android.DiscoveryPorts p = ports,
      android.ProcFacts adb = alive,
      android.ProcFacts emulator = alive,
    }) => android.buildDiscoveryDiagnostics((
      tmp: tmp,
      ports: p,
      devices: devices,
      dir: dir,
      adb: adb,
      emulator: emulator,
    ));

    test('prints every labelled item from full data', () {
      final String block = build();
      expect(block, contains('adb devices -l'));
      expect(block, contains('List of devices attached'));
      expect(block, contains('emulator console 5554'));
      expect(block, contains('emulator adb 5555'));
      expect(block, contains('adb server 41999'));
      expect(block, contains('control console listening on port 5554'));
      expect(block, contains(r'$TEST_TMPDIR/s/xdg-runtime/avd'));
      expect(block, contains('adb server process: alive: yes'));
      expect(block, contains('emulator process: alive: yes'));
      expect(block, contains('pid namespace: pid:[4026531836]'));
      expect(block, contains('net namespace: net:[4026531992]'));
      expect(block, isNot(contains('unavailable')));
    });

    test('prints unavailable with a reason for every missing field', () {
      final String block = build(
        devices: 'unavailable: adb not runnable',
        dir: 'unavailable: permission denied',
        p: (console: 5554, adb: 5555, server: 41999, log: const []),
        adb: unknownProc,
        emulator: unknownProc,
      );
      expect(block, contains('unavailable: adb not runnable'));
      expect(block, contains('unavailable: permission denied'));
      expect(block, contains('(none)'));
      expect(RegExp(unknown).allMatches(block), hasLength(6));
    });

    test('redacts host paths, users and tokens but keeps TEST_TMPDIR', () {
      final String block = build(
        devices: 'error at /home/alice/.android/adbkey auth_token=abc123',
        p: (
          console: 5554,
          adb: 5555,
          server: 41999,
          log: ['port file /home/alice/runfiles/emulator and $tmp/x/y'],
        ),
      );
      expect(block, isNot(contains('alice')));
      expect(block, isNot(contains('/home')));
      expect(block, isNot(contains('abc123')));
      expect(block, isNot(contains('/host/work')));
      expect(block, contains(r'$TEST_TMPDIR/x/y'));
    });

    test('a timeout error message keeps the original and adds the block', () {
      final String block = build();
      final Object out = android.decorateDiscoveryFailure(
        TimeoutException('Timed out after 120s', const Duration(seconds: 120)),
        block,
      );
      final error = out as TimeoutException;
      expect(error.message, startsWith('Timed out after 120s'));
      expect(error.message, contains(block));
      expect(error.duration, const Duration(seconds: 120));
    });

    test('device not found after start is a discovery failure', () {
      final notFound = StateError("adb: device 'emulator-5554' not found");
      expect(android.isDiscoveryFailure(notFound, 'emulator-5554'), isTrue);
      expect(android.isDiscoveryFailure(notFound, 'emulator-5556'), isFalse);
      expect(
        android.isDiscoveryFailure(StateError('other'), 'emulator-5554'),
        isFalse,
      );
      final Object out = android.decorateDiscoveryFailure(notFound, 'BLOCK');
      expect(out, isA<StateError>());
      expect((out as StateError).message, contains('BLOCK'));
    });

    test('collecting never throws and reports unavailable inputs', () async {
      final Directory scratch = Directory.systemTemp.createTempSync(
        'diag_collect_',
      );
      try {
        final String block = await android.collectDiscoveryDiagnostics((
          adb: '${scratch.path}/no_such_adb',
          env: {'HOME': scratch.path},
          tmp: scratch.path,
          ports: ports,
          emuPid: 2147483646,
        ));
        expect(block, contains('adb devices -l'));
        expect(block, contains('unavailable'));
        expect(block, contains('directory does not exist'));
        expect(block, contains('emulator process: alive: no'));
        expect(block, isNot(contains(scratch.path)));
      } finally {
        scratch.deleteSync(recursive: true);
      }
    });
  });
}
