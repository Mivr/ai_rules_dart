/// Unit tests for `package:e2e_runner/spec.dart`.
library;

import 'dart:io';

import 'package:e2e_runner/spec.dart';
import 'package:test/test.dart';

Matcher _runnerError(String specPath, String commandName, String substring) =>
    isA<E2eRunnerException>()
        .having((e) => e.specPath, 'specPath', specPath)
        .having((e) => e.commandName, 'commandName', commandName)
        .having(
          (e) => e.toString(),
          'toString()',
          allOf(
            contains(specPath),
            contains(commandName),
            contains(substring),
          ),
        );

/// Entry point for spec parser unit tests.
void main() {
  _registerValidSpecTests();
  _registerSchemaAndCommandErrorTests();
  _registerForbiddenSyntaxTests();
  _registerFileLoadingErrorTests();
}

void _registerValidSpecTests() {
  group('parseE2eSpec valid specs', () {
    test('parses shorthand string and map commands with all fields', () {
      const yaml = '''
schema: mivr-e2e-spec/1
commands:
  - bazel build //:app
  - name: run tests
    run: 'bazel test //... --test_arg="hello world" --flaky_test_attempts=1'
    min_tests_executed: 5
    write_files:
      foo/bar.txt: "hello"
    replace_in_files:
      - path: MODULE.bazel
        from: old_val
        to: new_val
    expect:
      exit_code: 0
      stdout_contains: passed
      stderr_not_contains:
        - FATAL
      output_contains:
        - INFO
      output_not_contains: PANIC
      output_regex:
        - 'passed.*ok'
      test_log_contains: suite_ok
      test_xml_contains:
        - '<testsuite name="x"'
        - failures="0"
  - name: red check
    args:
      - query
      - '@bad//...'
    expect:
      non_zero: true
      stderr_contains:
        - Error in fail
''';
      final E2eSpec spec = parseE2eSpec(yaml, specPath: 'e2e/sample/e2e.yaml');
      expect(spec.specPath, 'e2e/sample/e2e.yaml');
      expect(spec.commands, hasLength(3));
      expect(spec.commands[0].name, 'bazel build //:app');
      expect(spec.commands[0].tokens, ['bazel', 'build', '//:app']);

      final CommandSpec second = spec.commands[1];
      expect(second.name, 'run tests');
      expect(second.minTestsExecuted, 5);
      expect(second.tokens, [
        'bazel',
        'test',
        '//...',
        '--test_arg=hello world',
        '--flaky_test_attempts=1',
      ]);
      expect(second.writeFiles.single.path, 'foo/bar.txt');
      expect(second.replaceInFiles.single.from, 'old_val');
      expect(second.expect.expectsZeroExit, isTrue);
      expect(second.expect.stdoutContains, ['passed']);
      expect(second.expect.testLogContains, ['suite_ok']);
      expect(second.expect.testXmlContains, [
        '<testsuite name="x"',
        'failures="0"',
      ]);

      final CommandSpec third = spec.commands[2];
      expect(third.expect.nonZero, isTrue);
      expect(third.expect.expectsZeroExit, isFalse);
      expect(third.expect.stderrContains, ['Error in fail']);
    });

    test('parses write_files in list-of-maps form', () {
      const yaml = '''
schema: mivr-e2e-spec/1
commands:
  - name: write list
    run: bazel build //:all
    write_files:
      - path: a.txt
        content: alpha
''';
      final E2eSpec spec = parseE2eSpec(yaml, specPath: 'e2e/w/e2e.yaml');
      expect(spec.commands.single.writeFiles.single.path, 'a.txt');
      expect(spec.commands.single.writeFiles.single.content, 'alpha');
    });
  });
}

