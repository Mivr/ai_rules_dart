// Subprocess helpers and baseline runner tests for `analyze_runner_test`.
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Registers subprocess tests driving the built `analyze_runner` with
/// `--baseline`.
void defineRunnerSubprocessBaselineTests(
  List<String> args,
  Directory Function() currentTmp,
) {
  group('analyze_runner --baseline subprocess', () {
    _defineRunnerCeilingSubprocessTest(args, currentTmp);
    _defineRunnerOptionsParseErrorSubprocessTest(args, currentTmp);
    _defineRunnerZeroDiagnosticsCrashTest(args, currentTmp);
  });
}

/// Outcome of one `analyze_runner --baseline` subprocess invocation.
typedef _RunnerOutcome = ({
  int exitCode,
  bool stamped,
  String stdout,
  String stderr,
});

/// Runfiles-resolved binaries and scratch directory for a subprocess test.
final class _RunnerHarness {
  _RunnerHarness._(this.runner, this.dartBin, this.tmp);

  final String runner;
  final String dartBin;
  final Directory tmp;
  int _counter = 0;

  static _RunnerHarness? resolve(
    List<String> args,
    Directory Function() currentTmp,
  ) {
    if (args.length < 2) return null;
    final rf = Runfiles.create();
    return _RunnerHarness._(
      rf.rlocation(args[0]),
      rf.rlocation(args[1]),
      currentTmp(),
    );
  }

  Directory stageProject(
    String name,
    String relPath,
    String body, {
    String optionsBody = 'linter:\n  rules:\n    - avoid_print\n',
  }) {
    final project = Directory('${tmp.path}/$name.proj')
      ..createSync(recursive: true);
    File('${project.path}/analysis_options.yaml')
        .writeAsStringSync(optionsBody);
    File('${project.path}/pubspec.yaml')
        .writeAsStringSync('name: demo\nenvironment:\n  sdk: ^3.11.0\n');
    Directory('${project.path}/.dart_tool').createSync(recursive: true);
    File('${project.path}/.dart_tool/package_config.json')
        .writeAsStringSync('{"configVersion":2,"packages":[]}\n');
    final srcFile = File('${project.path}/src/$relPath');
    srcFile.parent.createSync(recursive: true);
    srcFile.writeAsStringSync(body);
    return project;
  }

  _RunnerOutcome run(
    Directory project,
    String sourceRel, {
    String? baselineJson,
    String? baselinePath,
    String? dartOverride,
  }) {
    final id = _counter++;
    final resolvedBaseline =
        baselinePath ??
        (File(
          '${tmp.path}/b_$id.json',
        )..writeAsStringSync('$baselineJson\n')).path;
    final stamp = File('${tmp.path}/s_$id.stamp');
    final res = Process.runSync(Platform.resolvedExecutable, [
      runner,
      '--dart',
      dartOverride ?? dartBin,
      '--project',
      project.path,
      '--stamp',
      stamp.path,
      '--fatal-infos',
      '--baseline',
      resolvedBaseline,
      '--source',
      sourceRel,
    ]);
    return (
      exitCode: res.exitCode,
      stamped: stamp.existsSync(),
      stdout: res.stdout as String,
      stderr: res.stderr as String,
    );
  }
}

void _defineRunnerCeilingSubprocessTest(
  List<String> args,
  Directory Function() currentTmp,
) {
  test('enforces ceilings and fail-closed checks via dart analyze', () {
    final harness = _RunnerHarness.resolve(args, currentTmp);
    if (harness == null) return;
    final project = harness.stageProject(
      'ceil',
      'lib/sample.dart',
      "void f() {\n  print('1');\n  print('2');\n}\n",
    );

    final ok = harness.run(
      project,
      'src/lib/sample.dart',
      baselineJson: '{"lib/sample.dart":{"avoid_print":2}}',
    );
    expect(ok.exitCode, 0, reason: '${ok.stdout}\n${ok.stderr}');
    expect(ok.stamped, isTrue);
    expect(ok.stdout, contains('lib/sample.dart:2:3'));
    expect(ok.stdout, contains('baselined (2/2)'));

    final low = harness.run(
      project,
      'src/lib/sample.dart',
      baselineJson: '{"lib/sample.dart":{"avoid_print":1}}',
    );
    expect(low.exitCode, isNonZero);
    expect(low.stamped, isFalse);
    expect(low.stdout, contains('observed 2, ceiling 1'));

    final missing = harness.run(
      project,
      'src/lib/sample.dart',
      baselinePath: '${harness.tmp.path}/does_not_exist.json',
    );
    expect(missing.exitCode, isNonZero);
    expect(missing.stamped, isFalse);
  });
}

void _defineRunnerOptionsParseErrorSubprocessTest(
  List<String> args,
  Directory Function() currentTmp,
) {
  test(
    'never hides an unkeyed options parse_error and exempts a keyed one',
    () {
      final harness = _RunnerHarness.resolve(args, currentTmp);
      if (harness == null) return;
      final project = harness.stageProject(
        'opts_err',
        'sub/lib/b.dart',
        "void f() {\n  print('1');\n}\n",
      );
      File('${project.path}/src/pkg/analysis_options.yaml')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('analyzer: [\ninvalid: yaml: :\n');
      File('${project.path}/src/pkg/lib/a.dart')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('const a = 1;\n');

      final unkeyed = harness.run(
        project,
        'src/sub/lib/b.dart',
        baselineJson: '{"sub/lib/b.dart":{"avoid_print":1}}',
      );
      expect(unkeyed.exitCode, isNonZero);
      expect(unkeyed.stamped, isFalse);
      expect(unkeyed.stdout, contains('pkg/analysis_options.yaml'));
      expect(unkeyed.stdout, contains('parse_error'));

      final keyed = harness.run(
        project,
        'src/sub/lib/b.dart',
        baselineJson:
            '{"sub/lib/b.dart":{"avoid_print":1},'
            '"pkg/analysis_options.yaml":{"parse_error":1}}',
      );
      expect(keyed.exitCode, 0, reason: '${keyed.stdout}\n${keyed.stderr}');
      expect(keyed.stamped, isTrue);
    },
  );
}

void _defineRunnerZeroDiagnosticsCrashTest(
  List<String> args,
  Directory Function() currentTmp,
) {
  test('fails closed when analyzer exits non-zero with no diagnostics', () {
    final harness = _RunnerHarness.resolve(args, currentTmp);
    if (harness == null) return;
    final ext = Platform.isWindows ? '.exe' : '';
    final aotRuntime =
        '${File(harness.dartBin).parent.path}/dartaotruntime$ext';
    final project = harness.stageProject(
      'crash',
      'lib/sample.dart',
      'const x = 1;\n',
    );
    // `dartaotruntime` rejects the `analyze` subcommand with non-zero exit
    // and no machine diagnostics on stdout.
    final crash = harness.run(
      project,
      'src/lib/sample.dart',
      baselineJson: '{}',
      dartOverride: aotRuntime,
    );
    expect(crash.exitCode, isNonZero);
    expect(crash.stamped, isFalse);
  });
}
