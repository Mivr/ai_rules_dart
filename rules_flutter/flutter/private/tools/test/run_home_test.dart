// Tagged `runfiles`: this test imports `package:runfiles` to read the shell
// counterpart handed to it through the `RUN_HOME_BZL` runfiles path, supplied
// via the `@rules_dart//dart/runfiles` dep its `dart_test` declares. A bare
// `dart test` resolves only this package's pubspec, where that import does
// not exist, so the file fails to load rather than failing a test.
// Coverage comes from //flutter/private/tools:run_home_test.
@Tags(['runfiles'])
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import '../run_home.dart' as run_home;

typedef _Row = ({
  List<String> args,
  run_home.RunHomePolicy policy,
  List<String> want,
});

// The shell counterpart (`RUN_HOME_SH` / `RUN_HOME_SUPPRESS_ANALYTICS` in
// `//flutter/private:run_home.bzl`) is handed to this test as a runfiles
// path via the `RUN_HOME_BZL` env var, so the agreement checks below fail
// the moment the two copies drift apart.
String _runHomeBzl() {
  final String? rel = Platform.environment['RUN_HOME_BZL'];
  if (rel == null || rel.isEmpty) {
    fail('RUN_HOME_BZL is not set; run this through `bazel test`.');
  }
  return File(Runfiles.create().rlocation(rel)).readAsStringSync();
}

// The shared classification table (FF-herm-bare-telemetry): every row states
// the `dart` CLI arguments, the home policy the launcher must apply, and the
// exact argv the launcher must exec. The Dart unit test and the bash launcher
// test below run this same table, and the Windows `.bat` in
// `//flutter/private:flutter_sdk_binary.bzl` mirrors it, so the three launchers
// agree.
const _private = run_home.RunHomePolicy.privateHome;
const _caller = run_home.RunHomePolicy.callerHomeSuppressed;

const _classificationTable =
    <
      ({
        List<String> args,
        run_home.RunHomePolicy policy,
        List<String> want,
      })
    >[
      // No positional argument: dartdev runs its front end. The suppression flag
      // covers some of these shapes but not `--verbose`, so the launcher uses a
      // private home and leaves the arguments unchanged.
      (args: [], policy: _private, want: []),
      (args: ['--help'], policy: _private, want: ['--help']),
      (args: ['-h'], policy: _private, want: ['-h']),
      (args: ['--verbose'], policy: _private, want: ['--verbose']),
      (args: ['-v'], policy: _private, want: ['-v']),
      (
        args: ['--help', '--verbose'],
        policy: _private,
        want: ['--help', '--verbose'],
      ),
      (
        args: ['--verbose', '--help'],
        policy: _private,
        want: ['--verbose', '--help'],
      ),
      (args: ['--version'], policy: _private, want: ['--version']),
      // The reported hole: the flag alone still lets `--verbose` write telemetry.
      (
        args: ['--suppress-analytics', '--verbose'],
        policy: _private,
        want: ['--suppress-analytics', '--verbose'],
      ),
      (
        args: ['--suppress-analytics'],
        policy: _private,
        want: ['--suppress-analytics'],
      ),
      // Program files: private home, arguments unchanged (the VM rejects the
      // analytics flag for a program file with exit 255).
      (args: ['hello.dart'], policy: _private, want: ['hello.dart']),
      (
        args: ['--enable-asserts', 'hello.dart'],
        policy: _private,
        want: ['--enable-asserts', 'hello.dart'],
      ),
      (args: ['HELLO.DART'], policy: _private, want: ['HELLO.DART']),
      (args: ['app.dill'], policy: _private, want: ['app.dill']),
      (args: ['APP.SNAPSHOT'], policy: _private, want: ['APP.SNAPSHOT']),
      (args: ['app.aot'], policy: _private, want: ['app.aot']),
      (args: ['app.jit'], policy: _private, want: ['app.jit']),
      // Commands: caller home, flag prepended, nothing else reordered.
      (
        args: ['help'],
        policy: _caller,
        want: ['--suppress-analytics', 'help'],
      ),
      (
        args: ['help', 'pub'],
        policy: _caller,
        want: ['--suppress-analytics', 'help', 'pub'],
      ),
      (
        args: ['pub', 'get'],
        policy: _caller,
        want: ['--suppress-analytics', 'pub', 'get'],
      ),
      (
        args: ['--verbose', 'pub', 'get'],
        policy: _caller,
        want: ['--suppress-analytics', '--verbose', 'pub', 'get'],
      ),
      (
        args: ['-v', 'format', '.'],
        policy: _caller,
        want: ['--suppress-analytics', '-v', 'format', '.'],
      ),
      (
        args: ['run', 'hello.dart'],
        policy: _caller,
        want: ['--suppress-analytics', 'run', 'hello.dart'],
      ),
      // An already-held leading flag passes through, never duplicated.
      (
        args: ['--suppress-analytics', 'pub', 'get'],
        policy: _caller,
        want: ['--suppress-analytics', 'pub', 'get'],
      ),
      // An explicit opt-out asks for analytics, so the run uses a private home
      // and the caller's directories stay clean.
      (
        args: ['--no-suppress-analytics', 'pub', 'get'],
        policy: _private,
        want: ['--no-suppress-analytics', 'pub', 'get'],
      ),
      (
        args: ['--no-suppress-analytics'],
        policy: _private,
        want: ['--no-suppress-analytics'],
      ),
    ];

