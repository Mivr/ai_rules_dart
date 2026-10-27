import 'dart:io';

import 'package:test/test.dart';

import 'private_home.dart';

// The shared classification table: every row states a `dart` CLI argument
// list and the HOME policy the launcher must apply. A bare CLI, help or
// verbose flags alone and `help` all reach dartdev and write telemetry,
// although the old classification called them file form; `--version` and a
// program file are the only VM forms. Commands keep the caller environment
// and gain the suppression flag.
const _policyTable = <({List<String> args, DartCliPolicy policy})>[
  // Usage forms: dartdev runs, the flag alone is not enough.
  (args: [], policy: DartCliPolicy.privateHome),
  (args: ['--help'], policy: DartCliPolicy.privateHome),
  (args: ['-h'], policy: DartCliPolicy.privateHome),
  (args: ['--verbose'], policy: DartCliPolicy.privateHome),
  (args: ['-v'], policy: DartCliPolicy.privateHome),
  (args: ['--verbose', '--help'], policy: DartCliPolicy.privateHome),
  (args: ['-h', '--verbose'], policy: DartCliPolicy.privateHome),
  (args: ['help'], policy: DartCliPolicy.privateHome),
  (args: ['help', 'pub'], policy: DartCliPolicy.privateHome),
  (args: ['--verbose', 'help', 'pub'], policy: DartCliPolicy.privateHome),
  (
    args: ['--suppress-analytics', '--verbose'],
    policy: DartCliPolicy.privateHome,
  ),
  (args: ['--disable-analytics'], policy: DartCliPolicy.privateHome),
  (args: ['--no-suppress-analytics'], policy: DartCliPolicy.privateHome),
  // A help flag sends even a `--version` argv to dartdev, which writes.
  (args: ['--version', '--help'], policy: DartCliPolicy.privateHome),
  // VM forms: nothing reaches dartdev, arguments pass through unchanged.
  (args: ['--version'], policy: DartCliPolicy.callerHome),
  (args: ['--verbose', '--version'], policy: DartCliPolicy.callerHome),
  (args: ['--version', '--verbose'], policy: DartCliPolicy.callerHome),
  (args: ['program.dart'], policy: DartCliPolicy.callerHome),
  (args: ['--enable-asserts', 'hello.dart'], policy: DartCliPolicy.callerHome),
  (args: ['HELLO.DART'], policy: DartCliPolicy.callerHome),
  (args: ['app.dill'], policy: DartCliPolicy.callerHome),
  (args: ['OUT/APP.DILL'], policy: DartCliPolicy.callerHome),
  (args: ['out/app.snapshot'], policy: DartCliPolicy.callerHome),
  (args: ['out/app.aot'], policy: DartCliPolicy.callerHome),
  (args: ['out/app.jit'], policy: DartCliPolicy.callerHome),
  (args: ['--version', 'hello.dart'], policy: DartCliPolicy.callerHome),
  // Commands: caller environment kept, suppression flag added.
  (args: ['pub', 'get'], policy: DartCliPolicy.suppressAnalytics),
  (args: ['pub', 'token', 'list'], policy: DartCliPolicy.suppressAnalytics),
  (args: ['--verbose', 'pub', 'get'], policy: DartCliPolicy.suppressAnalytics),
  (args: ['-v', 'format', '.'], policy: DartCliPolicy.suppressAnalytics),
  (args: ['run', 'hello.dart'], policy: DartCliPolicy.suppressAnalytics),
  (args: ['analyze'], policy: DartCliPolicy.suppressAnalytics),
  (args: ['fix', '--apply'], policy: DartCliPolicy.suppressAnalytics),
  (
    args: ['--enable-experiment=foo', 'pub', 'token', 'list'],
    policy: DartCliPolicy.suppressAnalytics,
  ),
  (args: ['--version', 'pub', 'get'], policy: DartCliPolicy.suppressAnalytics),
  (args: ['--help', 'pub', 'get'], policy: DartCliPolicy.suppressAnalytics),
  (
    args: ['--enable-analytics', 'pub', 'get'],
    policy: DartCliPolicy.suppressAnalytics,
  ),
  (
    args: ['--disable-analytics', 'pub', 'get'],
    policy: DartCliPolicy.suppressAnalytics,
  ),
  (
    args: ['--no-suppress-analytics', 'pub', 'get'],
    policy: DartCliPolicy.suppressAnalytics,
  ),
  // An argv that already suppresses globally is kept as written.
  (
    args: ['--suppress-analytics', 'pub', 'get'],
    policy: DartCliPolicy.callerHome,
  ),
];

// The exact argv the launcher execs for every command row: the suppression
// flag goes first unless the caller already stated it globally.
const _suppressTable = <({List<String> args, List<String> want})>[
  (args: ['pub', 'get'], want: ['--suppress-analytics', 'pub', 'get']),
  (
    args: ['--verbose', 'pub', 'get'],
    want: ['--suppress-analytics', '--verbose', 'pub', 'get'],
  ),
  (
    args: ['-v', 'format', '.'],
    want: ['--suppress-analytics', '-v', 'format', '.'],
  ),
  (
    args: ['--enable-experiment=foo', 'pub', 'token', 'list'],
    want: [
      '--suppress-analytics',
      '--enable-experiment=foo',
      'pub',
      'token',
      'list',
    ],
  ),
  (
    args: ['--suppress-analytics', 'pub', 'get'],
    want: ['--suppress-analytics', 'pub', 'get'],
  ),
  (
    args: ['--no-suppress-analytics', 'pub', 'get'],
    want: ['--suppress-analytics', '--no-suppress-analytics', 'pub', 'get'],
  ),
  (
    args: ['--enable-analytics', 'pub', 'get'],
    want: ['--suppress-analytics', '--enable-analytics', 'pub', 'get'],
  ),
  // A command's own flag named the same is not a global option.
  (
    args: ['pub', 'get', '--suppress-analytics'],
    want: ['--suppress-analytics', 'pub', 'get', '--suppress-analytics'],
  ),
];

void main() {
  group('private home', _privateHomeTests);
  group('dartCliPolicy', _policyTests);
  group('suppressAnalyticsArgv', _suppressTests);
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

/// Tests for the two private-home helpers.
void _privateHomeTests() {
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
        'XDG_STATE_HOME',
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

  test('removes the private home after an async success', () async {
    late String home;
    final code = await withPrivateHomeAsync('rules_dart_home_test.', (
      env,
    ) async {
      home = env['HOME']!;
      await Future<void>.value();
      return 7;
    });
    expect(code, 7);
    expect(Directory(home).existsSync(), isFalse);
  });

  test('removes the private home after an async failure', () async {
    late String home;
    await expectLater(
      withPrivateHomeAsync('rules_dart_home_test.', (env) async {
        home = env['HOME']!;
        throw StateError('boom');
      }),
      throwsStateError,
    );
    expect(Directory(home).existsSync(), isFalse);
  });
}

/// Tests for the argv classification.
void _policyTests() {
  test('classifies the shared table', () {
    for (final row in _policyTable) {
      expect(dartCliPolicy(row.args), row.policy, reason: '${row.args}');
    }
  });
}

/// Tests for the command-form argv rewrite.
void _suppressTests() {
  test('suppresses the shared table exactly once', () {
    for (final row in _suppressTable) {
      expect(suppressAnalyticsArgv(row.args), row.want, reason: '${row.args}');
    }
  });
}
