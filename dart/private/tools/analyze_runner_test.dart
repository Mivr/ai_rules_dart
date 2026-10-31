import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'analysis_baseline.dart'
    show
        AnalysisBaseline,
        BaselineException,
        BaselineReport,
        baselineFailureLine;
import 'analyze_runner.dart' as analyze_runner;
import 'analyze_runner_test_support.dart'
    show defineRunnerSubprocessBaselineTests;

/// The `analyze_runner`'s staged-source check refuses directives that would
/// read undeclared host files before `dart analyze` runs.
///
/// The runner is driven as a subprocess (it exits rather than returning), so
/// this test takes the built runner's runfiles path as its argument. The
/// refusal lands before any `dart` invocation, so `--dart` never runs.
void main(List<String> args) {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('analyze_runner_test_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('refuses a triple-quoted import before analyzing', () {
    if (args.isEmpty) return;
    // A multi-line first line the guard keeps but the front end drops would
    // read an undeclared host file through the analyzer's working directory.
    final runner = Runfiles.create().rlocation(args[0]);
    final project = Directory('${tmp.path}/demo.proj')
      ..createSync(recursive: true);
    Directory('${project.path}/src/pkg').createSync(recursive: true);
    File('${project.path}/src/pkg/main.dart').writeAsStringSync(
      "import '''   \n/secret/s.dart''';\n"
      'void main() => print(hostSecret);\n',
    );
    File('${project.path}/src/pkg/ok.dart')
        .writeAsStringSync('const ok = 1;\n');
    final stamp = File('${tmp.path}/analyzed.txt');
    final res = Process.runSync(Platform.resolvedExecutable, [
      runner,
      '--dart',
      'never-reached-dart',
      '--project',
      project.path,
      '--stamp',
      stamp.path,
      '--source',
      'src/pkg/main.dart',
    ]);
    expect(res.exitCode, isNonZero);
    expect(
      res.stderr as String,
      contains("import '   \n/secret/s.dart' is not a declared input"),
    );
    expect(stamp.existsSync(), isFalse);
  });

  _definePruneTests(() => tmp);
  _defineRunnerVerdictUnitTests();
  defineRunnerSubprocessBaselineTests(args, () => tmp);
}

void _definePruneTests(Directory Function() currentTmp) {
  group('pruneOrphanedStagedFiles', () {
    Directory stageSrc(String name) {
      final project = Directory('${currentTmp().path}/$name.proj')
        ..createSync(recursive: true);
      Directory('${project.path}/src/pkg').createSync(recursive: true);
      Directory('${project.path}/.dart_tool').createSync(recursive: true);
      return project;
    }

    void writeSrcManifest(Directory project, List<String> lines) {
      File('${project.path}/.dart_tool/src_manifest.txt')
          .writeAsStringSync("${lines.join('\n')}\n");
    }

    test('keys the allow-list src-relative and deletes unlisted files', () {
      final project = stageSrc('demo');
      File('${project.path}/src/pkg/keep.dart')
          .writeAsStringSync('const keep = 1;\n');
      File('${project.path}/src/pkg/drop.dart')
          .writeAsStringSync('const drop = 1;\n');
      writeSrcManifest(project, ['pkg/keep.dart']);

      final allowed = analyze_runner.pruneOrphanedStagedFiles(project.path);

      expect(allowed, {'pkg/keep.dart'});
      expect(File('${project.path}/src/pkg/keep.dart').existsSync(), isTrue);
      expect(File('${project.path}/src/pkg/drop.dart').existsSync(), isFalse);
    });

    test('a dot-slashed manifest line names the same staged file', () {
      final project = stageSrc('dotslash');
      File('${project.path}/src/pkg/keep.dart')
          .writeAsStringSync('const keep = 1;\n');
      writeSrcManifest(project, ['./pkg/keep.dart']);

      final allowed = analyze_runner.pruneOrphanedStagedFiles(project.path);

      expect(allowed, {'pkg/keep.dart'});
      expect(File('${project.path}/src/pkg/keep.dart').existsSync(), isTrue);
    });

    test('without a manifest nothing is pruned', () {
      final project = stageSrc('bare');
      File('${project.path}/src/pkg/any.dart')
          .writeAsStringSync('const any = 1;\n');

      expect(analyze_runner.pruneOrphanedStagedFiles(project.path), isNull);
      expect(File('${project.path}/src/pkg/any.dart').existsSync(), isTrue);
    });
  });
}

