import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'test_runner.dart' show suiteCommand;
import 'test_runner_packages.dart';

/// Drives the `dart_test` launcher against `test_runner_fixture.dart`.
///
/// Arguments are the runfiles paths of the launcher, the fixture's kernel,
/// and the SDK `dart` binary. The launcher under test gets its VM through
/// `RULES_DART_DART` holding the binary's runfiles path (this test's own
/// environment no longer carries `RULES_DART_*`: the launcher strips them),
/// and is pointed at the fixture through `RULES_DART_DILL`.
///
/// The arguments after those are for the runner path (see [_seedTests]): the
/// fixture compiled as a `package:test` suite, the runner built from the same
/// `package:test`, and the fixture's source. The last is this package's
/// `BUILD.bazel` (see [_shardingTests]).
void main(List<String> args) {
  final String launcher = Runfiles.create().rlocation(args[0]);
  _seedTests(launcher, args);
  _shardingTests(args[6]);
  _plainSelectionTests(launcher, args);
  _tagArgvTests();
  _packageConfigTests();

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

  // Bazel kills a test that hangs, so anything it printed is in test.log only
  // if the launcher passed it on as it came.
  test('passes output on while the test is still running', () async {
    final Process process = await start(['stream']);
    final StreamIterator<String> out = _lines(process.stdout);
    final StreamIterator<String> err = _lines(process.stderr);
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
    final Directory tmp = await Directory.systemTemp.createTemp(
      'test_runner_test_',
    );
    final release = File('${tmp.path}/release');
    final Process process = await start(['leak', release.path]);
    process.stderr.listen(stderr.add);

    // The lingering copy holds the launcher's stdout; it closes when that
    // copy is gone, which must happen before the directory goes away.
    final Future<void> stdoutClosed = process.stdout.drain<void>();
    addTearDown(() async {
      release.writeAsStringSync('');
      await stdoutClosed;
      tmp.deleteSync(recursive: true);
    });

    final int exitCode = await process.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () => fail('the launcher outlived the test it ran'),
    );
    expect(exitCode, 0);
  });

  test('fails with a clear error when RULES_DART_BASE_DILL cannot be resolved or does not exist', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'test_runner_base_dill_',
    );
    addTearDown(() => tmp.deleteSync(recursive: true));

    const ws = '_main';
    const testPath = 'pkg/my_test.dart';
    final wsDir = Directory('${tmp.path}/$ws/pkg')..createSync(recursive: true);
    File('${wsDir.path}/my_test.dart').writeAsStringSync('void main() {}\n');
    File('${wsDir.path}/my_test.dart.vm_test.vm.app.dill')
        .writeAsBytesSync(const [1, 2, 3, 4]);
    File('${wsDir.path}/runner.dill').writeAsBytesSync(const [5, 6, 7, 8]);

    final Process process = await Process.start(
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
    final String err = await process.stderr.transform(utf8.decoder).join();
    await process.stdout.drain<void>();
    expect(await process.exitCode, 1);
    expect(err, contains('dart_test: base dill not found'));
  });

  test(
    'a suite whose dill is not laid out for its path fails clearly',
    () async {
      final Process process = await Process.start(
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
      final String err = await process.stderr.transform(utf8.decoder).join();
      await process.stdout.drain<void>();
      expect(await process.exitCode, 1);
      expect(err, contains('is not laid out for pkg/my_test.dart'));
    },
  );

  test(
    'a plain test sees no RULES_DART_* variable but keeps caller variables',
    () async {
      final Process process = await start(
        ['env-probe'],
        extraEnv: {
          'RULES_DART_PROBE_LEAK': 'leaked',
          'PROBE_CALLER_VAR': 'caller-ok',
        },
      );
      final String out = await process.stdout.transform(utf8.decoder).join();
      await process.stderr.drain<void>();
      expect(await process.exitCode, 0);
      final seen = <String, String>{};
      for (final String line in const LineSplitter().convert(out)) {
        final int at = line.indexOf('=');
        if (at > 0) seen[line.substring(0, at)] = line.substring(at + 1);
      }
      final List<String> leaked = seen.keys
          .where((key) => key.startsWith('RULES_DART_'))
          .toList();
      expect(leaked, isEmpty, reason: 'the launcher leaked $leaked');
      expect(seen['PROBE_CALLER_VAR'], 'caller-ok');
    },
  );

  test('a test without package:test materializes workspace from manifest when not in place', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'test_runner_manifest_',
    );
    addTearDown(() => tmp.deleteSync(recursive: true));

    final String fixtureDill = Runfiles.create().rlocation(args[1]);
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

    final Process process = await Process.start(
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
    final String out = await process.stdout.transform(utf8.decoder).join();
    final String err = await process.stderr.transform(utf8.decoder).join();
    expect(await process.exitCode, 0, reason: err);
    expect(out.trim(), 'manifest-data');
  });
}