// The `RUN_HOME_SH` snippet, extracted from the `.bzl` source so the bash
// test below executes the shipped text, not a copy.
String _runHomeSnippet() {
  final String bzl = _runHomeBzl();
  const marker = 'RUN_HOME_SH = """\\\n';
  final int start = bzl.indexOf(marker);
  if (start < 0) fail('RUN_HOME_SH block not found in run_home.bzl.');
  final int end = bzl.indexOf('"""', start + marker.length);
  if (end < 0) fail('RUN_HOME_SH block is unterminated in run_home.bzl.');
  return bzl.substring(start + marker.length, end);
}

Future<bool> _bashAvailable() async {
  try {
    return (await Process.run('bash', ['--version'])).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Runs the shipped `RUN_HOME_SH` snippet over [args] through a stub `dart`
/// that records the argv it was execed with and the `HOME` it saw. Returns
/// both, so the caller can assert the argv and whether the run used the
/// caller home or a private one.
Future<({List<String> argv, String home})> _bashRun(
  Directory scratch,
  String snippet,
  List<String> args,
  String callerHome,
) async {
  final stub = File('${scratch.path}/stub.sh');
  await stub.writeAsString(
    '#!/usr/bin/env bash\n'
    'echo stub-ran > "\$STUB_RAN"\n'
    'printf \'%s\\n\' "\$HOME" > "\$STUB_HOME"\n'
    'if (( \$# > 0 )); then printf \'%s\\n\' "\$@" > "\$STUB_OUT";'
    ' else : > "\$STUB_OUT"; fi\n',
  );
  final driver = File('${scratch.path}/driver.sh');
  await driver.writeAsString(
    '$snippet\nrun_home_exec "\$STUB" "\$@"\n',
  );
  final out = File('${scratch.path}/out.txt');
  final ran = File('${scratch.path}/ran.txt');
  final home = File('${scratch.path}/home.txt');
  expect((await Process.run('chmod', ['+x', stub.path])).exitCode, 0);
  final ProcessResult result = await Process.run(
    'bash',
    [driver.path, ...args],
    environment: {
      'STUB': stub.path,
      'STUB_OUT': out.path,
      'STUB_RAN': ran.path,
      'STUB_HOME': home.path,
      'HOME': callerHome,
      'TMPDIR': scratch.path,
    },
  );
  expect(result.exitCode, 0, reason: 'bash driver failed: ${result.stderr}');
  expect(ran.existsSync(), isTrue, reason: 'the stub was never execed');
  return (argv: out.readAsLinesSync(), home: home.readAsStringSync().trim());
}

void main() {
  group('privateHomeEnv', () {
    test('covers every home-locating key at the given dir', () {
      final Map<String, String> env = run_home.privateHomeEnv('/priv');
      expect(env.keys.toSet(), run_home.homeEnvKeys.toSet());
      expect(env.values.toSet(), {'/priv'});
    });

    test('covers the POSIX and Windows keys', () {
      expect(
        run_home.homeEnvKeys.toSet(),
        {
          'HOME',
          'USERPROFILE',
          'LOCALAPPDATA',
          'APPDATA',
          'XDG_CONFIG_HOME',
          'XDG_CACHE_HOME',
          'XDG_DATA_HOME',
        },
      );
    });
  });

  group('isFileForm', () {
    test('is a program file only, never an empty or command argv', () {
      expect(run_home.isFileForm(['hello.dart']), isTrue);
      expect(run_home.isFileForm(['--enable-asserts', 'hello.dart']), isTrue);
      expect(run_home.isFileForm(['HELLO.DART']), isTrue);
      expect(run_home.isFileForm([]), isFalse);
      expect(run_home.isFileForm(['--help']), isFalse);
      expect(run_home.isFileForm(['--verbose']), isFalse);
      expect(run_home.isFileForm(['help']), isFalse);
      expect(run_home.isFileForm(['pub', 'get']), isFalse);
      expect(run_home.isFileForm(['run', 'hello.dart']), isFalse);
    });
  });

  group('runHomePolicy', () {
    test('matches the shared table', () {
      for (final _Row row in _classificationTable) {
        expect(
          run_home.runHomePolicy(row.args),
          row.policy,
          reason: 'policy for args ${row.args}',
        );
      }
    });
  });

  group('withSuppressedAnalytics', () {
    test('inserts the flag before the command', () {
      expect(
        run_home.withSuppressedAnalytics(['pub', 'token', 'list']),
        ['--suppress-analytics', 'pub', 'token', 'list'],
      );
    });

    test('never duplicates an already-present flag', () {
      expect(
        run_home.withSuppressedAnalytics(['--suppress-analytics', 'pub']),
        ['--suppress-analytics', 'pub'],
      );
      expect(
        run_home.withSuppressedAnalytics(['--no-suppress-analytics', 'pub']),
        ['--no-suppress-analytics', 'pub'],
      );
    });

    test('an empty argument list is not file form and passes through', () {
      expect(run_home.withSuppressedAnalytics([]), isEmpty);
    });

    test('command form takes the flag, private-home form passes through', () {
      for (final _Row row in _classificationTable) {
        expect(
          run_home.withSuppressedAnalytics(row.args),
          row.want,
          reason: 'args ${row.args}',
        );
      }
    });

    test(
      'the bash launcher classifies the shared table the same way',
      () async {
        if (!await _bashAvailable()) {
          markTestSkipped('bash is not on PATH; the .bat covers Windows.');
        }
        final String snippet = _runHomeSnippet();
        final Directory scratch = Directory.systemTemp.createTempSync(
          'run-home-bash-',
        );
        try {
          final caller = Directory('${scratch.path}/caller')..createSync();
          final marker = File('${caller.path}/marker')
            ..writeAsStringSync('caller home');
          for (final _Row row in _classificationTable) {
            final ({List<String> argv, String home}) got = await _bashRun(
              scratch,
              snippet,
              row.args,
              caller.path,
            );
            expect(got.argv, row.want, reason: 'bash args ${row.args}');
            if (row.policy == run_home.RunHomePolicy.privateHome) {
              expect(
                got.home,
                isNot(caller.path),
                reason: 'private args ${row.args} kept the caller home',
              );
              expect(
                Directory(got.home).existsSync(),
                isFalse,
                reason: 'private args ${row.args} left their home behind',
              );
            } else {
              expect(
                got.home,
                caller.path,
                reason: 'command args ${row.args} lost the caller home',
              );
            }
          }
          expect(
            caller.listSync().map((entry) => entry.path),
            [marker.path],
            reason: 'the launcher wrote under the caller home',
          );
        } finally {
          scratch.deleteSync(recursive: true);
        }
      },
    );
  });

  group('createPrivateHome', () {
    test('makes a fresh dir the caller removes', () {
      final Directory dir = run_home.createPrivateHome(
        Directory.systemTemp.path,
      );
      try {
        expect(dir.existsSync(), isTrue);
      } finally {
        dir.deleteSync(recursive: true);
      }
      expect(dir.existsSync(), isFalse);
    });
  });

  group('shell counterpart agreement', () {
    test('the flag value is pinned', () {
      expect(run_home.suppressAnalyticsFlag, '--suppress-analytics');
    });

    test('run_home.bzl defines the same flag', () {
      expect(
        _runHomeBzl(),
        contains(
          'RUN_HOME_SUPPRESS_ANALYTICS = "${run_home.suppressAnalyticsFlag}"',
        ),
      );
    });

    test('the RUN_HOME_SH snippet passes the same flag', () {
      final String bzl = _runHomeBzl();
      final String snippet = bzl.substring(bzl.indexOf('run_home_exec()'));
      // Both the already-present check and the insertion site spell the
      // flag literally, so a const-only change fails here until the
      // snippet follows.
      expect(snippet, contains('"${run_home.suppressAnalyticsFlag}"'));
      expect(snippet, contains('exec '));
    });

    test('the RUN_HOME_SH snippet classifies like the Dart table', () {
      final String snippet = _runHomeSnippet();
      // The leading check covers both flags, leading dash-arguments are
      // skipped, and the program suffixes match the Dart table.
      expect(snippet, contains('"${run_home.noSuppressAnalyticsFlag}"'));
      expect(snippet, contains('== -*'));
      expect(snippet, contains('run_home_private_exec'));
      for (final String suffix in run_home.programFileSuffixes) {
        expect(snippet, contains(suffix));
      }
    });
  });
}
