import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';

import 'private_home.dart';
import 'test_runner_coverage.dart';
import 'test_runner_workspace.dart' as staging;

/// Runs a `dart_test`'s pre-compiled kernel with asserts enabled.
///
/// The suite runs as a file-form `dart` execution, which never touches HOME,
/// so the program keeps the caller's environment minus this ruleset's own
/// control variables: it starts with the complete filtered environment and
/// the parent excluded, so no `RULES_DART_*` variable reaches it while PATH,
/// HOME, the pub cache, credentials, TEST_* and the runfiles variables do;
/// the launcher itself writes nothing under HOME either.
///
/// `dart_test` compiles the test at build time, so this launcher only resolves
/// files from runfiles and starts the VM — there is no package_config or source
/// co-location to do at runtime.
///
/// A test that depends on `package:test` runs under that package's own runner,
/// which this launcher adapts to Bazel's test protocol: `--test_filter` becomes
/// `--name`, sharding becomes `--total-shards`/`--shard-index`, the runner's
/// JSON report becomes the JUnit XML Bazel reads, and `package:test`'s own
/// 30-second default per case is replaced by Bazel's `TEST_TIMEOUT`, so that
/// Bazel's `size`/`timeout` is the limit. Any other test runs directly, and
/// refuses a filter or sharding it cannot honour rather than quietly running
/// everything.
///
/// A `--test-randomize-ordering-seed=<value>` argument (passed with
/// `bazel test --test_arg=...`, the value `random` or a decimal integer) is
/// handed to `package:test`'s runner, once, rather than to the test's `main`:
/// the runner shuffles the cases with it and prints the seed it used into the
/// test log, so a failure in one shuffled order can be run again in the same
/// order. A plain `main` has no cases to shuffle, so every such argument is
/// taken out before it starts.
///
/// Under `bazel coverage` (`COVERAGE_OUTPUT_FILE` set) the VM is started so
/// that its isolates can be collected, and the LCOV is written when it exits;
/// a collection that fails or is partial fails the run (see
/// `test_runner_coverage.dart`).
///
/// The VM writes straight to this process's stdio rather than through it, so a
/// test that hangs until Bazel kills it still leaves what it printed in
/// test.log, and the launcher exits with the VM even if the test leaked a
/// process that holds those streams open.
Future<void> main(List<String> args) async {
  final Map<String, String> env = Platform.environment;
  final String? dartKey = env['RULES_DART_DART'];
  final String? dillKey = env['RULES_DART_DILL'];

  if (dartKey == null || dillKey == null) {
    stderr.writeln('Missing required environment variables.');
    stderr.writeln('  RULES_DART_DART=$dartKey');
    stderr.writeln('  RULES_DART_DILL=$dillKey');
    exit(1);
  }

  final r = Runfiles.create();
  final String dart = File(r.rlocation(dartKey)).absolute.path;
  final String dill = File(r.rlocation(dillKey)).absolute.path;
  final String? manifest = _findManifestFile(env);
  final String? workspace = _workspaceName(env, dillKey);
  final CoverageConfig? coverage = _coverageConfig(env, r);

  // Empty counts as unset, so a test that starts another `dart_test` binary
  // can keep its own runner settings from leaking into the child.
  final String? runnerKey = env['RULES_DART_TEST_RUNNER'];
  if (runnerKey == null || runnerKey.isEmpty) {
    exit(
      await _runDirectly(
        dart,
        dill,
        args,
        manifest: manifest,
        workspace: workspace,
        coverage: coverage,
      ),
    );
  }
  final String? baseDillKey = env['RULES_DART_BASE_DILL'];
  String? baseDill;
  if (baseDillKey != null && baseDillKey.isNotEmpty) {
    try {
      baseDill = File(r.rlocation(baseDillKey)).absolute.path;
    } on StateError catch (e) {
      stderr.writeln('dart_test: base dill not found ($baseDillKey): $e');
      exit(1);
    }
  }
  final ({String dart, String runner}) suiteVm = (
    dart: dart,
    runner: File(r.rlocation(runnerKey)).absolute.path,
  );
  final ({String? baseDill, String dill, String testPath, String testSource})
  suiteSource = (
    dill: dill,
    baseDill: baseDill,
    testSource: File(r.rlocation(env['RULES_DART_TEST_MAIN']!)).absolute.path,
    testPath: env['RULES_DART_TEST_PATH']!,
  );
  exit(
    await _runUnderRunner(
      vm: suiteVm,
      source: suiteSource,
      workspace: (manifest: manifest, workspace: workspace),
      args: args,
      coverage: coverage,
    ),
  );
}

