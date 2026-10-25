import 'dart:io';

import 'package:test/test.dart';

import 'private_home.dart';

void main() {
  test('points every home variable at the fresh directory', () {
    withPrivateHome('rules_dart_home_test.', (env) {
      for (final key in [
        'HOME',
        'USERPROFILE',
        'LOCALAPPDATA',
        'APPDATA',
        'XDG_CONFIG_HOME',
        'XDG_CACHE_HOME',
        'XDG_DATA_HOME',
      ]) {
        expect(env[key], isNotEmpty, reason: key);
        expect(env[key], env['HOME'], reason: key);
      }
      expect(Directory(env['HOME']!).existsSync(), isTrue);
    });
  });

  test('removes the private home on success', () {
    late String home;
    final code = withPrivateHome('rules_dart_home_test.', (env) {
      home = env['HOME']!;
      return 7;
    });
    expect(code, 7);
    expect(Directory(home).existsSync(), isFalse);
  });

  test('removes the private home on failure', () {
    late String home;
    expect(
      () => withPrivateHome('rules_dart_home_test.', (env) {
        home = env['HOME']!;
        throw StateError('boom');
      }),
      throwsStateError,
    );
    expect(Directory(home).existsSync(), isFalse);
  });

  group('isFileExecution', () {
    test('treats program paths as file-form', () {
      for (final args in [
        ['program.dart'],
        ['out/app.dill'],
        ['out/app.snapshot'],
        ['out/app.aot'],
        ['out/app.jit'],
        ['OUT/APP.DILL'],
      ]) {
        expect(isFileExecution(args), isTrue, reason: '$args');
      }
    });

    test('treats empty and flag-only invocations as file-form', () {
      expect(isFileExecution([]), isTrue);
      expect(isFileExecution(['--version']), isTrue);
      expect(isFileExecution(['--verbose', '--version']), isTrue);
    });

    test('treats commands as command-form', () {
      for (final args in [
        ['pub', 'token', 'list'],
        ['format', '.'],
        ['analyze'],
        ['fix', '--apply'],
        ['run', 'program.dart'],
      ]) {
        expect(isFileExecution(args), isFalse, reason: '$args');
      }
    });
  });

  group('suppressAnalyticsArgv', () {
    test('places the flag before the command', () {
      expect(suppressAnalyticsArgv(['pub', 'token', 'list']), [
        '--suppress-analytics',
        'pub',
        'token',
        'list',
      ]);
    });

    test('leaves file-form executions unchanged', () {
      for (final args in [
        <String>[],
        ['--version'],
        ['program.dart'],
        ['out/app.dill'],
      ]) {
        expect(suppressAnalyticsArgv(args), args, reason: '$args');
      }
    });

    test('does not duplicate an explicit analytics flag', () {
      expect(suppressAnalyticsArgv(['--suppress-analytics', 'pub', 'get']), [
        '--suppress-analytics',
        'pub',
        'get',
      ]);
      expect(suppressAnalyticsArgv(['--no-suppress-analytics', 'pub', 'get']), [
        '--no-suppress-analytics',
        'pub',
        'get',
      ]);
    });
  });

  test('withoutRulesDartControls strips only the ruleset controls', () {
    expect(
      withoutRulesDartControls({
        'HOME': '/home/caller',
        'PUB_CACHE': '/some/pub-cache',
        'RULES_DART_DILL': 'parent.dill',
        'RULES_DART_KERNEL_CONFIG': 'parent.json',
      }),
      {'HOME': '/home/caller', 'PUB_CACHE': '/some/pub-cache'},
    );
  });
}
