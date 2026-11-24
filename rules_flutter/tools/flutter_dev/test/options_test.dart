import 'package:flutter_dev/src/options.dart';
import 'package:test/test.dart';

void main() {
  test('own flags are taken wherever they stand, the rest goes to the stock tool in order', () {
    final o = Options.parse(<String>[
      'run',
      '--machine',
      '--bazel-target=//:app',
      '-d',
      'emulator-5584',
      '--bazel-arg=--config=x',
      '--bazel-arg=--jobs=2',
      '--bazel=/opt/bazel',
      '--target',
      'lib/main.dart',
    ]);
    expect(o.command, 'run');
    expect(o.commandArgs, <String>[
      '--machine',
      '-d',
      'emulator-5584',
      '--target',
      'lib/main.dart',
    ]);
    expect(o.target, '//:app');
    expect(o.bazel, '/opt/bazel');
    expect(o.bazelArgs, <String>['--config=x', '--jobs=2']);
    expect(o.machine, isTrue);
    expect(o.deviceId, 'emulator-5584');
    expect(o.ownFlags, <String>[
      '--bazel=/opt/bazel',
      '--bazel-target=//:app',
      '--bazel-arg=--config=x',
      '--bazel-arg=--jobs=2',
    ]);
  });

  test('global flags before the command stay before it', () {
    final o = Options.parse(<String>[
      '-v',
      '--suppress-analytics',
      'attach',
      '--debug-url=http://x',
    ]);
    expect(o.command, 'attach');
    expect(o.globalArgs, <String>['-v', '--suppress-analytics']);
    expect(o.commandArgs, <String>['--debug-url=http://x']);
  });

  test('device ids in each spelling, and the web devices', () {
    for (final args in <List<String>>[
      <String>['run', '-d', 'chrome'],
      <String>['run', '-dchrome'],
      <String>['run', '--device-id=chrome'],
      <String>['run', '--device-id', 'chrome'],
    ]) {
      final o = Options.parse(args);
      expect(o.deviceId, 'chrome', reason: '$args');
      expect(o.web, isTrue, reason: '$args');
    }
    expect(Options.parse(<String>['run', '-d', 'linux']).web, isFalse);
    expect(Options.parse(<String>['run']).deviceId, isNull);
  });

  test('build mode and switches', () {
    expect(Options.parse(<String>['run']).mode, Mode.debug);
    expect(Options.parse(<String>['run', '--profile']).mode, Mode.profile);
    expect(Options.parse(<String>['run', '--release']).mode, Mode.release);
    final o = Options.parse(<String>[
      'run',
      '--no-hot',
      '--bazel-no-restart',
      '--bazel-allow-version-mismatch',
      '--pid-file=/p',
    ]);
    expect(o.noHot, isTrue);
    expect(o.autoRestart, isFalse);
    expect(o.allowVersionMismatch, isTrue);
    expect(o.hasOption('--pid-file'), isTrue);
    expect(o.hasOption('--pub'), isFalse);
  });

  test(
    'an unknown own flag, or one without its value, is an error that says so',
    () {
      expect(
        () => Options.parse(<String>['run', '--bazel-frobnicate']),
        throwsA(
          isA<UsageException>().having(
            (UsageException e) => e.message,
            'message',
            contains('--bazel-frobnicate'),
          ),
        ),
      );
      expect(
        () => Options.parse(<String>['run', '--bazel-target']),
        throwsA(
          isA<UsageException>().having(
            (UsageException e) => e.message,
            'message',
            contains('needs a value'),
          ),
        ),
      );
    },
  );
}