/// The coverage settings for this run, or null when Bazel asked for none.
///
/// Exits when coverage was asked for and cannot be set up.
CoverageConfig? _coverageConfig(Map<String, String> env, Runfiles r) {
  try {
    return CoverageConfig.fromEnvironment(
      env,
      locate: (key) => File(r.rlocation(key)).absolute.path,
    );
  } on CoverageFailure catch (e) {
    stderr.writeln('dart_test: coverage failed: $e');
    exit(1);
  }
}

/// The runner's default per-case timeout: Bazel's own for this test, which
/// Bazel always sets; `none` only when run outside Bazel.
String _suiteTimeout(Map<String, String> env) {
  final int? seconds = int.tryParse(env['TEST_TIMEOUT'] ?? '');
  return seconds == null ? 'none' : '${seconds}s';
}

/// The exit code `package:test`'s runner uses when no test ran.
const _noTestsRan = 79;

/// Deletes a scratch file the launcher no longer needs, ignoring failure.
///
/// Scratch cleanup is best-effort: the run's result no longer depends on these
/// files, so a failure to remove one must not fail the run or mask its exit
/// code. Only filesystem failures are ignored; anything else is a programming
/// error and propagates.
void deleteScratchQuietly(FileSystemEntity entity) =>
    staging.deleteScratchQuietly(entity);

/// Checks whether environment variables requiring `package:test` were set on
/// a test running directly with a plain `main()`.
///
/// Returns 1 with an error message on stderr if an unsupported feature was
/// requested, or null if the test can proceed.
int? _checkPlainMainRequirements(Map<String, String> env) {
  if (env.containsKey('TESTBRIDGE_TEST_ONLY')) {
    stderr.writeln(
      'dart_test: --test_filter needs a test written with package:test; this '
      'one has a plain main() and cannot select cases.',
    );
    return 1;
  }
  if (env.containsKey('TEST_TOTAL_SHARDS')) {
    stderr.writeln(
      'dart_test: shard_count needs a test written with package:test; this '
      'one has a plain main() and cannot be split.',
    );
    return 1;
  }
  final String? includeTags = env['RULES_DART_INCLUDE_TAGS'];
  if (includeTags != null && includeTags.isNotEmpty) {
    stderr.writeln(
      'dart_test: include_tags needs a test written with package:test; this '
      'one has a plain main() and cannot select cases.',
    );
    return 1;
  }
  final String? excludeTags = env['RULES_DART_EXCLUDE_TAGS'];
  if (excludeTags != null && excludeTags.isNotEmpty) {
    stderr.writeln(
      'dart_test: exclude_tags needs a test written with package:test; this '
      'one has a plain main() and cannot select cases.',
    );
    return 1;
  }
  return null;
}

