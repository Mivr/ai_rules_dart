// Tests for the staged project lint options helpers shared by
// `analyze_runner` and `fix_runner`.
import 'dart:io';

import 'package:test/test.dart';

import 'project_lint_options.dart';
import 'staged_project_copy.dart';

/// A staged tree with a symlinked options file enabling a project lint rule.
({Directory project, File target}) stageOptionsProject(Directory tmp) {
  final project = Directory('${tmp.path}/demo.proj')..createSync();
  Directory('${project.path}/src/lib').createSync(recursive: true);
  Directory('${project.path}/.dart_tool').createSync(recursive: true);
  File('${project.path}/.dart_tool/package_config.json')
      .writeAsStringSync('{"configVersion": 2, "packages": []}');
  File('${project.path}/src/lib/a.dart').writeAsStringSync('int a() => 1;\n');
  final target = File('${tmp.path}/real_options.yaml')
    ..writeAsStringSync(
      'linter:\n  rules:\n    no_stdout_in_worker: true\n    avoid_print: true\n',
    );
  Link('${project.path}/src/analysis_options.yaml').createSync(target.path);
  return (project: project, target: target);
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('project_lint_options_test_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  _defineSyntaxTests();
  _defineStagingTests(() => tmp);
}

void _defineSyntaxTests() {
  group('projectOptionsContainLintKeys', () {
    test('detects each project lint rule key in map and list syntax', () {
      for (final String key in projectLintRuleKeys) {
        expect(
          projectOptionsContainLintKeys('linter:\n  rules:\n    $key: true\n'),
          isTrue,
        );
        expect(
          projectOptionsContainLintKeys(
            'linter:\r\n  rules:\r\n    - $key\r\n',
          ),
          isTrue,
        );
      }
    });

    test('ignores other rules, comments, and values', () {
      expect(
        projectOptionsContainLintKeys(
          'linter:\n  rules:\n    avoid_print: true\n',
        ),
        isFalse,
      );
      expect(
        projectOptionsContainLintKeys('# no_stdout_in_worker: true\n'),
        isFalse,
      );
      expect(
        projectOptionsContainLintKeys('# - no_stdout_in_worker\n'),
        isFalse,
      );
      expect(projectOptionsContainLintKeys(''), isFalse);
    });
  });

  group('stripProjectLintKeys', () {
    test('removes map and list keys and keeps emptied errors valid', () {
      const options =
          '# header\n'
          'analyzer:\n'
          '  errors:\n'
          '    no_stdout_in_worker: ignore\n'
          'linter:\n'
          '  rules:\n'
          '    - no_home_env_reads # custom\n'
          '    - avoid_print\n'
          '    process_requires_environment: false\n';
      expect(
        stripProjectLintKeys(options),
        '# header\n'
        'analyzer:\n'
        '  errors: {}\n'
        'linter:\n'
        '  rules:\n'
        '    - avoid_print\n',
      );
    });

    test('leaves key-free options byte-identical', () {
      const options = 'linter:\n  rules:\n    avoid_print: true\n';
      expect(stripProjectLintKeys(options), options);
    });
  });
}

void _defineStagingTests(Directory Function() currentTmp) {
  group('findStagedProjectLintOptions', () {
    test('finds symlinked options without mutating the target', () {
      final ({Directory project, File target}) staged = stageOptionsProject(
        currentTmp(),
      );
      final Set<String> found = findStagedProjectLintOptions(
        staged.project.path,
      );
      expect(found, {'src/analysis_options.yaml'});
      expect(
        staged.target.readAsStringSync(),
        contains('no_stdout_in_worker: true'),
      );
    });

    test('returns empty when no keys are enabled', () {
      final project = Directory('${currentTmp().path}/empty.proj')
        ..createSync();
      Directory('${project.path}/src').createSync(recursive: true);
      File('${project.path}/src/analysis_options.yaml')
          .writeAsStringSync('linter:\n  rules:\n    avoid_print: true\n');
      expect(findStagedProjectLintOptions(project.path), isEmpty);
    });
  });

  group('stripStagedProjectLintOptions', () {
    test('strips scratch copies and leaves linked targets alone', () {
      final ({Directory project, File target}) staged = stageOptionsProject(
        currentTmp(),
      );
      final scratch = Directory('${currentTmp().path}/scratch')
        ..createSync(recursive: true);
      copyStagedTree(
        staged.project.path,
        scratch.path,
        projectRoot: staged.project.path,
      );
      final Set<String> stripped = stripStagedProjectLintOptions(scratch.path);
      expect(stripped, {'src/analysis_options.yaml'});
      expect(
        File('${scratch.path}/src/analysis_options.yaml').readAsStringSync(),
        isNot(contains('no_stdout_in_worker')),
      );
      expect(
        File('${scratch.path}/src/analysis_options.yaml').readAsStringSync(),
        contains('avoid_print'),
      );
      // The read-only target behind the symlink is untouched.
      expect(
        staged.target.readAsStringSync(),
        contains('no_stdout_in_worker: true'),
      );
    });
  });

  group('copyStagedTree', () {
    test('copies contents and skips unlisted src entries', () {
      final from = Directory('${currentTmp().path}/from')..createSync();
      Directory('${from.path}/src/lib').createSync(recursive: true);
      File('${from.path}/src/lib/a.dart').writeAsStringSync('int a() => 1;\n');
      File('${from.path}/src/lib/b.dart').writeAsStringSync('int b() => 2;\n');
      final to = '${currentTmp().path}/to';
      copyStagedTree(
        from.path,
        to,
        projectRoot: from.path,
        allowedSrcPaths: {'src/lib/a.dart'},
      );
      expect(File('$to/src/lib/a.dart').existsSync(), isTrue);
      expect(File('$to/src/lib/b.dart').existsSync(), isFalse);
    });
  });
}