/// Reads [stream] line by line.
StreamIterator<String> _lines(Stream<List<int>> stream) => StreamIterator(
  stream.transform(utf8.decoder).transform(const LineSplitter()),
);

/// Bazel's ordering-seed option, as `bazel test --test_arg=...` hands it to
/// the launcher.
const _seedFlag = '--test-randomize-ordering-seed=';

/// The line `package:test`'s runner prints for the seed it shuffled with
/// (with a carriage return before the newline where the host writes one).
final RegExp _shufflingLine = RegExp(
  r'^Shuffling test order with --test-randomize-ordering-seed=(\d+)\r?$',
  multiLine: true,
);

/// One of the suite fixture's ordering cases in the launcher's JUnit report.
final RegExp _orderingCase = RegExp(r'<testcase name="(case \d+)"');

/// A launcher run that has finished: its exit code and everything it wrote.
typedef _Run = ({int exitCode, String stdout, String stderr});

/// A run of the suite fixture under the runner: the launcher run, and the
/// JUnit report the launcher wrote for it.
typedef _SuiteRun = ({_Run run, String report});

/// Runs the launcher with [launchArgs] to the end, over this test's
/// environment with [environment] on top.
Future<_Run> _launch(
  String launcher,
  List<String> launchArgs,
  Map<String, String> environment,
) async {
  final Process process = await Process.start(
    launcher,
    launchArgs,
    environment: environment,
  );
  final Future<String> out = process.stdout.transform(utf8.decoder).join();
  final Future<String> err = process.stderr.transform(utf8.decoder).join();
  return (
    exitCode: await process.exitCode,
    stdout: await out,
    stderr: await err,
  );
}

/// Every seed the runner said it shuffled with, in the order it said so.
List<String> _reportedSeeds(String output) => [
  for (final RegExpMatch match in _shufflingLine.allMatches(output))
    match.group(1)!,
];

/// The suite fixture's ordering cases, in the order the JUnit [report] lists
/// them, which is the order they finished in.
List<String> _ranOrder(String report) => [
  for (final RegExpMatch match in _orderingCase.allMatches(report))
    match.group(1)!,
];

/// The values after [prefix] on the lines of [output] that start with it.
List<String> _tagged(String output, String prefix) => [
  for (final String line in const LineSplitter().convert(output))
    if (line.startsWith(prefix)) line.substring(prefix.length),
];

/// The tests for Bazel's `--test-randomize-ordering-seed`, on both of the
/// launcher's paths.
void _seedTests(String launcher, List<String> args) {
  _runnerSeedTests(launcher, args);
  _plainSeedTest(launcher, args);
}

