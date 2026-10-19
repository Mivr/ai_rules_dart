import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';

/// Runs a `dart_test`'s pre-compiled kernel with asserts enabled.
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
/// The VM writes straight to this process's stdio rather than through it, so a
/// test that hangs until Bazel kills it still leaves what it printed in
/// test.log, and the launcher exits with the VM even if the test leaked a
/// process that holds those streams open.
Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final dartKey = env['RULES_DART_DART'];
  final dillKey = env['RULES_DART_DILL'];

  if (dartKey == null || dillKey == null) {
    stderr.writeln('Missing required environment variables.');
    stderr.writeln('  RULES_DART_DART=$dartKey');
    stderr.writeln('  RULES_DART_DILL=$dillKey');
    exit(1);
  }

  final r = Runfiles.create();
  final dart = File(r.rlocation(dartKey)).absolute.path;
  final dill = File(r.rlocation(dillKey)).absolute.path;
  final manifest = _findManifestFile(env);
  final workspace = _workspaceName(env, dillKey);

  // Empty counts as unset, so a test that starts another `dart_test` binary
  // can keep its own runner settings from leaking into the child.
  final runnerKey = env['RULES_DART_TEST_RUNNER'];
  if (runnerKey == null || runnerKey.isEmpty) {
    exit(
      await _runDirectly(
        dart,
        dill,
        args,
        manifest: manifest,
        workspace: workspace,
      ),
    );
  }
  final baseDillKey = env['RULES_DART_BASE_DILL'];
  String? baseDill;
  if (baseDillKey != null && baseDillKey.isNotEmpty) {
    try {
      baseDill = File(r.rlocation(baseDillKey)).absolute.path;
    } on StateError catch (e) {
      stderr.writeln('dart_test: base dill not found ($baseDillKey): $e');
      exit(1);
    }
  }
  exit(
    await _runUnderRunner(
      dart: dart,
      dill: dill,
      baseDill: baseDill,
      runner: File(r.rlocation(runnerKey)).absolute.path,
      testSource: File(r.rlocation(env['RULES_DART_TEST_MAIN']!)).absolute.path,
      testPath: env['RULES_DART_TEST_PATH']!,
      manifest: manifest,
      workspace: workspace,
      args: args,
    ),
  );
}

/// The runner's default per-case timeout: Bazel's own for this test, which
/// Bazel always sets; `none` only when run outside Bazel.
String _suiteTimeout(Map<String, String> env) {
  final seconds = int.tryParse(env['TEST_TIMEOUT'] ?? '');
  return seconds == null ? 'none' : '${seconds}s';
}

/// The exit code `package:test`'s runner uses when no test ran.
const _noTestsRan = 79;

