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
}
