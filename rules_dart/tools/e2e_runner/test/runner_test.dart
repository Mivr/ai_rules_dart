import 'dart:io';

import 'package:e2e_runner/runner.dart';
import 'package:e2e_runner/spec.dart';
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

RunOutcome _outcome({
  int exitCode = 0,
  String stdout = '',
  String stderr = '',
  String testLog = '',
  String testXml = '',
  int executedTests = 0,
}) {
  return RunOutcome(
    exitCode: exitCode,
    stdout: stdout,
    stderr: stderr,
    testLog: testLog,
    testXml: testXml,
    executedTests: executedTests,
  );
}

void main(List<String> args) {
  group('resolveArgv', _testResolveArgv);
  group('isBazelCommand / isBazelTestCommand', _testCommandClassification);
  group('collectTestLogs', _testCollectTestLogs);
  group('checkExpectations', _testCheckExpectations);
  group('applyReplaceInFiles / expandWorkspacePlaceholders', _testPlaceholders);
  group('enforceTestFloor', _testEnforceTestFloor);
  group('runSpec', _testRunSpec);
  group('inner Bazel environment and tools pin', () => _testInnerBazel(args));
}

void _testResolveArgv() {
  test('rewrites a bazel command with output base and BEP', () {
    final argv = resolveArgv(
      ['bazel', 'test', '--test_output=errors', '//...'],
      client: 'bazel',
      outputBase: '/ob',
      bepPath: '/bep.json',
    );
    expect(argv, [
      'bazel',
      '--output_base=/ob',
      'test',
      '--test_output=errors',
      '//...',
      '--build_event_json_file=/bep.json',
    ]);
  });

  test('leaves non-bazel commands alone', () {
    expect(
      resolveArgv(
        ['./run.sh'],
        client: 'bazel',
        outputBase: '/ob',
        bepPath: '/bep.json',
      ),
      ['./run.sh'],
    );
  });

  test('does not add BEP for a bazel build command', () {
    final argv = resolveArgv(
      ['bazel', 'build', '//...'],
      client: 'bazel',
      outputBase: '/ob',
      bepPath: '/bep.json',
    );
    expect(argv, ['bazel', '--output_base=/ob', 'build', '//...']);
  });
}

void _testCommandClassification() {
  test('classifies commands including startup flags', () {
    expect(isBazelCommand(['bazel', 'build']), isTrue);
    expect(isBazelTestCommand(['bazel', 'test', '//...']), isTrue);
    expect(
      isBazelTestCommand(['bazel', '--max_idle_secs=60', 'test', '//...']),
      isTrue,
    );
    expect(isBazelTestCommand(['bazel', 'build']), isFalse);
    expect(isBazelCommand(['./run.sh']), isFalse);
  });
}