Future<int> _runDirectly(
  String dart,
  String dill,
  List<String> args, {
  required String? manifest,
  required String? workspace,
  required CoverageConfig? coverage,
}) async {
  final Map<String, String> env = Platform.environment;
  // A plain `main` has no notion of test cases, so there is nothing to filter,
  // split or select by tag. Running every case anyway would report a filtered or
  // sharded run that never happened.
  final int? refusal = _checkPlainMainRequirements(env);
  if (refusal != null) return refusal;
  final bool inPlace = staging.workspaceInPlace(
    manifest: manifest,
    workspace: workspace,
  );
  Directory? scratch;
  if (!inPlace) {
    scratch = Directory(env['TEST_TMPDIR'] ?? Directory.systemTemp.path)
        .createTempSync('dart_test.');
    staging.materializeWorkspace(
      manifest: File(manifest!).readAsLinesSync(),
      workspace: workspace!,
      into: scratch.path,
    );
  }
  // The program keeps the caller's environment (see above) with the parent
  // excluded, so no `RULES_DART_*` control variable reaches it (Dart would
  // otherwise merge the map over the parent); the resolved runfiles
  // locations still win over the inherited ones.
  final Map<String, String> childEnv = {
    ...withoutRulesDartControls(env),
    ..._childRunfilesEnv(env, manifest),
  };
  final Process vm = await Process.start(
    dart,
    [
      ...?coverage?.vmFlags,
      '--enable-asserts',
      dill,
      ..._withoutSeedFlags(args),
    ],
    workingDirectory: scratch?.path,
    environment: childEnv.isEmpty ? null : childEnv,
    includeParentEnvironment: false,
    mode: ProcessStartMode.inheritStdio,
  );
  final CoverageSession? session = coverage == null
      ? null
      : CoverageSession.attach(coverage, vm);
  try {
    final int code = await vm.exitCode;
    return session == null ? code : await session.finish(code);
  } finally {
    if (scratch != null && !env.containsKey('TEST_TMPDIR')) {
      deleteScratchQuietly(scratch);
    }
  }
}

/// The executables for one suite run: the Dart VM and the `package:test`
/// runner that hosts the suite.
typedef _SuiteVm = ({String dart, String runner});

/// The suite under run: its precompiled dill, the base dill it extends, the
/// test source, and the test's workspace-relative path.
typedef _SuiteSource = ({
  String dill,
  String? baseDill,
  String testSource,
  String testPath,
});

/// The runfiles context a suite runs in: the manifest file and the workspace
/// name, each null outside Bazel.
typedef _SuiteWorkspace = ({String? manifest, String? workspace});

Future<int> _runUnderRunner({
  required _SuiteVm vm,
  required _SuiteSource source,
  required _SuiteWorkspace workspace,
  required List<String> args,
  required CoverageConfig? coverage,
}) async {
  final Map<String, String> env = Platform.environment;

  if (!_isRunnableLayout(
    dill: source.dill,
    baseDill: source.baseDill,
    testPath: source.testPath,
  )) {
    return 1;
  }
  final Directory tmp = Directory(
    env['TEST_TMPDIR'] ?? Directory.systemTemp.path,
  ).createTempSync('dart_test.');
  final _Precompiled pre = _preparePrecompiled(
    dill: source.dill,
    baseDill: source.baseDill,
    testPath: source.testPath,
    tmp: tmp,
  );
  final bool inPlace = _stageSuiteWorkspace(
    testSource: source.testSource,
    testPath: source.testPath,
    manifest: workspace.manifest,
    workspace: workspace.workspace,
    tmp: tmp,
  );
  final String report = staging.joinPaths(tmp.path, 'results.json');
  final _LauncherArgs launcherArgs = _splitSeed(args);

  final Process vmProcess = await Process.start(
    vm.dart,
    [
      ...?coverage?.vmFlags,
      ...suiteCommand(
        runner: vm.runner,
        precompiled: pre.precompiled,
        testPath: source.testPath,
        report: report,
        env: env,
        seed: launcherArgs.seed,
      ),
    ],
    workingDirectory: inPlace ? null : tmp.path,
    environment: {
      ...withoutRulesDartControls(env),
      ..._childRunfilesEnv(env, workspace.manifest),
      // The test's `main` gets the launcher's arguments less the seed, which
      // went to the runner above.
      'RULES_DART_TEST_ARGS': jsonEncode(launcherArgs.rest),
      // The runner reads a per-user config (`~/.dart_test.yaml`, or
      // `%LOCALAPPDATA%\DartTest.yaml`) unless this names one. A path that
      // does not exist means none: a developer's own settings must not change
      // what a test does under Bazel, and Bazel's Windows test environment has
      // no LOCALAPPDATA for the runner to read at all.
      'DART_TEST_CONFIG': staging.joinPaths(
        tmp.path,
        'no_global_config/DartTest.yaml',
      ),
    },
    // The map above is the complete filtered environment: the parent is
    // excluded, so no `RULES_DART_*` control variable reaches the suite.
    includeParentEnvironment: false,
    mode: ProcessStartMode.inheritStdio,
  );
  final CoverageSession? session = coverage == null
      ? null
      : CoverageSession.attach(coverage, vmProcess);
  final int suiteCode = await _waitForSuite(vmProcess, combined: pre.combined);
  // The suite's code is mapped onto Bazel's first, so a coverage failure is
  // never hidden by the "no test ran" tolerance.
  final int code = _finishSuiteRun(
    code: suiteCode,
    report: report,
    testPath: source.testPath,
    env: env,
  );
  return session == null ? code : await session.finish(code);
}