void _registerSchemaAndCommandErrorTests() {
  group('parseE2eSpec structural errors name specPath and commandName', () {
    const path = 'e2e/broken/e2e.yaml';

    test('rejects unknown root key', () {
      const yaml = '''
schema: mivr-e2e-spec/1
unknown_root: 1
commands:
  - bazel build //:all
''';
      expect(
        () => parseE2eSpec(yaml, specPath: path),
        throwsA(_runnerError(path, '<spec>', 'unknown key "unknown_root"')),
      );
    });

    test('rejects wrong schema', () {
      const yaml = '''
schema: wrong/2
commands:
  - bazel build //:all
''';
      expect(
        () => parseE2eSpec(yaml, specPath: path),
        throwsA(_runnerError(path, '<spec>', 'expected schema')),
      );
    });

    test('rejects empty commands list', () {
      const yaml = '''
schema: mivr-e2e-spec/1
commands: []
''';
      expect(
        () => parseE2eSpec(yaml, specPath: path),
        throwsA(_runnerError(path, 'commands', 'non-empty list')),
      );
    });

    test('rejects unknown command key and names command', () {
      const yaml = '''
schema: mivr-e2e-spec/1
commands:
  - name: bad-step
    run: bazel build //:all
    bogus_field: true
''';
      expect(
        () => parseE2eSpec(yaml, specPath: path),
        throwsA(_runnerError(path, 'bad-step', 'unknown key "bogus_field"')),
      );
    });

    test('rejects command with neither run nor args', () {
      const yaml = '''
schema: mivr-e2e-spec/1
commands:
  - name: missing-exec
    min_tests_executed: 1
''';
      expect(
        () => parseE2eSpec(yaml, specPath: path),
        throwsA(_runnerError(path, 'missing-exec', 'either "run" or "args"')),
      );
    });

    test('rejects command with both run and args', () {
      const yaml = '''
schema: mivr-e2e-spec/1
commands:
  - name: dual-exec
    run: bazel build //:all
    args: [build, //:all]
''';
      expect(
        () => parseE2eSpec(yaml, specPath: path),
        throwsA(_runnerError(path, 'dual-exec', 'both "run" and "args"')),
      );
    });

    test('rejects unknown expect key', () {
      const yaml = '''
schema: mivr-e2e-spec/1
commands:
  - name: bad-expect
    run: bazel build //:all
    expect:
      not_a_key: foo
''';
      expect(
        () => parseE2eSpec(yaml, specPath: path),
        throwsA(_runnerError(path, 'bad-expect', 'unknown key "not_a_key"')),
      );
    });
  });
}

void _registerForbiddenSyntaxTests() {
  group('parseE2eSpec policy guards', () {
    const path = 'e2e/policy/e2e.yaml';

    test('rejects shell operators in run and args', () {
      for (final op in ['||', '&&', '|', ';']) {
        final yaml =
            '''
schema: mivr-e2e-spec/1
commands:
  - name: shell-cmd
    run: bazel test //... $op true
''';
        expect(
          () => parseE2eSpec(yaml, specPath: path),
          throwsA(_runnerError(path, 'shell-cmd', 'shell')),
        );
      }
      const argsYaml = '''
schema: mivr-e2e-spec/1
commands:
  - name: shell-args
    args: [test, //..., "||", "true"]
''';
      expect(
        () => parseE2eSpec(argsYaml, specPath: path),
        throwsA(_runnerError(path, 'shell-args', 'shell operator')),
      );
    });

    test('rejects --flaky_test_attempts above 1', () {
      const yaml = '''
schema: mivr-e2e-spec/1
commands:
  - name: flaky-step
    run: bazel test //... --flaky_test_attempts=2
''';
      expect(
        () => parseE2eSpec(yaml, specPath: path),
        throwsA(
          _runnerError(path, 'flaky-step', '--flaky_test_attempts'),
        ),
      );
    });

    test('rejects exit_code: 4 and min_tests_executed < 1', () {
      const exit4Yaml = '''
schema: mivr-e2e-spec/1
commands:
  - name: allow-4
    run: bazel test //...
    expect:
      exit_code: 4
''';
      expect(
        () => parseE2eSpec(exit4Yaml, specPath: path),
        throwsA(_runnerError(path, 'allow-4', 'exit_code: 4')),
      );

      const zeroFloorYaml = '''
schema: mivr-e2e-spec/1
commands:
  - name: zero-floor
    run: bazel test //...
    min_tests_executed: 0
''';
      expect(
        () => parseE2eSpec(zeroFloorYaml, specPath: path),
        throwsA(_runnerError(path, 'zero-floor', 'min_tests_executed')),
      );
    });
  });
}

void _registerFileLoadingErrorTests() {
  group('loadE2eSpec', () {
    test('fails naming spec path and <spec> when file is unreadable', () {
      final Directory tempDir = Directory.systemTemp.createTempSync(
        'spec_test_',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final missing = '${tempDir.path}/missing_e2e.yaml';
      expect(
        () => loadE2eSpec(missing),
        throwsA(_runnerError(missing, '<spec>', 'cannot read spec file')),
      );
    });
  });
}