/// The seed tests on the launcher's runner path.
///
/// They run the fixture's `suite` mode, compiled as a `package:test` suite,
/// under the runner built from the same `package:test` (`args[3]` and
/// `args[4]`), the way `dart_test` runs a test that depends on
/// `package:test`; `args[5]` is the fixture's source, which the runner reads.
void _runnerSeedTests(String launcher, List<String> args) {
  // The runner loads the suite from `<dir>/<test path>.vm_test.vm.app.dill`,
  // where `dart_test_kernel` declared it.
  const precompiled = '.precompiled/';
  const suffix = '.vm_test.vm.app.dill';
  final String suiteDill = args[3];
  final String testPath = suiteDill.substring(
    suiteDill.indexOf(precompiled) + precompiled.length,
    suiteDill.length - suffix.length,
  );

  Future<_SuiteRun> runSuite(List<String> launchArgs) async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'test_runner_seed_',
    );
    addTearDown(() => tmp.deleteSync(recursive: true));
    // The suite's JUnit report goes here, not over this test's own.
    final report = File('${tmp.path}/test.xml');
    final _Run run = await _launch(launcher, launchArgs, {
      'RULES_DART_DART': args[2],
      'RULES_DART_DILL': suiteDill,
      'RULES_DART_TEST_RUNNER': args[4],
      'RULES_DART_TEST_MAIN': args[5],
      'RULES_DART_TEST_PATH': testPath,
      'XML_OUTPUT_FILE': report.path,
    });
    return (
      run: run,
      report: report.existsSync() ? report.readAsStringSync() : '',
    );
  }

  /// Checks that [suite] passed, after its seed was checked.
  void expectPassed(_SuiteRun suite) => expect(
    suite.run.exitCode,
    0,
    reason: '${suite.run.stdout}\n${suite.run.stderr}',
  );

  test(
    'a package:test suite gets an integer seed once, and its main never',
    () async {
      final _SuiteRun suite = await runSuite([
        'suite',
        'first',
        '${_seedFlag}9',
        'second',
        '${_seedFlag}20261103',
      ]);
      // The later seed wins, as a later flag does on a command line.
      expect(_reportedSeeds(suite.run.stdout), [
        '20261103',
      ], reason: suite.run.stdout);
      expectPassed(suite);
      final List<String> suiteArgs = _tagged(suite.run.stdout, 'suite-args:');
      expect(suiteArgs, hasLength(1), reason: suite.run.stdout);
      expect(jsonDecode(suiteArgs.single), ['suite', 'first', 'second']);
    },
  );

  test('a random order replays from the seed the runner printed', () async {
    final _SuiteRun first = await runSuite(['suite', '${_seedFlag}random']);
    final List<String> seeds = _reportedSeeds(first.run.stdout);
    expect(seeds, hasLength(1), reason: first.run.stdout);
    expectPassed(first);
    final List<String> order = _ranOrder(first.report);
    // Every one of the fixture's eight ordering cases, each run once.
    expect(order, unorderedEquals([for (var i = 0; i < 8; i++) 'case $i']));

    final _SuiteRun again = await runSuite([
      'suite',
      '$_seedFlag${seeds.single}',
    ]);
    expect(_reportedSeeds(again.run.stdout), seeds, reason: again.run.stdout);
    expectPassed(again);
    expect(_ranOrder(again.report), order);
  });
}

/// The seed test on the launcher's direct path: the plain-`main` fixture
/// (`args[1]`) exits non-zero if a seed option reaches it.
void _plainSeedTest(String launcher, List<String> args) {
  test('a test without package:test never sees a seed option', () async {
    final _Run run = await _launch(
      launcher,
      [
        'args-probe',
        'first',
        '${_seedFlag}7',
        'second',
        '${_seedFlag}random',
        '${_seedFlag}not-a-seed',
        'third',
      ],
      {
        'RULES_DART_DART': args[2],
        'RULES_DART_DILL': args[1],
        'RULES_DART_TEST_RUNNER': '',
      },
    );
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    expect(_tagged(run.stdout, 'arg:'), ['first', 'second', 'third']);
  });
}

/// The p95 of `kernel_module_test`'s slowest shard at each `shard_count` it was
/// measured at, in seconds (`1` is the suite unsharded): ten runs each, run as
/// the nightly flake sweep runs them, with `--local_test_jobs` at twice the
/// host's CPUs and the cases in random order.
const Map<int, double> _kernelModuleSlowestShard = {
  1: 24.2,
  2: 21.3,
  4: 21.4,
  8: 19.8,
  16: 13.4,
};

/// Bazel's timeout in seconds for each test `size`, and for each `timeout`,
/// which overrides the size's when a target states one.
const Map<String, int> _timeoutSeconds = {
  'small': 60,
  'medium': 300,
  'large': 900,
  'enormous': 3600,
  'short': 60,
  'moderate': 300,
  'long': 900,
  'eternal': 3600,
};

