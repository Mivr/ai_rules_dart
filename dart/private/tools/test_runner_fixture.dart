import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Stands in for a compiled test `main` under `test_runner_test.dart`.
///
/// - `stream`: announces itself on stdout and stderr, then echoes one line of
///   stdin. The driver sends that line only once it has seen both
///   announcements, so the echo proves they arrived while this was running.
/// - `env-probe`: prints its whole environment, one `KEY=VALUE` line per
///   variable, so the driver can check which variables the launcher passed
///   through to the program it started.
/// - `leak <release>`: starts a copy of itself in `linger` mode that shares
///   this process's stdio, then exits without waiting for it.
/// - `linger <release>`: holds that stdio open until `<release>` exists.
/// - `args-probe <arg>...`: prints each argument after the mode on its own
///   `arg:<value>` line, then exits 3 if any of them is a
///   `--test-randomize-ordering-seed=...` option: the launcher must take that
///   option out before a plain `main` sees it.
/// - `suite <arg>...`: only where `:test_runner_suite_fixture` compiles this
///   file as a `package:test` suite, so that the runner calls this with the
///   launcher's arguments. Declares [_suiteCases] cases named `case <n>`, whose
///   order the driver reads from the launcher's JUnit report, and one that
///   writes `suite-args:<json>` of the arguments it was given to stdout and
///   fails if a `--test-randomize-ordering-seed=...` option is among them.
Future<void> main(List<String> args) async {
  switch (args) {
    case ['stream']:
      stdout.writeln('stdout-ready');
      stderr.writeln('stderr-ready');
      final String line = await stdin
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      stdout.writeln('echo:$line');
    case ['leak', final release]:
      await Process.start(Platform.resolvedExecutable, [
        Platform.script.toFilePath(),
        'linger',
        release,
      ], mode: ProcessStartMode.inheritStdio);
      exit(0);
    case ['linger', final release]:
      while (!File(release).existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    case ['read-cwd', final relPath]:
      stdout.writeln(File(relPath).readAsStringSync().trim());
    case ['env-probe']:
      for (final MapEntry<String, String> entry
          in Platform.environment.entries) {
        stdout.writeln('${entry.key}=${entry.value}');
      }
    case ['args-probe', ...final rest]:
      for (final arg in rest) {
        stdout.writeln('arg:$arg');
      }
      if (rest.any(_isSeedOption)) exit(3);
    case ['suite', ...]:
      _declareSuite(args);
    default:
      stderr.writeln(
        'usage: stream | leak <release> | linger <release> | read-cwd <path> '
        '| env-probe | args-probe <arg>... | suite <arg>...',
      );
      exit(2);
  }
}

/// How many ordering cases `suite` declares: enough that a shuffled order is
/// all but never the declared one by chance.
const _suiteCases = 8;

/// Whether [arg] is the seed option meant for `package:test`'s runner.
bool _isSeedOption(String arg) =>
    arg.startsWith('--test-randomize-ordering-seed=');

/// Declares the `suite` mode's cases (see [main]).
void _declareSuite(List<String> args) {
  final seen = <int>{};
  for (var i = 0; i < _suiteCases; i++) {
    test('case $i', () {
      expect(seen.add(i), isTrue);
    });
  }
  test('sees the launcher arguments without the seed', () {
    stdout.writeln('suite-args:${jsonEncode(args)}');
    expect(args.where(_isSeedOption), isEmpty);
  });
}