Future<int> _runDirectly(
  String dart,
  String dill,
  List<String> args, {
  required String? manifest,
  required String? workspace,
}) async {
  final env = Platform.environment;
  // A plain `main` has no notion of test cases, so there is nothing to filter
  // or split. Running every case anyway would report a filtered or sharded run
  // that never happened.
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
  final inPlace = _workspaceInPlace(manifest: manifest, workspace: workspace);
  Directory? scratch;
  if (!inPlace) {
    scratch = Directory(env['TEST_TMPDIR'] ?? Directory.systemTemp.path)
        .createTempSync('dart_test.');
    materializeWorkspace(
      manifest: File(manifest!).readAsLinesSync(),
      workspace: workspace!,
      into: scratch.path,
    );
  }
  final childEnv = _childRunfilesEnv(env, manifest);
  final vm = await Process.start(
    dart,
    ['--enable-asserts', dill, ...args],
    workingDirectory: scratch?.path,
    environment: childEnv.isEmpty ? null : childEnv,
    mode: ProcessStartMode.inheritStdio,
  );
  try {
    return await vm.exitCode;
  } finally {
    if (scratch != null && !env.containsKey('TEST_TMPDIR')) {
      try {
        scratch.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}

Future<int> _runUnderRunner({
  required String dart,
  required String dill,
  String? baseDill,
  required String runner,
  required String testSource,
  required String testPath,
  required String? manifest,
  required String? workspace,
  required List<String> args,
}) async {
  final env = Platform.environment;

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
  final normalized = dill.replaceAll(r'\', '/');
  if (!normalized.endsWith(suffix)) {
    stderr.writeln('dart_test: $dill is not laid out for $testPath');
    return 1;
  }
  if (baseDill != null && !File(baseDill).existsSync()) {
    stderr.writeln('dart_test: base dill not found: $baseDill');
    return 1;
  }
  var precompiled = dill.substring(0, dill.length - suffix.length);
  final tmp = Directory(env['TEST_TMPDIR'] ?? Directory.systemTemp.path)
      .createTempSync('dart_test.');
  File? combinedDill;
  if (baseDill != null) {
    final combinedPath = _join(
      tmp.path,
      'precompiled/$testPath.vm_test.vm.app.dill',
    );
    precompiled = combinedPath.substring(
      0,
      combinedPath.length - suffix.length,
    );
    combinedDill = File(combinedPath);
    final builder = BytesBuilder(copy: false)
      ..add(File(dill).readAsBytesSync())
      ..add(File(baseDill).readAsBytesSync());
    combinedDill.writeAsBytesSync(builder.takeBytes(), flush: true);
  }
  final inPlace = _workspaceInPlace(
    testPath: testPath,
    manifest: manifest,
    workspace: workspace,
  );
  if (!inPlace) {
    // The workspace's runfiles are laid out in the scratch directory, so `data`
    // is found by workspace-relative path as it is in a runfiles tree.
    if (manifest != null && workspace != null) {
      materializeWorkspace(
        manifest: File(manifest).readAsLinesSync(),
        workspace: workspace,
        into: tmp.path,
      );
    }
    final inScratch = File(_join(tmp.path, testPath));
    if (!inScratch.existsSync()) {
      File(testSource).copySync(inScratch.path);
    }
  }

  final filter = env['TESTBRIDGE_TEST_ONLY'];
  final totalShards = env['TEST_TOTAL_SHARDS'];
  final shardIndex = env['TEST_SHARD_INDEX'];
  final xmlOutput = env['XML_OUTPUT_FILE'];
  final shardStatus = env['TEST_SHARD_STATUS_FILE'];
  final report = _join(tmp.path, 'results.json');

  // Touched before the run, as Bazel asks: it is how a test runner says it
  // supports sharding at all.
  if (shardStatus != null) {
    File(shardStatus).writeAsStringSync('');
  }

  final vm = await Process.start(
    dart,
    [
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
      if (totalShards != null && shardIndex != null) ...[
        '--total-shards',
        totalShards,
        '--shard-index',
        shardIndex,
      ],
      testPath,
    ],
    workingDirectory: inPlace ? null : tmp.path,
    environment: {
      ..._childRunfilesEnv(env, manifest),
      'RULES_DART_TEST_ARGS': jsonEncode(args),
      // The runner reads a per-user config (`~/.dart_test.yaml`, or
      // `%LOCALAPPDATA%\DartTest.yaml`) unless this names one. A path that
      // does not exist means none: a developer's own settings must not change
      // what a test does under Bazel, and Bazel's Windows test environment has
      // no LOCALAPPDATA for the runner to read at all.
      'DART_TEST_CONFIG': _join(tmp.path, 'no_global_config/DartTest.yaml'),
    },
    mode: ProcessStartMode.inheritStdio,
  );
  int code;
  try {
    code = await vm.exitCode;
  } finally {
    if (combinedDill != null && combinedDill.existsSync()) {
      try {
        combinedDill.deleteSync();
      } catch (_) {}
    }
  }

  // A filter that selects nothing here, or a shard that drew no cases, is not
  // a failure: `bazel test //... --test_filter=x` has to pass every target the
  // filter does not touch.
  final selecting = filter != null || totalShards != null;
  if (code == _noTestsRan && selecting) {
    code = 0;
  }

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
  final fromEnv = env['RUNFILES_MANIFEST_FILE'];
  if (fromEnv != null && fromEnv.isNotEmpty && File(fromEnv).existsSync()) {
    return fromEnv;
  }
  final runfilesDir = env['RUNFILES_DIR'];
  if (runfilesDir != null && runfilesDir.isNotEmpty) {
    for (final candidate in [
      '$runfilesDir/MANIFEST',
      '${runfilesDir}_manifest',
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
  }
  final exe = Platform.executable;
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
  final fromEnv = env['TEST_WORKSPACE'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  final slash = dillKey.indexOf('/');
  return slash > 0 ? dillKey.substring(0, slash) : null;
}

Map<String, String> _childRunfilesEnv(
  Map<String, String> env,
  String? manifest,
) {
  final out = <String, String>{};
  final runfilesDir = env['RUNFILES_DIR'];
  if (runfilesDir != null &&
      runfilesDir.isNotEmpty &&
      Directory(runfilesDir).existsSync()) {
    out['RUNFILES_DIR'] = Directory(runfilesDir).resolveSymbolicLinksSync();
  } else {
    final exe = Platform.executable;
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

bool _workspaceInPlace({
  String? testPath,
  String? manifest,
  String? workspace,
}) {
  if (testPath != null && !File(testPath).existsSync()) {
    return false;
  }
  if (manifest == null || workspace == null) {
    return true;
  }
  final prefix = '$workspace/';
  for (final line in File(manifest).readAsLinesSync()) {
    final space = line.indexOf(' ');
    if (space < 0 || !line.startsWith(prefix)) continue;
    final relative = line.substring(prefix.length, space);
    final real = line.substring(space + 1);
    if (Directory(real).existsSync()) {
      if (!Directory(relative).existsSync()) return false;
    } else if (File(real).existsSync()) {
      if (!File(relative).existsSync()) return false;
    }
  }
  return true;
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
  final prefix = '$workspace/';
  for (final line in manifest) {
    final space = line.indexOf(' ');
    if (space < 0 || !line.startsWith(prefix)) continue;
    final relative = line.substring(prefix.length, space);
    final real = line.substring(space + 1);
    final destination = _join(into, relative);
    if (Directory(real).existsSync()) {
      _copyDirectory(Directory(real), Directory(destination));
    } else if (File(real).existsSync()) {
      final destFile = File(destination);
      destFile.parent.createSync(recursive: true);
      if (destFile.existsSync()) {
        destFile.deleteSync();
      }
      File(real).copySync(destination);
    }
  }
}

void _copyDirectory(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync(recursive: true, followLinks: true)) {
    final relative = entity.path.substring(from.path.length + 1);
    final target = _join(to.path, relative.replaceAll(r'\', '/'));
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      final targetFile = File(target);
      targetFile.parent.createSync(recursive: true);
      if (targetFile.existsSync()) {
        targetFile.deleteSync();
      }
      entity.copySync(target);
    }
  }
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
    final event = decoded;
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
        final c = byId[id] ??= _Case(id);
        c
          ..hidden = event['hidden'] as bool? ?? false
          ..skipped = event['skipped'] as bool? ?? false
          ..result = event['result'] as String? ?? 'success'
          ..millis = (event['time'] as int) - (starts[id] ?? 0);
        cases.add(c);
    }
  }

  final shown = [
    for (final c in cases)
      if (!c.hidden || c.result != 'success') c,
  ];
  String seconds(int ms) => (ms / 1000).toStringAsFixed(3);
  final failures = shown.where((c) => c.result == 'failure').length;
  final errors = shown.where((c) => c.result == 'error').length;
  final skipped = shown.where((c) => c.skipped).length;
  final total = shown.fold<int>(0, (sum, c) => sum + c.millis);

  final out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<testsuites>')
    ..writeln(
      '  <testsuite name="${_attr(suiteName)}" tests="${shown.length}" '
      'failures="$failures" errors="$errors" skipped="$skipped" '
      'time="${seconds(total)}">',
    );
  for (final c in shown) {
    out.write(
      '    <testcase name="${_attr(names[c.id] ?? 'test ${c.id}')}" '
      'classname="${_attr(suiteName)}" time="${seconds(c.millis)}">',
    );
    if (c.skipped) {
      out.write('<skipped/>');
    } else if (c.result != 'success') {
      final tag = c.result == 'failure' ? 'failure' : 'error';
      final message = c.errors.isEmpty ? c.result : c.errors.first;
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
  out
    ..writeln('  </testsuite>')
    ..writeln('</testsuites>');
  return out.toString();
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

/// Joins a forward-slashed relative path onto [base], creating its parents.
String _join(String base, String relative) {
  final path = [base, ...relative.split('/')].join(Platform.pathSeparator);
  File(path).parent.createSync(recursive: true);
  return path;
}