/// The longest an unsharded test may take at p95, in seconds, before it has
/// to be split into shards.
const _unshardedCeiling = 120;

/// [build] with every `#` comment taken out, so that a commented-out
/// attribute does not count.
String _withoutComments(String build) => [
  for (final String line in const LineSplitter().convert(build))
    line.replaceFirst(RegExp(r'#.*$'), ''),
].join('\n');

/// The call in [build] that declares [name], from its opening parenthesis to
/// the one that closes it, or null when no call declares it.
String? _declaration(String build, String name) {
  final RegExpMatch? named = RegExp('name = "${RegExp.escape(name)}"')
      .firstMatch(build);
  if (named == null) return null;
  final int open = build.lastIndexOf('(', named.start);
  var depth = 0;
  for (var i = open; i < build.length; i++) {
    if (build[i] == '(') depth++;
    if (build[i] == ')' && --depth == 0) return build.substring(open, i + 1);
  }
  return null;
}

/// The value [attribute] is given in [declaration], or null when it is not.
String? _attribute(String declaration, String attribute) =>
    RegExp('\\b$attribute = "?(\\w+)"?').firstMatch(declaration)?.group(1);

/// What is wrong with how [build] shards and sizes `kernel_module_test`,
/// against the [slowestShard] p95 measured at each shard count.
///
/// The test must be split into 2 to 50 shards, and the slowest shard expected
/// at its count must take at most half of its timeout (as the nightly sweep
/// checks), and at most [_unshardedCeiling]. A count between two measured
/// ones is expected to be as slow as the lower one: more shards never make
/// the slowest one slower.
List<String> _shardingProblems(String build, Map<int, double> slowestShard) {
  final String? declaration = _declaration(
    _withoutComments(build),
    'kernel_module_test',
  );
  if (declaration == null) return ['kernel_module_test is not declared'];
  final int shards =
      int.tryParse(_attribute(declaration, 'shard_count') ?? '') ?? 1;
  if (shards < 2 || shards > 50) {
    return ['kernel_module_test has shard_count $shards, not 2 to 50'];
  }
  // Bazel's default size is `medium`.
  final String limit =
      _attribute(declaration, 'timeout') ??
      _attribute(declaration, 'size') ??
      'medium';
  final int? timeout = _timeoutSeconds[limit];
  if (timeout == null) return ['kernel_module_test has unknown size $limit'];
  final int measured = slowestShard.keys
      .where((int count) => count <= shards)
      .reduce(max);
  final double slowest = slowestShard[measured]!;
  final where =
      'kernel_module_test at $shards shards: slowest shard ${slowest}s';
  return [
    if (slowest * 2 > timeout)
      "$where is over half of $limit's ${timeout}s timeout",
    if (slowest > _unshardedCeiling) '$where is over ${_unshardedCeiling}s',
  ];
}

/// A `kernel_module_test` declaration with [attributes] in it.
String _kernelModuleTest(String attributes) =>
    'dart_test(\n    name = "kernel_module_test",\n$attributes'
    '    main = "kernel_module_test.dart",\n)\n';

