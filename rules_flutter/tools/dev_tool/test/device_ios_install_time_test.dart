import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/device_ios.dart';
import 'package:flutter_bazel_dev_tool/device_ios_sim.dart';
import 'package:flutter_bazel_dev_tool/vm_service_discovery.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'fakes.dart';

/// A clock whose reads step forward by [step] each time, so an install that
/// reads it before and after measures exactly [step].
class _SteppingClock implements VmDiscoveryClock {
  new(this.step);

  final Duration step;
  DateTime _now = DateTime(2026);

  @override
  DateTime now() {
    final DateTime at = _now;
    _now = _now.add(step);
    return at;
  }

  @override
  Future<void> sleep(Duration duration) async {}

  @override
  VmDiscoveryTimer startTimer(Duration duration, void Function() onFire) =>
      throw UnimplementedError();
}

const _deviceJson =
    '{"result":{"devices":[{"identifier":"CD","hardwareProperties":'
    '{"udid":"PHONE"},"deviceProperties":{"name":"P"},'
    '"connectionProperties":{"transportType":"wired","pairingState":"paired",'
    '"localHostnames":["p.local"]}}]}}';

List<String> _installLines(List<LogRecord> records) => [
  for (final r in records)
    if (r.message.startsWith('iOS install')) r.message,
];

void main() {
  late List<LogRecord> records;
  late StreamSubscription<LogRecord> sub;

  setUp(() {
    hierarchicalLoggingEnabled = true;
    records = [];
    sub = Logger.root.onRecord.listen(records.add);
  });
  tearDown(() => sub.cancel());

  IOSSimulatorDevice sim({required int installExit}) => IOSSimulatorDevice(
    udid: 'SIM',
    bundleId: 'com.example.test',
    runProcess: (exe, args) async {
      if (args.contains('install')) {
        return ProcessResult(0, installExit, '', 'INSTALL_FAILED');
      }
      return ProcessResult(0, 0, '', '');
    },
    startProcess: (exe, args) async => FakeProcess(),
  )..clock = _SteppingClock(const Duration(milliseconds: 4200));

  IOSDevice phone({required int installExit}) => IOSDevice(
    udid: 'PHONE',
    runProcess: (exe, args) async {
      if (args.contains('--json-output')) {
        final String out = args[args.indexOf('--json-output') + 1];
        if (args.contains('install')) {
          if (installExit == 0) {
            File(out).writeAsStringSync(
              '{"result":{"installedApplications":'
              '[{"installationURL":"file:///x/"}]}}',
            );
          }
          return ProcessResult(0, installExit, '', 'INSTALL_FAILED');
        }
        File(out).writeAsStringSync(_deviceJson);
      }
      return ProcessResult(0, 0, '', '');
    },
    startProcess: (exe, args) async => FakeProcess(),
  )..clock = _SteppingClock(const Duration(milliseconds: 4200));

  test('simulator launch logs one install time line', () async {
    final IOSSimulatorDevice device = sim(installExit: 0);
    // Launch may fail after the install; only the install line matters.
    await device
        .launch('/path/MyApp.app')
        .then<void>((_) {}, onError: (Object _) {})
        .timeout(const Duration(seconds: 2), onTimeout: () {});
    expect(_installLines(records), ['iOS install (simulator): 4.2s']);
  });

  test('device install logs one install time line', () async {
    final IOSDevice device = phone(installExit: 0);
    // Launch may fail after the install; only the install line matters.
    await device
        .launch('/path/MyApp.app')
        .then<void>((_) {}, onError: (Object _) {})
        .timeout(const Duration(seconds: 2), onTimeout: () {});
    expect(_installLines(records), ['iOS install (device): 4.2s']);
  });

  test('failing simctl install throws and logs no time', () async {
    await expectLater(
      sim(installExit: 1).launch('/path/MyApp.app'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('simctl install failed: INSTALL_FAILED'),
        ),
      ),
    );
    expect(_installLines(records), isEmpty);
  });

  test('failing devicectl install throws and logs no time', () async {
    await expectLater(
      phone(installExit: 1).launch('/path/MyApp.app'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('devicectl install failed: INSTALL_FAILED'),
        ),
      ),
    );
    expect(_installLines(records), isEmpty);
  });
}
