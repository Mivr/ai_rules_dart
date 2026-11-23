import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/android_splits.dart';
import 'package:flutter_bazel_dev_tool/device_android.dart';
import 'package:flutter_bazel_dev_tool/run_command.dart';
import 'package:test/test.dart';

/// One `adb` invocation the device made.
typedef _Call = List<String>;

void main() {
  late Directory tmp;
  late List<_Call> calls;
  late String base;
  late String payload;
  var adbExit = 0;
  var adbStderr = '';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('split_install_test');
    base = _write(tmp, 'app_base.apk', 'base v1');
    payload = _write(tmp, 'app_payload.apk', 'payload v1');
    calls = [];
    adbExit = 0;
    adbStderr = '';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  AndroidDevice device({String? deviceId}) => AndroidDevice(
    deviceId: deviceId,
    packageName: 'com.example.app',
    adbPath: 'adb',
    runProcess: (exe, args) async {
      calls.add([exe, ...args]);
      return ProcessResult(0, adbExit, '', adbStderr);
    },
  );

  group('installSplits', () {
    test('the first install passes every split to install-multiple', () async {
      await device().installSplits([base, payload]);

      expect(calls, [
        ['adb', 'install-multiple', '-r', base, payload],
      ]);
    });

    test('a payload-only change installs only that split, partially', () async {
      final AndroidDevice d = device();
      await d.installSplits([base, payload]);
      calls.clear();

      _write(tmp, 'app_payload.apk', 'payload v2');
      await d.installSplits([base, payload]);

      expect(calls, [
        ['adb', 'install-multiple', '-r', '-p', 'com.example.app', payload],
      ]);
    });

    test('a changed base installs the whole set again', () async {
      final AndroidDevice d = device();
      await d.installSplits([base, payload]);
      calls.clear();

      _write(tmp, 'app_base.apk', 'base v2');
      await d.installSplits([base, payload]);

      expect(calls, [
        ['adb', 'install-multiple', '-r', base, payload],
      ]);
    });

    test('splits that did not change install nothing', () async {
      final AndroidDevice d = device();
      await d.installSplits([base, payload]);
      calls.clear();

      await d.installSplits([base, payload]);

      expect(calls, isEmpty);
    });

    test('a device id addresses adb with -s', () async {
      await device(deviceId: 'emulator-5554').installSplits([base, payload]);

      expect(calls.single.take(3), ['adb', '-s', 'emulator-5554']);
    });

    test(
      'a nonzero adb exit names the command and the device message',
      () async {
        adbExit = 1;
        adbStderr = 'Failure [INSTALL_FAILED_VERSION_DOWNGRADE]';

        await expectLater(
          device().installSplits([base, payload]),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('install-multiple'),
                contains('INSTALL_FAILED_VERSION_DOWNGRADE'),
              ),
            ),
          ),
        );
        // No other install mode is tried.
        expect(calls, hasLength(1));
        expect(calls.single, contains('install-multiple'));
      },
    );

    test(
      'a failed install is not recorded: the next try sends everything',
      () async {
        final AndroidDevice d = device();
        adbExit = 1;
        await expectLater(d.installSplits([base, payload]), throwsStateError);
        adbExit = 0;
        calls.clear();

        await d.installSplits([base, payload]);

        expect(calls, [
          ['adb', 'install-multiple', '-r', base, payload],
        ]);
      },
    );
  });

  group('split selection', () {
    test('splitApksFrom orders base then payload', () {
      expect(splitApksFrom(['/o/x_payload.apk', '/o/x_base.apk']), [
        '/o/x_base.apk',
        '/o/x_payload.apk',
      ]);
      expect(splitApksFrom(['/o/x.apk']), isNull);
    });

    test('a split run asks bazel for the split output groups', () {
      final d = AndroidDevice()..splitInstall = true;
      expect(d.buildArgs, contains(splitOutputGroupsFlag));
      expect(AndroidDevice().buildArgs, isNot(contains(splitOutputGroupsFlag)));
    });

    test('--single-apk is a run flag that defaults to off', () {
      expect(RunCommand.parser.options['single-apk'], isNotNull);
      expect(RunCommand.parser.parse([])['single-apk'], isFalse);
      expect(RunCommand.parser.parse(['--single-apk'])['single-apk'], isTrue);
    });
  });

  group('sha256Hex', () {
    test('matches the FIPS 180-4 vectors', () async {
      expect(
        await sha256Hex(_write(tmp, 'empty', '')),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        await sha256Hex(_write(tmp, 'abc', 'abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        await sha256Hex(
          _write(
            tmp,
            'two_blocks',
            'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
          ),
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });

    test('hashes a million letters across read chunks', () async {
      final file = File('${tmp.path}/million')
        ..writeAsBytesSync(utf8.encode('a' * 1000000));
      expect(
        await sha256Hex(file.path),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });
  });
}

String _write(Directory dir, String name, String content) {
  final file = File('${dir.path}/$name')..writeAsStringSync(content);
  return file.path;
}