/// The tests that hold `kernel_module_test`'s `shard_count` and `size`, read
/// from the package's [build] file, to the shard times it was measured at.
///
/// They sit with the launcher's tests because the launcher is what splits a
/// `package:test` suite into Bazel's shards.
void _shardingTests(String build) {
  group('kernel_module_test sharding', () {
    test('is sharded and sized for the measured shard times', () {
      final String text = File(Runfiles.create().rlocation(build))
          .readAsStringSync();
      expect(_shardingProblems(text, _kernelModuleSlowestShard), isEmpty);
    });

    test('refuses a missing, commented-out or out-of-range shard_count', () {
      for (final attributes in [
        '    size = "small",\n',
        '    size = "small",\n    # shard_count = 16,\n',
        '    size = "small",\n    shard_count = 1,\n',
        '    size = "small",\n    shard_count = 51,\n',
      ]) {
        expect(
          _shardingProblems(
            _kernelModuleTest(attributes),
            _kernelModuleSlowestShard,
          ),
          isNotEmpty,
          reason: attributes,
        );
      }
    });

    test('refuses a size whose timeout the measured shards contradict', () {
      // Measurements twice as slow as the real ones: 16 shards still fit
      // `small`, 8 shards fit `medium` but not `small` or a `short` timeout.
      final Map<int, double> slower = {
        for (final MapEntry<int, double> entry
            in _kernelModuleSlowestShard.entries)
          entry.key: entry.value * 2,
      };
      String sized(String size, int shards) => _kernelModuleTest(
        '    size = "$size",\n    shard_count = $shards,\n',
      );
      expect(_shardingProblems(sized('small', 16), slower), isEmpty);
      expect(_shardingProblems(sized('small', 8), slower), isNotEmpty);
      expect(_shardingProblems(sized('medium', 8), slower), isEmpty);
      expect(
        _shardingProblems(
          _kernelModuleTest(
            '    size = "medium",\n    shard_count = 8,\n'
            '    timeout = "short",\n',
          ),
          slower,
        ),
        isNotEmpty,
      );
    });
  });
}

/// Tests that a plain-`main()` test without `package:test` refuses case
/// selection options (`--test_filter`, `include_tags`, `exclude_tags`).
void _plainSelectionTests(String launcher, List<String> args) {
  Map<String, String> plainEnv(String key, String value) => {
    'RULES_DART_DART': args[2],
    'RULES_DART_DILL': args[1],
    'RULES_DART_TEST_RUNNER': '',
    key: value,
  };

  // A plain `main` has no cases to select, so a filter must fail loudly
  // rather than run everything and report a filtered pass.
  test('a test without package:test refuses --test_filter', () async {
    final _Run run = await _launch(launcher, [
      'stream',
    ], plainEnv('TESTBRIDGE_TEST_ONLY', 'anything'));
    expect(run.exitCode, 1);
    expect(
      run.stderr,
      contains('--test_filter needs a test written with package:test'),
    );
  });

  test('a test without package:test refuses include_tags', () async {
    final _Run run = await _launch(launcher, [
      'stream',
    ], plainEnv('RULES_DART_INCLUDE_TAGS', 'smoke'));
    expect(run.exitCode, 1);
    expect(run.stdout, isEmpty);
    expect(
      run.stderr,
      startsWith(
        'dart_test: include_tags needs a test written with package:test',
      ),
    );
  });

  test('a test without package:test refuses exclude_tags', () async {
    final _Run run = await _launch(launcher, [
      'stream',
    ], plainEnv('RULES_DART_EXCLUDE_TAGS', 'broken'));
    expect(run.exitCode, 1);
    expect(run.stdout, isEmpty);
    expect(
      run.stderr,
      startsWith(
        'dart_test: exclude_tags needs a test written with package:test',
      ),
    );
  });
}

/// Runs `suiteCommand` with the given [env] and standard test parameters.
List<String> _runSuiteCommand({Map<String, String> env = const {}}) =>
    suiteCommand(
      runner: 'runner.dill',
      precompiled: '/tmp/precompiled',
      testPath: 'test/my_test.dart',
      report: '/tmp/report.json',
      env: env,
      seed: null,
    );

/// Expected `suiteCommand` argv, with optional [tagArgs] inserted before the test path.
List<String> _expectedSuiteArgs({List<String> tagArgs = const []}) => [
  '--enable-asserts',
  'runner.dill',
  '--precompiled=/tmp/precompiled',
  '--reporter=expanded',
  '--timeout=none',
  '--file-reporter=json:/tmp/report.json',
  ...tagArgs,
  'test/my_test.dart',
];

