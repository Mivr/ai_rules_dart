import 'dart:io';

import 'package:e2e_runner/runner.dart';
import 'package:e2e_runner/spec.dart';
import 'package:test/test.dart';

RunOutcome _outcome({
  int exitCode = 0,
  String stdout = '',
  String stderr = '',
  String testLog = '',
  int executedTests = 0,
}) {
  return RunOutcome(
    exitCode: exitCode,
    stdout: stdout,
    stderr: stderr,
    testLog: testLog,
    executedTests: executedTests,
  );
}

void main() {
  group('resolveArgv', () {
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
  });

  group('isBazelCommand / isBazelTestCommand', () {
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

    test('identifies POSIX-only sandbox flags', () {
      expect(
        requiresPosixSandbox([
          'bazel',
          'test',
          '--strategy=DartAnalyze=sandboxed',
          '//...',
        ]),
        isTrue,
      );
      expect(
        requiresPosixSandbox(['bazel', 'test', '--worker_sandboxing', '//...']),
        isTrue,
      );
      expect(
        requiresPosixSandbox([
          'bazel',
          'test',
          '--spawn_strategy=standalone',
          '//...',
        ]),
        isFalse,
      );
    });
  });

  group('collectTestLogs', () {
    test('records timeout marker when BEP reports TIMEOUT without footer', () {
      final dir = Directory.systemTemp.createTempSync('e2e_tlog_');
      try {
        final logFile = File('${dir.path}/test.log')
          ..writeAsStringSync('printed before hanging\n');
        final bep =
            '{"testResult":{"status":"TIMEOUT","testActionOutput":'
            '[{"name":"test.log","uri":"${Uri.file(logFile.path)}"}]}}\n';
        final logs = collectTestLogs(
          bep,
          dir.path,
          dir.path,
          needFallback: true,
        );
        expect(logs, contains('printed before hanging'));
        expect(logs, contains('Test timed out'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('checkExpectations', () {
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
          const Expect(
            nonZero: true,
            required: OutputPatterns(stderr: ['boom']),
          ),
          's',
          'c',
        ),
        returnsNormally,
      );
    });

    test('fails non_zero when the process exits 0', () {
      expect(
        () => checkExpectations(
          _outcome(),
          const Expect(nonZero: true),
          's',
          'c',
        ),
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
  });

  group('applyReplaceInFiles / expandWorkspacePlaceholders', () {
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
  });

  group('enforceTestFloor', () {
    test('passes when executed meets the floor', () {
      expect(() => enforceTestFloor(3, 3, 's', 'c'), returnsNormally);
      expect(() => enforceTestFloor(1, null, 's', 'c'), returnsNormally);
    });

    test('fails when executed is below the floor', () {
      expect(() => enforceTestFloor(0, 1, 's', 'c'), throwsStateError);
      expect(() => enforceTestFloor(2, 3, 's', 'c'), throwsStateError);
    });
  });

  group('runSpec', () {
    test('stages workspace, leaves source untouched, and runs shutdown', () {
      final tmp = Directory.systemTemp.createTempSync('e2e_runspec_');
      try {
        final repo = Directory('${tmp.path}/repo')..createSync();
        File('${repo.path}/.bazelversion').writeAsStringSync('9.3.0\n');
        final ws = Directory('${repo.path}/e2e/sample')
          ..createSync(recursive: true);
        File('${ws.path}/MODULE.bazel').writeAsStringSync(
          'local_path_override(module_name = "ai_rules_dart", path = "../..")\n',
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
  });
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