void _defineRunnerVerdictUnitTests() {
  group('machine parsing and baseline verdict', () {
    _defineRunnerEscapeParseTest();
    _defineRunnerCeilingTests();
  });
}

void _defineRunnerEscapeParseTest() {
  test('parses escaped pipes and Windows paths and rejects corrupt lines', () {
    const winProject = r'C:\work\demo.proj\';
    const machineOut =
        r'INFO|LINT|AVOID_PRINT|C:\\work\\demo.proj\\src\\lib\\a.dart|4|3|5|'
        r'Use a \| b in C:\\work\\demo.proj\\src\\lib\\a.dart'
        '\n';
    final parsed = analyze_runner.parseMachineDiagnostics(
      machineOut,
      winProject,
    )!;
    expect(parsed, hasLength(1));
    expect(parsed.single.path, 'lib/a.dart');
    expect(parsed.single.code, 'avoid_print');
    expect(parsed.single.text, contains(r'Use a | b in lib\a.dart'));

    expect(
      analyze_runner.parseMachineDiagnostics('not-a-machine-line\n', '/proj'),
      isNull,
    );
    expect(
      analyze_runner.parseMachineDiagnostics(
        'INFO|LINT|X|f|1|2|3|dangling\\',
        '/proj',
      ),
      isNull,
    );
  });
}

void _defineRunnerCeilingTests() {
  test('judges machine diagnostics against per-file ceilings', () {
    const project = '/work/stage.proj';
    String line(String level, String code, String file, int row) =>
        '$level|LINT|$code|$project/src/$file|$row|1|4|msg\n';

    final baseline = AnalysisBaseline.parse(
      '{"lib/a.dart":{"avoid_print":2,"undefined_identifier":1}}',
      source: 'runner_baseline.json',
    );

    final atCeiling = BaselineReport.of(
      analyze_runner.parseMachineDiagnostics(
        line('INFO', 'AVOID_PRINT', 'lib/a.dart', 1) +
            line('INFO', 'AVOID_PRINT', 'lib/a.dart', 2) +
            line('ERROR', 'UNDEFINED_IDENTIFIER', 'lib/a.dart', 3),
        project,
      )!,
      baseline,
    );
    expect(atCeiling.passes, isTrue);

    final overCeiling = BaselineReport.of(
      analyze_runner.parseMachineDiagnostics(
        line('INFO', 'AVOID_PRINT', 'lib/a.dart', 1) * 3,
        project,
      )!,
      baseline,
    );
    expect(overCeiling.passes, isFalse);
    expect(
      baselineFailureLine(overCeiling.groupFor('lib/a.dart', 'avoid_print')!),
      contains('observed 3, ceiling 2'),
    );

    final unkeyedAndOtherFile = [
      line('INFO', 'UNUSED_IMPORT', 'lib/a.dart', 1),
      line('INFO', 'AVOID_PRINT', 'lib/other.dart', 1),
      line('ERROR', 'URI_DOES_NOT_EXIST', 'lib/a.dart', 2),
    ];
    for (final raw in unkeyedAndOtherFile) {
      final report = BaselineReport.of(
        analyze_runner.parseMachineDiagnostics(raw, project)!,
        baseline,
      );
      expect(report.passes, isFalse, reason: raw);
    }
  });

  test('rejects invalid JSON, negative counts, and non-normalized paths', () {
    expect(
      AnalysisBaseline.parse('{"pkg/x.dart":{"dead_code":-0}}')
          .ceilingFor('pkg/x.dart', 'dead_code'),
      0,
    );
    for (final (badJson, offending) in [
      ('{"pkg/x.dart":', 'pkg/x.dart'),
      ('{"pkg/x.dart":{"dead_code":-2}}', 'dead_code'),
      ('{"/abs/x.dart":{"dead_code":1}}', '/abs/x.dart'),
      ('{"./pkg/x.dart":{"dead_code":1}}', './pkg/x.dart'),
      ('{"pkg//x.dart":{"dead_code":1}}', 'pkg//x.dart'),
    ]) {
      expect(
        () => AnalysisBaseline.parse(badJson, source: 'runner_baseline.json'),
        throwsA(
          isA<BaselineException>().having(
            (e) => e.message,
            'message',
            allOf(contains('runner_baseline.json'), contains(offending)),
          ),
        ),
      );
    }
  });
}