/// Tests for single-word tag entries in `suiteCommand`.
void _tagSingleWordArgvTests() {
  test('passes single-word tag options and omits them when empty', () {
    expect(_runSuiteCommand(), _expectedSuiteArgs());
    expect(
      _runSuiteCommand(env: {'RULES_DART_INCLUDE_TAGS': ''}),
      _expectedSuiteArgs(),
    );
    expect(
      _runSuiteCommand(env: {'RULES_DART_EXCLUDE_TAGS': ''}),
      _expectedSuiteArgs(),
    );
    expect(
      _runSuiteCommand(
        env: {'RULES_DART_INCLUDE_TAGS': '', 'RULES_DART_EXCLUDE_TAGS': ''},
      ),
      _expectedSuiteArgs(),
    );
    expect(
      _runSuiteCommand(env: {'RULES_DART_INCLUDE_TAGS': '(smoke)'}),
      _expectedSuiteArgs(tagArgs: ['--tags', '(smoke)']),
    );
    expect(
      _runSuiteCommand(env: {'RULES_DART_INCLUDE_TAGS': '(smoke) && (unit)'}),
      _expectedSuiteArgs(tagArgs: ['--tags', '(smoke) && (unit)']),
    );
    expect(
      _runSuiteCommand(env: {'RULES_DART_EXCLUDE_TAGS': '(broken)'}),
      _expectedSuiteArgs(tagArgs: ['--exclude-tags', '(broken)']),
    );
    expect(
      _runSuiteCommand(env: {'RULES_DART_EXCLUDE_TAGS': '(broken) || (flaky)'}),
      _expectedSuiteArgs(tagArgs: ['--exclude-tags', '(broken) || (flaky)']),
    );
    expect(
      _runSuiteCommand(
        env: {
          'RULES_DART_INCLUDE_TAGS': '(smoke) && (unit)',
          'RULES_DART_EXCLUDE_TAGS': '(broken) || (flaky)',
        },
      ),
      _expectedSuiteArgs(
        tagArgs: [
          '--tags',
          '(smoke) && (unit)',
          '--exclude-tags',
          '(broken) || (flaky)',
        ],
      ),
    );
  });
}

/// Tests for compound tag selectors and selectors with ternary operators in `suiteCommand`.
void _tagCompoundArgvTests() {
  test(
    'passes compound tag selectors with precedence-preserving parentheses',
    () {
      expect(
        _runSuiteCommand(
          env: {'RULES_DART_INCLUDE_TAGS': '(smoke || fast) && (linux)'},
        ),
        _expectedSuiteArgs(tagArgs: ['--tags', '(smoke || fast) && (linux)']),
      );
      expect(
        _runSuiteCommand(
          env: {'RULES_DART_EXCLUDE_TAGS': '(ios ? slow : broken) || (flaky)'},
        ),
        _expectedSuiteArgs(
          tagArgs: ['--exclude-tags', '(ios ? slow : broken) || (flaky)'],
        ),
      );
      expect(
        _runSuiteCommand(
          env: {
            'RULES_DART_INCLUDE_TAGS': '(smoke || fast) && (linux)',
            'RULES_DART_EXCLUDE_TAGS': '(ios ? slow : broken) || (flaky)',
          },
        ),
        _expectedSuiteArgs(
          tagArgs: [
            '--tags',
            '(smoke || fast) && (linux)',
            '--exclude-tags',
            '(ios ? slow : broken) || (flaky)',
          ],
        ),
      );
    },
  );

  test('passes single selector holding ternary operator', () {
    expect(
      _runSuiteCommand(
        env: {'RULES_DART_INCLUDE_TAGS': '(ios ? slow : broken)'},
      ),
      _expectedSuiteArgs(tagArgs: ['--tags', '(ios ? slow : broken)']),
    );
    expect(
      _runSuiteCommand(
        env: {'RULES_DART_EXCLUDE_TAGS': '(ios ? slow : broken)'},
      ),
      _expectedSuiteArgs(tagArgs: ['--exclude-tags', '(ios ? slow : broken)']),
    );
  });
}

/// Tests for the argv that `suiteCommand` builds for tag options.
void _tagArgvTests() {
  group('suiteCommand tag arguments', () {
    _tagSingleWordArgvTests();
    _tagCompoundArgvTests();
  });
}

/// The `file:` URI of the directory [below] [tree], as the writer spells it.
String _dirUri(Directory tree, String below) =>
    Uri.directory('${tree.path}/$below').toString();