void _testCollectTestLogs() {
  test('records timeout marker when BEP reports TIMEOUT without footer', () {
    final dir = Directory.systemTemp.createTempSync('e2e_tlog_');
    try {
      final logFile = File('${dir.path}/test.log')
        ..writeAsStringSync('printed before hanging\n');
      final bep =
          '{"testResult":{"status":"TIMEOUT","testActionOutput":'
          '[{"name":"test.log","uri":"${Uri.file(logFile.path)}"}]}}\n';
      final logs = collectTestLogs(bep, dir.path, dir.path, needFallback: true);
      expect(logs, contains('printed before hanging'));
      expect(logs, contains('Test timed out'));
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}

void _testCheckExpectations() {
  _testCheckExpectationsExitCodes();
  _testCheckExpectationsOutputs();
}

void _testCheckExpectationsExitCodes() {
  test('passes an exit-0 outcome with no expect', () {
    expect(
      () => checkExpectations(_outcome(), null, 's', 'c'),
      returnsNormally,
    );
  });

  test('fails a non-zero outcome with no expect', () {
    expect(
      () => checkExpectations(_outcome(exitCode: 1), null, 's', 'c'),
      throwsStateError,
    );
  });

  test('rejects Bazel exit code 4 unconditionally even under non_zero', () {
    expect(
      () => checkExpectations(
        _outcome(exitCode: 4),
        const Expect(nonZero: true),
        's',
        'c',
      ),
      throwsStateError,
    );
    expect(
      () => checkExpectations(_outcome(exitCode: 4), null, 's', 'c'),
      throwsStateError,
    );
  });

  test('passes non_zero when the process fails', () {
    expect(
      () => checkExpectations(
        _outcome(exitCode: 1, stderr: 'boom'),
        const Expect(nonZero: true, required: OutputPatterns(stderr: ['boom'])),
        's',
        'c',
      ),
      returnsNormally,
    );
  });

  test('fails non_zero when the process exits 0', () {
    expect(
      () =>
          checkExpectations(_outcome(), const Expect(nonZero: true), 's', 'c'),
      throwsStateError,
    );
  });

  test('passes an exact exit_code', () {
    expect(
      () => checkExpectations(
        _outcome(exitCode: 3),
        const Expect(exitCode: 3),
        's',
        'c',
      ),
      returnsNormally,
    );
  });
}

void _testCheckExpectationsOutputs() {
  test('fails stderr_not_contains on a hit', () {
    expect(
      () => checkExpectations(
        _outcome(stderr: 'should not appear'),
        const Expect(forbidden: OutputPatterns(stderr: ['not appear'])),
        's',
        'c',
      ),
      throwsStateError,
    );
  });

  test('checks test_xml_contains', () {
    checkExpectations(
      _outcome(testXml: '<testcase name="greets"/>'),
      const Expect(testXmlContains: ['name="greets"']),
      's',
      'c',
    );
    expect(
      () => checkExpectations(
        _outcome(testXml: '<testcase name="other"/>'),
        const Expect(testXmlContains: ['name="greets"']),
        's',
        'c',
      ),
      throwsStateError,
    );
  });

  test('checks test_log_contains', () {
    expect(
      () => checkExpectations(
        _outcome(testLog: 'printed before hanging'),
        const Expect(testLogContains: ['before hanging']),
        's',
        'c',
      ),
      returnsNormally,
    );
  });
}

void _testPlaceholders() {
  test('expands workspace placeholders on POSIX and Windows paths', () {
    expect(
      expandWorkspacePlaceholders(
        r'file://${WORKSPACE}/fixtures',
        '/tmp/staged/ws',
      ),
      'file:///tmp/staged/ws/fixtures',
    );
    expect(
      expandWorkspacePlaceholders(
        r'file://${WORKSPACE}/fixtures',
        r'D:\tmp\staged\ws',
      ),
      'file:///D:/tmp/staged/ws/fixtures',
    );
  });

  test('throws naming spec path and command when target file is missing', () {
    final dir = Directory.systemTemp.createTempSync('e2e_repl_');
    try {
      const cmd = Command(
        name: 'mutate',
        argv: ['bazel', 'build', '//...'],
        replaceInFiles: {
          'missing.lock': [Replacement(find: 'A', replace: 'B')],
        },
      );
      expect(
        () => applyReplaceInFiles(cmd, dir.path, 'e2e/foo/e2e.yaml'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('e2e/foo/e2e.yaml'), contains('mutate')),
          ),
        ),
      );
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}

void _testEnforceTestFloor() {
  test('passes when executed meets the floor', () {
    expect(() => enforceTestFloor(3, 3, 's', 'c'), returnsNormally);
    expect(() => enforceTestFloor(1, null, 's', 'c'), returnsNormally);
  });

  test('fails when executed is below the floor', () {
    expect(() => enforceTestFloor(0, 1, 's', 'c'), throwsStateError);
    expect(() => enforceTestFloor(2, 3, 's', 'c'), throwsStateError);
  });
}

void _testRunSpec() {
  _testRunSpecSelection();
  _testRunSpecStaging();
}

void _testRunSpecSelection() {
  test('runs only the commands --command selected, in spec order', () {
    final tmp = Directory.systemTemp.createTempSync('e2e_select_');
    try {
      final (:repo, :ws) = _createSampleWorkspace(tmp.path);
      File('${ws.path}/note.txt').writeAsStringSync('STAGED');
      final logFile = File('${tmp.path}/calls.log');
      final fakeBazel = _writeFakeBazel(tmp.path, logFile.path);
      final specPath = '${ws.path}/e2e.yaml';
      final spec = selectCommands(
        parseSpec(
          'schema: mivr-e2e-spec/1\n'
          'commands:\n'
          '  - name: first\n'
          '    run: bazel build //first\n'
          '  - name: second\n'
          '    run: bazel build //second\n'
          '  - name: third\n'
          '    run: bazel build //third\n',
          specPath: specPath,
        ),
        ['third', 'first'],
        specPath: specPath,
      );
      final rc = runSpec(
        RunnerConfig(
          workspaceDir: ws.path,
          repoRoot: repo.path,
          client: fakeBazel,
          specPath: specPath,
          spec: spec,
        ),
      );
      final calls = logFile.readAsStringSync();
      expect(calls, contains('//first'));
      expect(calls, contains('//third'));
      expect(calls, isNot(contains('//second')));
      expect(calls.indexOf('//first'), lessThan(calls.indexOf('//third')));
      expect(rc, 0);
    } finally {
      tmp.deleteSync(recursive: true);
    }
  }, skip: Platform.isWindows ? 'fake client is a POSIX shell script' : false);
}

void _testRunSpecStaging() {
  test('stages workspace, leaves source untouched, and runs shutdown', () {
    final tmp = Directory.systemTemp.createTempSync('e2e_runspec_');
    try {
      final (:repo, :ws) = _createSampleWorkspace(
        tmp.path,
        writeRootVersion: true,
      );
      File('${ws.path}/note.txt').writeAsStringSync('ORIG');
      final logFile = File('${tmp.path}/calls.log');
      final fakeBazel = _writeFakeBazel(tmp.path, logFile.path);
      final spec = parseSpec(
        'schema: mivr-e2e-spec/1\n'
        'commands:\n'
        '  - name: green\n'
        '    run: bazel test //...\n'
        '    replace_in_files:\n'
        '      note.txt:\n'
        '        - find: ORIG\n'
        '          replace: STAGED\n'
        '  - name: zero_tests\n'
        '    run: bazel test //empty\n',
        specPath: '${ws.path}/e2e.yaml',
      );
      final rc = runSpec(
        RunnerConfig(
          workspaceDir: ws.path,
          repoRoot: repo.path,
          client: fakeBazel,
          specPath: '${ws.path}/e2e.yaml',
          spec: spec,
        ),
      );
      expect(rc, 1);
      expect(File('${ws.path}/note.txt').readAsStringSync(), 'ORIG');
      expect(logFile.readAsStringSync(), contains('shutdown'));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}

void _testInnerBazel(List<String> args) {
  _testInnerDropsLaunchingDir(args);
  _testInnerKeepsCleanEnv(args);
  _testToolsBazelversion(args);
}

void _testInnerDropsLaunchingDir(List<String> args) {
  test('removes launching Bazel directory from PATH for inner calls', () {
    final tmp = Directory.systemTemp.createTempSync('e2e_inner_drop_');
    try {
      final ws = _stageSampleVersionWorkspace(tmp.path);
      final wrongLog = File('${tmp.path}/wrong_bazel.log');
      final envDump = File('${tmp.path}/inner_env.txt');
      final casLaunchDir =
          '${tmp.path}/cache/bazelisk/downloads/sha256/${'a' * 64}/bin';
      final customHome = '${tmp.path}/custom_bz_home';
      final customLaunchDir =
          '$customHome/downloads/bazelbuild/bazel-9.3.0/bin';
      final localLaunchDir = '${tmp.path}/cache/bazelisk/local/dev/bin';
      for (final dir in [casLaunchDir, customLaunchDir, localLaunchDir]) {
        _writeLaunchingBazel(dir, wrongLog.path);
      }
      final wrapperDir = '${tmp.path}/wrapper/bin';
      _writeWrapperBazel(wrapperDir, envDump.path);
      final sep = Platform.isWindows ? ';' : ':';
      final cleanTail = _cleanSystemPathEntries();
      final expectedPath = [wrapperDir, ...cleanTail].join(sep);
      final inputPath = [
        casLaunchDir,
        customLaunchDir,
        localLaunchDir,
        wrapperDir,
        ...cleanTail,
      ].join(sep);
      final env = _buildEnvWithPath(
        inputPath,
        extra: {'BAZELISK_HOME': customHome, 'CUSTOM_VAR': 'kept_value'},
      );
      final dumped = _runSampleUnderEnv(args, ws, envDump, env);
      expect(wrongLog.existsSync(), isFalse);
      expect(dumped, contains('PATH=$expectedPath'));
      expect(dumped, contains('CUSTOM_VAR=kept_value'));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}

void _testInnerKeepsCleanEnv(List<String> args) {
  test('leaves environment unchanged when launching Bazel dir is absent', () {
    final tmp = Directory.systemTemp.createTempSync('e2e_inner_keep_');
    try {
      final ws = _stageSampleVersionWorkspace(tmp.path);
      final envDump = File('${tmp.path}/inner_env.txt');
      final wrapperDir = '${tmp.path}/wrapper/bin';
      _writeWrapperBazel(wrapperDir, envDump.path);
      final toolcacheDir = '${tmp.path}/hostedtoolcache/bazelisk/1.25.0/x64';
      Directory(toolcacheDir).createSync(recursive: true);
      final sep = Platform.isWindows ? ';' : ':';
      final expectedPath = [
        wrapperDir,
        toolcacheDir,
        ..._cleanSystemPathEntries(),
      ].join(sep);
      final env = _buildEnvWithPath(
        expectedPath,
        extra: {'CUSTOM_VAR': 'unchanged_marker'},
      );
      final dumped = _runSampleUnderEnv(args, ws, envDump, env);
      expect(dumped, contains('PATH=$expectedPath'));
      expect(dumped, contains('CUSTOM_VAR=unchanged_marker'));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}

void _testToolsBazelversion(List<String> args) {
  test('tools/.bazelversion equals the root .bazelversion', () {
    final root = _repoRoot(args);
    final rootVersion = File('$root/.bazelversion');
    final toolsVersion = File('$root/tools/.bazelversion');
    expect(rootVersion.existsSync(), isTrue);
    expect(
      toolsVersion.existsSync(),
      isTrue,
      reason: 'tools/.bazelversion must exist',
    );
    final expected = rootVersion.readAsStringSync();
    expect(expected.trim(), isNotEmpty);
    expect(toolsVersion.readAsStringSync(), expected);
  });
}

({Directory repo, Directory ws}) _createSampleWorkspace(
  String baseDir, {
  bool writeRootVersion = false,
}) {
  final repo = Directory('$baseDir/repo')..createSync(recursive: true);
  if (writeRootVersion) {
    File('${repo.path}/.bazelversion').writeAsStringSync('9.3.0\n');
  }
  final ws = Directory('${repo.path}/e2e/sample')..createSync(recursive: true);
  File('${ws.path}/MODULE.bazel').writeAsStringSync(
    'local_path_override(module_name = "ai_rules_dart", path = "../..")\n',
  );
  return (repo: repo, ws: ws);
}

List<String> _runSampleUnderEnv(
  List<String> args,
  String ws,
  File envDump,
  Map<String, String> env,
) {
  final result = Process.runSync(
    _e2eRunnerBinary(args),
    ['--workspace=$ws', '--bazel=bazel'],
    environment: env,
    includeParentEnvironment: false,
  );
  expect(
    result.exitCode,
    0,
    reason: 'runner failed:\n${result.stdout}\n${result.stderr}',
  );
  return envDump.readAsLinesSync();
}

String _stageSampleVersionWorkspace(String baseDir) {
  final (:ws, repo: _) = _createSampleWorkspace(
    baseDir,
    writeRootVersion: true,
  );
  File('${ws.path}/.bazelversion').writeAsStringSync('9.0.0\n');
  File('${ws.path}/e2e.yaml').writeAsStringSync(
    'schema: mivr-e2e-spec/1\n'
    'commands:\n'
    '  - name: bazel version\n'
    '    run: bazel version\n'
    '    expect:\n'
    '      stdout_contains: "Build label: 9.0.0"\n'
    '      output_regex: \'^Build label: 9\\.0\\.0\\r?\$\'\n',
  );
  return ws.path;
}

List<String> _cleanSystemPathEntries() {
  final sep = Platform.isWindows ? ';' : ':';
  final raw =
      Platform.environment['PATH'] ?? Platform.environment['Path'] ?? '';
  return raw
      .split(sep)
      .where(
        (e) =>
            e.isNotEmpty &&
            !e.toLowerCase().contains('bazelisk') &&
            !e.toLowerCase().contains('downloads'),
      )
      .toList();
}

Map<String, String> _buildEnvWithPath(
  String pathValue, {
  required Map<String, String> extra,
}) {
  final env = <String, String>{};
  var wrotePath = false;
  Platform.environment.forEach((key, value) {
    final upper = key.toUpperCase();
    if (upper == 'BAZELISK_HOME' || upper == 'BAZELISK_SKIP_WRAPPER') return;
    if (upper == 'PATH') {
      if (!wrotePath) {
        env[key] = pathValue;
        wrotePath = true;
      }
      return;
    }
    env[key] = value;
  });
  if (!wrotePath) env['PATH'] = pathValue;
  env.addAll(extra);
  return env;
}

void _writeLaunchingBazel(String dir, String markerLog) {
  Directory(dir).createSync(recursive: true);
  if (Platform.isWindows) {
    File('$dir/bazel.bat').writeAsStringSync(
      '@echo launched>>"$markerLog"\r\n'
      '@echo Build label: 9.3.0\r\n'
      '@exit /b 0\r\n',
    );
    return;
  }
  final script = File('$dir/bazel')
    ..writeAsStringSync(
      '#!/bin/sh\n'
      'echo launched >> "$markerLog"\n'
      'echo "Build label: 9.3.0"\n',
    );
  Process.runSync('chmod', ['+x', script.path]);
}

void _writeWrapperBazel(String dir, String envDumpPath) {
  Directory(dir).createSync(recursive: true);
  if (Platform.isWindows) {
    File('$dir/bazel.bat').writeAsStringSync(
      '@echo off\r\n'
      'echo %* | findstr /C:"shutdown" >nul && exit /b 0\r\n'
      '(\r\n'
      '  echo PATH=%PATH%\r\n'
      '  echo CUSTOM_VAR=%CUSTOM_VAR%\r\n'
      ')>"$envDumpPath"\r\n'
      'set /p VER=<.bazelversion\r\n'
      'echo Build label: %VER%\r\n'
      'exit /b 0\r\n',
    );
    return;
  }
  final script = File('$dir/bazel')
    ..writeAsStringSync(
      '#!/bin/sh\n'
      'case "\$*" in\n'
      '  *shutdown*) exit 0 ;;\n'
      'esac\n'
      'printf "PATH=%s\\nCUSTOM_VAR=%s\\n" "\$PATH" "\${CUSTOM_VAR:-}" > "$envDumpPath"\n'
      'ver="\$(cat .bazelversion)"\n'
      'printf "Build label: %s\\n" "\$ver"\n',
    );
  Process.runSync('chmod', ['+x', script.path]);
}

String _e2eRunnerBinary(List<String> args) {
  if (args.length < 2) {
    throw StateError('expected e2e_runner rlocationpath as second arg');
  }
  final mapped = Runfiles.create().rlocation(args[1]);
  return File(mapped).resolveSymbolicLinksSync();
}

String _repoRoot(List<String> args) {
  if (args.isNotEmpty) {
    final mapped = Runfiles.create().rlocation(args.first);
    final resolved = File(mapped).resolveSymbolicLinksSync();
    var dir = File(resolved).parent;
    while (true) {
      if (File('${dir.path}/MODULE.bazel').existsSync() &&
          Directory('${dir.path}/dart').existsSync()) {
        return dir.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
  throw StateError('cannot locate rules_dart repository root');
}

String _writeFakeBazel(String dir, String logPath) {
  if (Platform.isWindows) {
    final bat = File('$dir/fake_bazel.bat')
      ..writeAsStringSync('@echo shutdown>>"$logPath"\r\n@exit /b 4\r\n');
    return bat.path;
  }
  final script = File('$dir/fake_bazel.sh')
    ..writeAsStringSync('''#!/bin/sh
echo "\$*" >> "$logPath"
case "\$*" in
  *shutdown*) exit 0 ;;
  *//empty*) exit 0 ;;
  *)
    for arg in "\$@"; do
      case "\$arg" in
        --build_event_json_file=*)
          bep="\${arg#--build_event_json_file=}"
          xml="$dir/ok_test.xml"
          printf '<testsuite><testcase name="t"/></testsuite>' > "\$xml"
          printf '{"id":{"testResult":{"label":"//:t"}},"testResult":{"testActionOutput":[{"name":"test.xml","uri":"file://%s"}]}}\\n' "\$xml" > "\$bep"
          ;;
      esac
    done
    grep -q STAGED note.txt && grep -q "${dir.replaceAll('"', '')}/repo" MODULE.bazel
    ;;
esac
''');
  Process.runSync('chmod', ['+x', script.path]);
  return script.path;
}