/// Whether the dill is laid out where the runner loads it from.
///
/// Reports the layout problem and returns false when it is not.
bool _isRunnableLayout({
  required String dill,
  required String? baseDill,
  required String testPath,
}) {
  // The runner loads the precompiled suite from `<dir>/<path>.vm_test.vm.app.dill`
  // — which is where `dart_test` put the dill, so it is loaded in place — and
  // reads the test's source at `<path>` relative to its working directory for
  // its annotations. The suite runs as an isolate inside the runner, so the
  // runner's working directory is the test's: Bazel's contract makes that the
  // runfiles workspace root, where `data` is found by workspace-relative path.
  // Only where runfiles cannot hold the source at that relative path (Windows
  // or `--noenable_runfiles` has only a manifest) is the workspace's runfiles
  // laid out in a scratch directory from the manifest, to run in.
  final suffix = '/$testPath.vm_test.vm.app.dill';
  final String normalized = dill.replaceAll(r'\', '/');
  if (!normalized.endsWith(suffix)) {
    stderr.writeln('dart_test: $dill is not laid out for $testPath');
    return false;
  }
  if (baseDill != null && !File(baseDill).existsSync()) {
    stderr.writeln('dart_test: base dill not found: $baseDill');
    return false;
  }
  return true;
}

/// The precompiled suite directory and the combined dill, when one is needed.
typedef _Precompiled = ({String precompiled, File? combined});

/// Prepares the precompiled suite directory (see [_Precompiled]).
///
/// The layout is already checked by [_isRunnableLayout].
_Precompiled _preparePrecompiled({
  required String dill,
  required String? baseDill,
  required String testPath,
  required Directory tmp,
}) {
  final suffix = '/$testPath.vm_test.vm.app.dill';
  String precompiled = dill.substring(0, dill.length - suffix.length);
  File? combined;
  if (baseDill != null) {
    final String combinedPath = staging.joinPaths(
      tmp.path,
      'precompiled/$testPath.vm_test.vm.app.dill',
    );
    precompiled = combinedPath.substring(
      0,
      combinedPath.length - suffix.length,
    );
    combined = File(combinedPath);
    final builder = BytesBuilder(copy: false)
      ..add(File(dill).readAsBytesSync())
      ..add(File(baseDill).readAsBytesSync());
    combined.writeAsBytesSync(builder.takeBytes(), flush: true);
  }
  return (precompiled: precompiled, combined: combined);
}

/// Lays out the workspace's runfiles in [tmp] unless they are usable in place.
///
/// Returns whether the suite runs in place.
bool _stageSuiteWorkspace({
  required String testSource,
  required String testPath,
  required String? manifest,
  required String? workspace,
  required Directory tmp,
}) {
  final bool inPlace = staging.workspaceInPlace(
    testPath: testPath,
    manifest: manifest,
    workspace: workspace,
  );
  if (!inPlace) {
    // The workspace's runfiles are laid out in the scratch directory, so `data`
    // is found by workspace-relative path as it is in a runfiles tree.
    if (manifest != null && workspace != null) {
      staging.materializeWorkspace(
        manifest: File(manifest).readAsLinesSync(),
        workspace: workspace,
        into: tmp.path,
      );
    }
    final inScratch = File(staging.joinPaths(tmp.path, testPath));
    if (!inScratch.existsSync()) {
      File(testSource).copySync(inScratch.path);
    }
  }
  return inPlace;
}

/// The prefix of Bazel's `--test-randomize-ordering-seed=<value>` launcher
/// argument, which is also the option `package:test`'s runner takes.
const _seedFlag = '--test-randomize-ordering-seed=';

/// The seed values `package:test`'s runner takes: `random`, or a decimal
/// integer (which it reduces to 32 bits and prints back).
final _seedValue = RegExp(r'^(?:random|[+-]?[0-9]+)$');

/// The launcher's arguments, split into the ordering seed for
/// `package:test`'s runner, if one was given, and the arguments the test's
/// own `main` gets.
typedef _LauncherArgs = ({String? seed, List<String> rest});

/// The launcher's [args] split into the ordering seed for `package:test`'s
/// runner and the arguments the test's own `main` gets.
///
/// Every `--test-randomize-ordering-seed=<value>` whose value the runner takes
/// is taken out of [args]. The last one wins, as a repeated flag does on any
/// command line, so a seed given with `--test_arg` overrides one in the
/// target's own `args`. Every other argument, a seed flag with a value the
/// runner would not take among them, stays where it was.
_LauncherArgs _splitSeed(List<String> args) {
  String? seed;
  final rest = <String>[];
  for (final arg in args) {
    final String? value = arg.startsWith(_seedFlag)
        ? arg.substring(_seedFlag.length)
        : null;
    if (value != null && _seedValue.hasMatch(value)) {
      seed = value;
    } else {
      rest.add(arg);
    }
  }
  return (seed: seed, rest: rest);
}

/// [args] without any `--test-randomize-ordering-seed=...` argument.
///
/// A plain `main` has no cases to shuffle, and must not be handed an option
/// meant for `package:test`'s runner that it would read as its own argument.
List<String> _withoutSeedFlags(List<String> args) => [
  for (final arg in args)
    if (!arg.startsWith(_seedFlag)) arg,
];

/// The runner command line for one suite run.
///
/// A [seed] goes to the runner as its one `--test-randomize-ordering-seed`.
List<String> suiteCommand({
  required String runner,
  required String precompiled,
  required String testPath,
  required String report,
  required Map<String, String> env,
  required String? seed,
}) {
  final String? filter = env['TESTBRIDGE_TEST_ONLY'];
  final String? totalShards = env['TEST_TOTAL_SHARDS'];
  final String? shardIndex = env['TEST_SHARD_INDEX'];
  final String? shardStatus = env['TEST_SHARD_STATUS_FILE'];
  final String? includeTags = env['RULES_DART_INCLUDE_TAGS'];
  final String? excludeTags = env['RULES_DART_EXCLUDE_TAGS'];

  // Touched before the run, as Bazel asks: it is how a test runner says it
  // supports sharding at all.
  if (shardStatus != null) {
    File(shardStatus).writeAsStringSync('');
  }
  return [
    '--enable-asserts',
    runner,
    '--precompiled=$precompiled',
    '--reporter=expanded',
    // Bazel's timeout replaces `package:test`'s 30-second default. Not
    // `none`: in `package:test` a suite-level `none` also overrides the
    // timeout a test states on its own case, and that one is the author's.
    '--timeout=${_suiteTimeout(env)}',
    '--file-reporter=json:$report',
    if (filter != null && filter.isNotEmpty) ...['--name', filter],
    if (includeTags != null && includeTags.isNotEmpty) ...[
      '--tags',
      includeTags,
    ],
    if (excludeTags != null && excludeTags.isNotEmpty) ...[
      '--exclude-tags',
      excludeTags,
    ],
    if (totalShards != null && shardIndex != null) ...[
      '--total-shards',
      totalShards,
      '--shard-index',
      shardIndex,
    ],
    // The runner prints the seed it shuffled with, a concrete one for
    // `random` too, straight into the test log.
    if (seed != null) '$_seedFlag$seed',
    testPath,
  ];
}

/// Waits for the suite VM, deleting the combined dill it no longer needs.
Future<int> _waitForSuite(Process vm, {required File? combined}) async {
  try {
    return await vm.exitCode;
  } finally {
    if (combined != null) {
      deleteScratchQuietly(combined);
    }
  }
}

/// Maps the suite's exit code onto Bazel's and writes the JUnit report.
int _finishSuiteRun({
  required int code,
  required String report,
  required String testPath,
  required Map<String, String> env,
}) {
  // A filter that selects nothing here, or a shard that drew no cases, is not
  // a failure: `bazel test //... --test_filter=x` has to pass every target the
  // filter does not touch.
  final bool selecting =
      env['TESTBRIDGE_TEST_ONLY'] != null || env['TEST_TOTAL_SHARDS'] != null;
  if (code == _noTestsRan && selecting) {
    code = 0;
  }

  final String? xmlOutput = env['XML_OUTPUT_FILE'];
  if (xmlOutput != null) {
    final reportFile = File(report);
    if (reportFile.existsSync()) {
      File(xmlOutput).writeAsStringSync(
        junitXml(reportFile.readAsLinesSync(), suiteName: testPath),
      );
    }
  }
  return code;
}

String? _findManifestFile(Map<String, String> env) {
  final String? fromEnv = env['RUNFILES_MANIFEST_FILE'];
  if (fromEnv != null && fromEnv.isNotEmpty && File(fromEnv).existsSync()) {
    return fromEnv;
  }
  final String? runfilesDir = env['RUNFILES_DIR'];
  if (runfilesDir != null && runfilesDir.isNotEmpty) {
    for (final candidate in [
      '$runfilesDir/MANIFEST',
      '${runfilesDir}_manifest',
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
  }
  final String exe = Platform.executable;
  for (final candidate in [
    '$exe.runfiles_manifest',
    '$exe.exe.runfiles_manifest',
    '$exe.runfiles/MANIFEST',
    '$exe.exe.runfiles/MANIFEST',
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

String? _workspaceName(Map<String, String> env, String dillKey) {
  final String? fromEnv = env['TEST_WORKSPACE'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  final int slash = dillKey.indexOf('/');
  return slash > 0 ? dillKey.substring(0, slash) : null;
}

Map<String, String> _childRunfilesEnv(
  Map<String, String> env,
  String? manifest,
) {
  final out = <String, String>{};
  final String? runfilesDir = env['RUNFILES_DIR'];
  if (runfilesDir != null &&
      runfilesDir.isNotEmpty &&
      Directory(runfilesDir).existsSync()) {
    out['RUNFILES_DIR'] = Directory(runfilesDir).resolveSymbolicLinksSync();
  } else {
    final String exe = Platform.executable;
    for (final candidate in ['$exe.runfiles', '$exe.exe.runfiles']) {
      if (Directory(candidate).existsSync()) {
        out['RUNFILES_DIR'] = Directory(candidate).resolveSymbolicLinksSync();
        break;
      }
    }
  }
  if (manifest != null) {
    out['RUNFILES_MANIFEST_FILE'] = File(manifest).absolute.path;
  }
  return out;
}

/// Lays out `workspace`'s runfiles under [into] from the lines of a runfiles
/// manifest, each `<runfiles path> <real path>`.
///
/// Where Bazel builds no runfiles tree (Windows by default, or
/// `--noenable_runfiles`) the manifest is all there is, and a test's working
/// directory would hold none of its `data`. A real path that is a directory (a
/// tree artifact is one entry) is copied whole.
void materializeWorkspace({
  required List<String> manifest,
  required String workspace,
  required String into,
}) {
  staging.materializeWorkspace(
    manifest: manifest,
    workspace: workspace,
    into: into,
  );
}

/// Converts `package:test`'s JSON reporter output into JUnit XML, one
/// `testcase` per test the runner did not hide (it hides its own "loading"
/// pseudo-tests unless they fail).
String junitXml(List<String> lines, {required String suiteName}) {
  final names = <int, String>{};
  final starts = <int, int>{};
  final cases = <_Case>[];
  final byId = <int, _Case>{};
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is! Map<String, dynamic>) continue;
    final Map<String, dynamic> event = decoded;
    switch (event['type']) {
      case 'testStart':
        final test = event['test'] as Map<String, dynamic>;
        final id = test['id'] as int;
        names[id] = test['name'] as String;
        starts[id] = event['time'] as int;
      case 'error':
        final id = event['testID'] as int;
        (byId[id] ??= _Case(
          id,
        )).errors.add('${event['error']}\n${event['stackTrace']}');
      case 'print':
        final id = event['testID'] as int;
        (byId[id] ??= _Case(id)).output.writeln(event['message']);
      case 'testDone':
        final id = event['testID'] as int;
        final _Case c = byId[id] ??= _Case(id);
        c
          ..hidden = event['hidden'] as bool? ?? false
          ..skipped = event['skipped'] as bool? ?? false
          ..result = event['result'] as String? ?? 'success'
          ..millis = (event['time'] as int) - (starts[id] ?? 0);
        cases.add(c);
    }
  }

  final List<_Case> shown = [
    for (final c in cases)
      if (!c.hidden || c.result != 'success') c,
  ];
  String seconds(int ms) => (ms / 1000).toStringAsFixed(3);
  final int failures = shown.where((c) => c.result == 'failure').length;
  final int errors = shown.where((c) => c.result == 'error').length;
  final int skipped = shown.where((c) => c.skipped).length;
  final int total = shown.fold<int>(0, (sum, c) => sum + c.millis);

  final out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<testsuites>')
    ..writeln(
      '  <testsuite name="${_attr(suiteName)}" tests="${shown.length}" '
      'failures="$failures" errors="$errors" skipped="$skipped" '
      'time="${seconds(total)}">',
    );
  for (final c in shown) {
    _writeTestCaseElement(
      out,
      c,
      names: names,
      suiteName: suiteName,
      seconds: seconds,
    );
  }
  out
    ..writeln('  </testsuite>')
    ..writeln('</testsuites>');
  return out.toString();
}

/// One `<testcase>` element for a shown case: open tag, skipped/failure
/// details, captured output, and close tag.
void _writeTestCaseElement(
  StringBuffer out,
  _Case c, {
  required Map<int, String> names,
  required String suiteName,
  required String Function(int) seconds,
}) {
  out.write(
    '    <testcase name="${_attr(names[c.id] ?? 'test ${c.id}')}" '
    'classname="${_attr(suiteName)}" time="${seconds(c.millis)}">',
  );
  if (c.skipped) {
    out.write('<skipped/>');
  } else if (c.result != 'success') {
    final tag = c.result == 'failure' ? 'failure' : 'error';
    final String message = c.errors.isEmpty ? c.result : c.errors.first;
    out.write(
      '<$tag message="${_attr(message.split('\n').first)}">'
      '${_text(c.errors.join('\n'))}</$tag>',
    );
  }
  if (c.output.isNotEmpty) {
    out.write('<system-out>${_text(c.output.toString())}</system-out>');
  }
  out.writeln('</testcase>');
}

class _Case {
  _Case(this.id);

  final int id;
  final List<String> errors = [];
  final StringBuffer output = StringBuffer();
  bool hidden = false;
  bool skipped = false;
  String result = 'success';
  int millis = 0;
}

String _text(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _attr(String s) => _text(s).replaceAll('"', '&quot;');
