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

  // The shared classification table: every row states `dart` CLI arguments,
  // whether they are file form, and the exact argv the launcher must exec.
  // Command form behind leading flags (`--verbose pub get`) takes the flag:
  // those rows fail while `isFileExecution` treats any leading `-` as file
  // form (ledger row opus-2026-10-26:L-2).
  const classificationTable =
      <({List<String> args, bool fileForm, List<String> want})>[
        // No args: file form, passes through unchanged.
        (args: [], fileForm: true, want: []),
        // Global flags only: file form, unchanged.
        (args: ['--version'], fileForm: true, want: ['--version']),
        (
          args: ['--verbose', '--version'],
          fileForm: true,
          want: ['--verbose', '--version'],
        ),
        // Program files: file form, unchanged.
        (args: ['program.dart'], fileForm: true, want: ['program.dart']),
        (
          args: ['--enable-asserts', 'hello.dart'],
          fileForm: true,
          want: ['--enable-asserts', 'hello.dart'],
        ),
        (args: ['HELLO.DART'], fileForm: true, want: ['HELLO.DART']),
        (args: ['app.dill'], fileForm: true, want: ['app.dill']),
        (args: ['OUT/APP.DILL'], fileForm: true, want: ['OUT/APP.DILL']),
        (
          args: ['out/app.snapshot'],
          fileForm: true,
          want: ['out/app.snapshot'],
        ),
        (args: ['out/app.aot'], fileForm: true, want: ['out/app.aot']),
        (args: ['out/app.jit'], fileForm: true, want: ['out/app.jit']),
        // Commands: the flag is prepended, nothing else reordered.
        (
          args: ['pub', 'get'],
          fileForm: false,
          want: ['--suppress-analytics', 'pub', 'get'],
        ),
        (
          args: ['pub', 'token', 'list'],
          fileForm: false,
          want: ['--suppress-analytics', 'pub', 'token', 'list'],
        ),
        (
          args: ['--verbose', 'pub', 'get'],
          fileForm: false,
          want: ['--suppress-analytics', '--verbose', 'pub', 'get'],
        ),
        (
          args: ['-v', 'format', '.'],
          fileForm: false,
          want: ['--suppress-analytics', '-v', 'format', '.'],
        ),
        (
          args: ['run', 'hello.dart'],
          fileForm: false,
          want: ['--suppress-analytics', 'run', 'hello.dart'],
        ),
        (
          args: ['analyze'],
          fileForm: false,
          want: ['--suppress-analytics', 'analyze'],
        ),
        (
          args: ['fix', '--apply'],
          fileForm: false,
          want: ['--suppress-analytics', 'fix', '--apply'],
        ),
        (
          args: ['--enable-experiment=foo', 'pub', 'token', 'list'],
          fileForm: false,
          want: [
            '--suppress-analytics',
            '--enable-experiment=foo',
            'pub',
            'token',
            'list',
          ],
        ),
        // An already-held flag passes through, never duplicated.
        (
          args: ['--suppress-analytics', 'pub', 'get'],
          fileForm: false,
          want: ['--suppress-analytics', 'pub', 'get'],
        ),
        (
          args: ['--no-suppress-analytics', 'pub', 'get'],
          fileForm: false,
          want: ['--no-suppress-analytics', 'pub', 'get'],
        ),
      ];

  group('isFileExecution', () {
    test('classifies the shared table', () {
      for (final row in classificationTable) {
        expect(isFileExecution(row.args), row.fileForm, reason: '${row.args}');
      }
    });
  });

  group('suppressAnalyticsArgv', () {
    test('suppresses the shared table exactly once', () {
      for (final row in classificationTable) {
        expect(
          suppressAnalyticsArgv(row.args),
          row.want,
          reason: '${row.args}',
        );
      }
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
