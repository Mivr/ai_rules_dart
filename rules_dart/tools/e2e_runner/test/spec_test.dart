import 'package:e2e_runner/spec.dart';
import 'package:test/test.dart';

void main() {
  group('parseSpec', () {
    test('parses a shorthand string command', () {
      final spec = parseSpec(
        'schema: mivr-e2e-spec/1\n'
        'commands:\n'
        '  - bazel build //...\n',
        specPath: 'e2e/hello_world/e2e.yaml',
      );
      expect(spec.commands, hasLength(1));
      expect(spec.commands.single.argv, ['bazel', 'build', '//...']);
    });

    test('parses a run command with a name and min_tests_executed', () {
      final spec = parseSpec(
        'schema: mivr-e2e-spec/1\n'
        'commands:\n'
        '  - name: test\n'
        '    run: bazel test --test_output=errors //...\n'
        '    min_tests_executed: 3\n',
        specPath: 's',
      );
      final command = spec.commands.single;
      expect(command.name, 'test');
      expect(command.argv, ['bazel', 'test', '--test_output=errors', '//...']);
      expect(command.minTestsExecuted, 3);
    });

    test('parses an args command and scalar or list expect blocks', () {
      final spec = parseSpec(
        'schema: mivr-e2e-spec/1\n'
        'commands:\n'
        '  - name: fail\n'
        '    args: [bazel, build, //:bad]\n'
        '    expect:\n'
        '      non_zero: true\n'
        '      stderr_contains: "boom"\n'
        '      output_contains:\n'
        '        - "one"\n'
        '        - "two"\n',
        specPath: 's',
      );
      final command = spec.commands.single;
      expect(command.argv, ['bazel', 'build', '//:bad']);
      expect(command.expect!.nonZero, isTrue);
      expect(command.expect!.stderrContains, ['boom']);
      expect(command.expect!.outputContains, ['one', 'two']);
    });

    test('parses write_files and replace_in_files', () {
      final spec = parseSpec(
        'schema: mivr-e2e-spec/1\n'
        'commands:\n'
        '  - run: ./script.sh\n'
        '    write_files:\n'
        '      a.txt: hello\n'
        '    replace_in_files:\n'
        '      b.txt:\n'
        '        - find: OLD\n'
        '          replace: NEW\n',
        specPath: 's',
      );
      final command = spec.commands.single;
      expect(command.writeFiles['a.txt'], 'hello');
      expect(command.replaceInFiles['b.txt']!.single.find, 'OLD');
      expect(command.replaceInFiles['b.txt']!.single.replace, 'NEW');
    });

    test('rejects an unknown top-level key', () {
      expect(
        () => parseSpec(
          'schema: mivr-e2e-spec/1\n'
          'commands:\n  - bazel build //...\n'
          'bogus: true\n',
          specPath: 's',
        ),
        throwsA(isA<SpecError>()),
      );
    });

    test('rejects an unknown command key and names the command name', () {
      try {
        parseSpec(
          'schema: mivr-e2e-spec/1\n'
          'commands:\n'
          '  - name: my_custom_command\n'
          '    run: bazel build //...\n'
          '    bogus: true\n',
          specPath: 'e2e/test/e2e.yaml',
        );
        fail('expected SpecError');
      } on SpecError catch (e) {
        expect(e.message, contains('e2e/test/e2e.yaml'));
        expect(e.message, contains('my_custom_command'));
        expect(e.message, contains('bogus'));
      }
    });

    test('rejects exit_code 4, min_tests_executed < 1, and flaky attempts', () {
      expect(
        () => parseSpec(
          'schema: mivr-e2e-spec/1\n'
          'commands:\n'
          '  - name: no_targets\n'
          '    run: bazel test //...\n'
          '    expect:\n'
          '      exit_code: 4\n',
          specPath: 'e2e/x/e2e.yaml',
        ),
        throwsA(isA<SpecError>()),
      );
      expect(
        () => parseSpec(
          'schema: mivr-e2e-spec/1\n'
          'commands:\n'
          '  - name: zero_floor\n'
          '    run: bazel test //...\n'
          '    min_tests_executed: 0\n',
          specPath: 'e2e/x/e2e.yaml',
        ),
        throwsA(isA<SpecError>()),
      );
      expect(
        () => parseSpec(
          'schema: mivr-e2e-spec/1\n'
          'commands:\n'
          '  - run: bazel test --flaky_test_attempts=2 //...\n',
          specPath: 'e2e/x/e2e.yaml',
        ),
        throwsA(isA<SpecError>()),
      );
    });

    test('rejects an empty commands list', () {
      expect(
        () =>
            parseSpec('schema: mivr-e2e-spec/1\ncommands: []\n', specPath: 's'),
        throwsA(isA<SpecError>()),
      );
    });

    test('rejects a command with neither run nor args', () {
      expect(
        () => parseSpec(
          'schema: mivr-e2e-spec/1\n'
          'commands:\n'
          '  - name: nothing\n',
          specPath: 's',
        ),
        throwsA(isA<SpecError>()),
      );
    });

    test('rejects a command with both run and args', () {
      expect(
        () => parseSpec(
          'schema: mivr-e2e-spec/1\n'
          'commands:\n'
          '  - run: bazel build //...\n'
          '    args: [bazel, build, //...]\n',
          specPath: 's',
        ),
        throwsA(isA<SpecError>()),
      );
    });

    test('rejects a wrong schema', () {
      expect(
        () => parseSpec(
          'schema: other/1\ncommands:\n  - bazel build //...\n',
          specPath: 's',
        ),
        throwsA(isA<SpecError>()),
      );
    });

    test('rejects invalid YAML', () {
      expect(
        () => parseSpec('schema: [unclosed', specPath: 's'),
        throwsA(isA<SpecError>()),
      );
    });

    test('names the spec path and command in the error', () {
      try {
        parseSpec(
          'schema: mivr-e2e-spec/1\n'
          'commands:\n'
          '  - name: nothing\n',
          specPath: 'e2e/x/e2e.yaml',
        );
        fail('expected SpecError');
      } on SpecError catch (e) {
        expect(e.message, contains('e2e/x/e2e.yaml'));
        expect(e.message, contains('nothing'));
      }
    });
  });

  group('splitRun', () {
    test('splits on whitespace and respects quotes', () {
      expect(splitRun('bazel test //...'), ['bazel', 'test', '//...']);
      expect(splitRun('  ./run.sh  '), ['./run.sh']);
      expect(splitRun('bazel query "tests(//...)"'), [
        'bazel',
        'query',
        'tests(//...)',
      ]);
    });

    test('rejects an empty string and shell syntax', () {
      expect(() => splitRun('   '), throwsA(isA<SpecError>()));
      expect(
        () => splitRun('bazel test //... || true'),
        throwsA(isA<SpecError>()),
      );
      expect(
        () => splitRun('bazel build //... && echo ok'),
        throwsA(isA<SpecError>()),
      );
      expect(
        () => splitRun('bazel build //... ; ls'),
        throwsA(isA<SpecError>()),
      );
    });
  });

  group('selectCommands', () {
    const yaml =
        'schema: mivr-e2e-spec/1\n'
        'commands:\n'
        '  - name: a\n'
        '    run: bazel build //a\n'
        '  - name: b\n'
        '    run: bazel build //b\n';

    test('keeps spec order regardless of filter order', () {
      final spec = parseSpec(yaml, specPath: 'e2e/x/e2e.yaml');
      final picked = selectCommands(spec, ['b', 'a'], specPath: 'p');
      expect(picked.commands.map((c) => c.name), ['a', 'b']);
      expect(
        selectCommands(spec, ['b'], specPath: 'p').commands.single.name,
        'b',
      );
    });

    test('fails closed on an empty filter or an unknown name', () {
      final spec = parseSpec(yaml, specPath: 'e2e/x/e2e.yaml');
      expect(
        () => selectCommands(spec, [], specPath: 'e2e/x/e2e.yaml'),
        throwsA(isA<SpecError>()),
      );
      expect(
        () => selectCommands(spec, [''], specPath: 'e2e/x/e2e.yaml'),
        throwsA(isA<SpecError>()),
      );
      expect(
        () => selectCommands(spec, ['nope'], specPath: 'e2e/x/e2e.yaml'),
        throwsA(
          isA<SpecError>().having(
            (e) => e.message,
            'message',
            allOf(contains('e2e/x/e2e.yaml'), contains('nope')),
          ),
        ),
      );
    });
  });

  test('parses test_xml_contains', () {
    final spec = parseSpec(
      'schema: mivr-e2e-spec/1\n'
      'commands:\n'
      '  - name: t\n'
      '    run: bazel test //...\n'
      '    expect:\n'
      '      test_xml_contains: greets\n',
      specPath: 'p',
    );
    expect(spec.commands.single.expect!.testXmlContains, ['greets']);
  });
}
