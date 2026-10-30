import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'analyze_runner.dart' as analyze_runner;

import 'analysis_baseline.dart'
    show
        AnalysisBaseline,
        BaselineDiagnostic,
        BaselineReport,
        baselineFailureLine;

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

  group('pruneOrphanedStagedFiles', () {
    Directory stageSrc(String name) {
      final project = Directory('${tmp.path}/$name.proj')
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

  group('baseline verdict', () {
    BaselineDiagnostic errorAt(String path, String code) => BaselineDiagnostic(
      path: path,
      code: code,
      level: 'error',
      text: '$path $code',
    );

    test('exempts a keyed error but never an unkeyed one', () {
      final baseline = AnalysisBaseline.parse(
        '{"lib/a.dart":{"undefined_identifier":1}}',
        source: 'baseline.json',
      );

      expect(
        BaselineReport.of([
          errorAt('lib/a.dart', 'undefined_identifier'),
        ], baseline).passes,
        isTrue,
      );
      expect(
        BaselineReport.of([
          errorAt('lib/b.dart', 'undefined_identifier'),
        ], baseline).passes,
        isFalse,
      );
    });

    test('fails above the ceiling and names the file, code and counts', () {
      final baseline = AnalysisBaseline.parse(
        '{"lib/a.dart":{"avoid_print":2}}',
      );
      final report = BaselineReport.of([
        for (var i = 0; i < 3; i++)
          BaselineDiagnostic(
            path: 'lib/a.dart',
            code: 'avoid_print',
            level: 'info',
            text: 'lib/a.dart $i',
          ),
      ], baseline);

      expect(report.passes, isFalse);
      final group = report.groupFor('lib/a.dart', 'avoid_print')!;
      expect(group.observed, 3);
      expect(group.ceiling, 2);
      expect(baselineFailureLine(group), contains('observed 3, ceiling 2'));
    });
  });
}
