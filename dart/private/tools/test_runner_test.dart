import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Drives the `dart_test` launcher against `test_runner_fixture.dart`.
///
/// Arguments are the runfiles paths of the launcher, the fixture's kernel,
/// and the SDK `dart` binary. The launcher under test gets its VM through
/// `RULES_DART_DART` holding the binary's runfiles path (this test's own
/// environment no longer carries `RULES_DART_*`: the launcher strips them),
/// and is pointed at the fixture through `RULES_DART_DILL`.
void main(List<String> args) {
  final launcher = Runfiles.create().rlocation(args[0]);

  Future<Process> start(
    List<String> fixtureArgs, {
    Map<String, String> extraEnv = const {},
  }) => Process.start(
    launcher,
    fixtureArgs,
    // This test itself runs under the `package:test` runner; the fixture is a
    // plain `main`, run directly.
    environment: {
      'RULES_DART_DART': args[2],
      'RULES_DART_DILL': args[1],
      'RULES_DART_TEST_RUNNER': '',
      ...extraEnv,
    },
  );

  StreamIterator<String> lines(Stream<List<int>> stream) => StreamIterator(
    stream.transform(utf8.decoder).transform(const LineSplitter()),
  );

  // Bazel kills a test that hangs, so anything it printed is in test.log only
  // if the launcher passed it on as it came.
  test('passes output on while the test is still running', () async {
    final process = await start(['stream']);
    final out = lines(process.stdout);
    final err = lines(process.stderr);
    // A paused pipe left open would keep this test's own VM alive.
    addTearDown(() => Future.wait([out.cancel(), err.cancel()]));

    expect(await out.moveNext() ? out.current : null, 'stdout-ready');
    expect(await err.moveNext() ? err.current : null, 'stderr-ready');

    // Once the fixture has exited, stdin is gone and so is the echo.
    process.stdin.writeln('ping');
    unawaited(process.stdin.close().catchError((_) {}));
    expect(
      await out.moveNext() ? out.current : null,
      'echo:ping',
      reason: 'the launcher withheld output until the test exited',
    );
    expect(await process.exitCode, 0);
  });

  test('exits with the test, not with a process the test leaked', () async {
    final tmp = await Directory.systemTemp.createTemp('test_runner_test_');
    final release = File('${tmp.path}/release');
    final process = await start(['leak', release.path]);
    process.stderr.listen(stderr.add);

    // The lingering copy holds the launcher's stdout; it closes when that
    // copy is gone, which must happen before the directory goes away.
    final stdoutClosed = process.stdout.drain<void>();
    addTearDown(() async {
      release.writeAsStringSync('');
      await stdoutClosed;
      tmp.deleteSync(recursive: true);
    });

    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () => fail('the launcher outlived the test it ran'),
    );
    expect(exitCode, 0);
  });

  // A plain `main` has no cases to select, so a filter must fail loudly
  // rather than run everything and report a filtered pass.
  test('a test without package:test refuses --test_filter', () async {
    final process = await Process.start(
      launcher,
      ['stream'],
      environment: {
        'RULES_DART_DART': args[2],
        'RULES_DART_DILL': args[1],
        'RULES_DART_TEST_RUNNER': '',
        'TESTBRIDGE_TEST_ONLY': 'anything',
      },
    );
    final err = await process.stderr.transform(utf8.decoder).join();
    await process.stdout.drain<void>();
    expect(await process.exitCode, 1);
    expect(
      err,
      contains('--test_filter needs a test written with package:test'),
    );
  });

  test('fails with a clear error when RULES_DART_BASE_DILL cannot be resolved or does not exist', () async {
    final tmp = await Directory.systemTemp.createTemp('test_runner_base_dill_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    const ws = '_main';
    const testPath = 'pkg/my_test.dart';
    final wsDir = Directory('${tmp.path}/$ws/pkg')..createSync(recursive: true);
    File('${wsDir.path}/my_test.dart').writeAsStringSync('void main() {}\n');
    File('${wsDir.path}/my_test.dart.vm_test.vm.app.dill')
        .writeAsBytesSync(const [1, 2, 3, 4]);
    File('${wsDir.path}/runner.dill').writeAsBytesSync(const [5, 6, 7, 8]);

    final process = await Process.start(
      launcher,
      const [],
      environment: {
        'RUNFILES_DIR': tmp.path,
        'RUNFILES_MANIFEST_FILE': '',
        ' TEST_WORKSPACE': ws,
        'TEST_WORKSPACE': ws,
        'RULES_DART_DART': args[2],
        'RULES_DART_DILL': '$ws/pkg/my_test.dart.vm_test.vm.app.dill',
        'RULES_DART_TEST_RUNNER': '$ws/pkg/runner.dill',
        'RULES_DART_TEST_MAIN': '$ws/$testPath',
        'RULES_DART_TEST_PATH': testPath,
        'RULES_DART_BASE_DILL': '$ws/pkg/missing.base.dill',
      },
    );
    final err = await process.stderr.transform(utf8.decoder).join();
    await process.stdout.drain<void>();
    expect(await process.exitCode, 1);
    expect(err, contains('dart_test: base dill not found'));
  });

  test(
    'a suite whose dill is not laid out for its path fails clearly',
    () async {
      final process = await Process.start(
        launcher,
        const [],
        environment: {
          'RULES_DART_DART': args[2],
          'RULES_DART_DILL': args[1],
          'RULES_DART_TEST_RUNNER': args[1],
          'RULES_DART_TEST_MAIN': args[1],
          'RULES_DART_TEST_PATH': 'pkg/my_test.dart',
        },
      );
      final err = await process.stderr.transform(utf8.decoder).join();
      await process.stdout.drain<void>();
      expect(await process.exitCode, 1);
      expect(err, contains('is not laid out for pkg/my_test.dart'));
    },
  );

  test(
    'a plain test sees no RULES_DART_* variable but keeps caller variables',
    () async {
      final process = await start(
        ['env-probe'],
        extraEnv: {
          'RULES_DART_PROBE_LEAK': 'leaked',
          'PROBE_CALLER_VAR': 'caller-ok',
        },
      );
      final out = await process.stdout.transform(utf8.decoder).join();
      await process.stderr.drain<void>();
      expect(await process.exitCode, 0);
      final seen = <String, String>{};
      for (final line in const LineSplitter().convert(out)) {
        final at = line.indexOf('=');
        if (at > 0) seen[line.substring(0, at)] = line.substring(at + 1);
      }
      final leaked = seen.keys
          .where((key) => key.startsWith('RULES_DART_'))
          .toList();
      expect(leaked, isEmpty, reason: 'the launcher leaked $leaked');
      expect(seen['PROBE_CALLER_VAR'], 'caller-ok');
    },
  );

  test('a test without package:test materializes workspace from manifest when not in place', () async {
    final tmp = await Directory.systemTemp.createTemp('test_runner_manifest_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final fixtureDill = Runfiles.create().rlocation(args[1]);
    final emptyCwd = Directory('${tmp.path}/empty_cwd')..createSync();
    final runfilesDir = Directory('${tmp.path}/skeleton.runfiles')
      ..createSync();
    final realData = File('${tmp.path}/real_data.txt')
      ..writeAsStringSync('manifest-data\n');
    File('${runfilesDir.path}/MANIFEST').writeAsStringSync(
      '_main/pkg/data.txt ${realData.path}\n'
      'dart_sdk/bin/dart ${Platform.resolvedExecutable}\n'
      '${args[1]} $fixtureDill\n',
    );

    final process = await Process.start(
      launcher,
      ['read-cwd', 'pkg/data.txt'],
      workingDirectory: emptyCwd.path,
      environment: {
        'RUNFILES_DIR': runfilesDir.path,
        'RUNFILES_MANIFEST_FILE': '',
        'TEST_WORKSPACE': '_main',
        'TEST_TMPDIR': tmp.path,
        'RULES_DART_DART': 'dart_sdk/bin/dart',
        'RULES_DART_DILL': args[1],
        'RULES_DART_TEST_RUNNER': '',
      },
    );
    final out = await process.stdout.transform(utf8.decoder).join();
    final err = await process.stderr.transform(utf8.decoder).join();
    expect(await process.exitCode, 0, reason: err);
    expect(out.trim(), 'manifest-data');
  });
}