/// The runtime package config: which packages are mapped and what is written.
void _packageConfigTests() {
  group('runtime package config', () {
    late Directory tree;
    setUp(() => tree = Directory.systemTemp.createTempSync('pkg_cfg_'));
    tearDown(() => tree.deleteSync(recursive: true));

    File stage(String runfilesPath) => File('${tree.path}/$runfilesPath')
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    Map<String, String> dirs(
      List<PackageRoot> roots, {
      List<String>? manifest,
    }) => stagedLibDirs(
      roots,
      workspace: '_main',
      runfiles: (directory: tree.path, manifest: manifest ?? const []),
    );

    test('reads name and root from each line and skips malformed ones', () {
      expect(parsePackageRoots(['a\tpkg/a', 'no tab', '\tnoname', 'b\t']), [
        (name: 'a', root: 'pkg/a'),
        (name: 'b', root: ''),
      ]);
    });

    test('maps a package to the runfiles lib directory of its root', () {
      expect(
        libRunfilesPath((name: 'a', root: 'pkg/a'), '_main'),
        '_main/pkg/a/lib',
      );
      expect(
        libRunfilesPath((name: 'a', root: '../dep+/x'), '_main'),
        'dep+/x/lib',
      );
      expect(libRunfilesPath((name: 'a', root: ''), '_main'), '_main/lib');
    });

    test('lists only packages with files staged under lib/', () {
      stage('_main/pkg/a/lib/data/x.txt');
      Directory('${tree.path}/_main/pkg/b').createSync(recursive: true);
      stage('dep+/x/lib/y.txt');
      final Map<String, String> found = dirs([
        (name: 'a', root: 'pkg/a'),
        (name: 'b', root: 'pkg/b'),
        (name: 'c', root: '../dep+/x'),
        (name: 'd', root: 'pkg/missing'),
      ]);
      expect(found, {
        'a': '${tree.path}/_main/pkg/a/lib',
        'c': '${tree.path}/dep+/x/lib',
      });
    });

    test('keeps the first listing of a package name', () {
      stage('_main/one/lib/x.txt');
      stage('_main/two/lib/x.txt');
      expect(dirs([(name: 'a', root: 'one'), (name: 'a', root: 'two')]), {
        'a': '${tree.path}/_main/one/lib',
      });
    });

    test('finds a staged lib directory from the manifest alone', () {
      final real = File('${tree.path}/real/lib/data/x.txt')
        ..createSync(recursive: true);
      final Map<String, String> found = stagedLibDirs(
        [(name: 'a', root: 'pkg/a'), (name: 'b', root: 'pkg/b')],
        workspace: '_main',
        runfiles: (
          directory: null,
          manifest: ['_main/pkg/a/lib/data/x.txt ${real.path}'],
        ),
      );
      expect(found, {'a': '${tree.path}/real/lib'});
    });

    test('writes file URIs in name order and nothing for no package', () {
      final config = jsonDecode(
        packageConfigJson({
          'z': '${tree.path}/p/z/lib',
          'a': '${tree.path}/p/a/lib',
        }),
      ) as Map<String, dynamic>;
      expect(config['configVersion'], 2);
      expect(config['packages'], [
        {'name': 'a', 'rootUri': _dirUri(tree, 'p/a'), 'packageUri': 'lib/'},
        {'name': 'z', 'rootUri': _dirUri(tree, 'p/z'), 'packageUri': 'lib/'},
      ]);
      final empty =
          jsonDecode(packageConfigJson(const {})) as Map<String, dynamic>;
      expect(empty['packages'], isEmpty);
    });

    test('writes the file whole, in a directory made for it', () {
      final target = File('${tree.path}/pre/.dart_tool/package_config.json');
      writePackageConfig(target, '{"a":1}');
      writePackageConfig(target, '{"a":2}');
      expect(target.readAsStringSync(), '{"a":2}');
      // Compare as URIs: the listing spells separators the platform's way.
      expect(target.parent.listSync().map((e) => e.uri), [target.uri]);
    });
  });
}
