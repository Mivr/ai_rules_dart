// Subprocess helpers and baseline runner tests for `analyze_runner_test`.
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'analysis_baseline.dart';
import 'analyze_runner_machine.dart';

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
    _defineRunnerSymlinkSubprocessTest(args, currentTmp);
    _defineRunnerUnkeyedWrapperSubprocessTest(args, currentTmp);
  });
  group(
    'analyze_runner whole-path prefix matching and unkeyed diagnostics',
    () {
      _defineRunnerPrefixMatchingUnitTests(currentTmp);
    },
  );
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
  }) => stageProjectAt(
    Directory('${tmp.path}/$name.proj'),
    relPath,
    body,
    optionsBody: optionsBody,
  );

  Directory stageProjectAt(
    Directory project,
    String relPath,
    String body, {
    String optionsBody = 'linter:\n  rules:\n    - avoid_print\n',
  }) {
    project.createSync(recursive: true);
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

void _defineRunnerSymlinkSubprocessTest(
  List<String> args,
  Directory Function() currentTmp,
) {
  test(
    'matches symlink-resolved root and baseline keys without substring mangling',
    skip: args.length < 2
        ? 'requires analyze_runner and dart runfiles paths'
        : null,
    () {
      final _RunnerHarness harness = _RunnerHarness.resolve(args, currentTmp)!;
      final String realTmp = Directory(currentTmp().path)
          .resolveSymbolicLinksSync();
      final String sep = Platform.pathSeparator;
      final privateSegment = Platform.isWindows
          ? 'private_sym_root'
          : 'private$realTmp';
      final Directory realDir = harness.stageProjectAt(
        Directory(
          '$realTmp/$privateSegment/sym_ceil.proj'.replaceAll('/', sep),
        ),
        'lib/sample.dart',
        "void f() {\n  print('1');\n  print('2');\n}\n",
      );

      final pkgOptions = File('${realDir.path}/src/pkg/analysis_options.yaml')
        ..parent.createSync(recursive: true);
      pkgOptions.writeAsStringSync('analyzer: [\ninvalid: yaml: :\n');
      File('${realDir.path}/src/pkg/lib/a.dart')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('const a = 1;\n');

      final symlink = Link('$realTmp/sym_ceil.proj'.replaceAll('/', sep))
        ..createSync(realDir.path);
      final symlinkProject = Directory(symlink.path);

      final _RunnerOutcome ok = harness.run(
        symlinkProject,
        'src/lib/sample.dart',
        baselineJson:
            '{"lib/sample.dart":{"avoid_print":2},'
            '"pkg/analysis_options.yaml":{"parse_error":1}}',
      );
      expect(ok.exitCode, 0, reason: '${ok.stdout}\n${ok.stderr}');
      expect(ok.stamped, isTrue);
      expect(ok.stdout, contains('lib/sample.dart'));
      expect(ok.stdout, contains('pkg/analysis_options.yaml'));
      expect(ok.stdout, contains('baselined (2/2)'));
      expect(ok.stdout, contains('baselined (1/1)'));
      expect(ok.stdout, isNot(contains('privatelib')));
      expect(ok.stdout, isNot(contains(privateSegment)));

      final _RunnerOutcome low = harness.run(
        symlinkProject,
        'src/lib/sample.dart',
        baselineJson:
            '{"lib/sample.dart":{"avoid_print":1},'
            '"pkg/analysis_options.yaml":{"parse_error":1}}',
      );
      expect(low.exitCode, isNonZero);
      expect(low.stamped, isFalse);
      expect(
        low.stdout,
        contains(
          'baseline: lib/sample.dart avoid_print: observed 2, ceiling 1',
        ),
      );
    },
  );
}

String _escapeMachineField(String value) => value.replaceAll(r'\', r'\\');

void _defineRunnerUnkeyedWrapperSubprocessTest(
  List<String> args,
  Directory Function() currentTmp,
) {
  test(
    'reports wrapper-root diagnostics outside src as unkeyed failures',
    skip: args.length < 2
        ? 'requires analyze_runner and dart runfiles paths'
        : null,
    () {
      final _RunnerHarness harness = _RunnerHarness.resolve(args, currentTmp)!;
      final Directory project = harness.stageProject(
        'wrap_err',
        'lib/sample.dart',
        'const x = 1;\n',
        optionsBody: 'analyzer: [\ninvalid: yaml: :\n',
      );
      final _RunnerOutcome outcome = harness.run(
        project,
        'src/lib/sample.dart',
        baselineJson: '{"analysis_options.yaml":{"parse_error":5}}',
      );
      expect(
        outcome.exitCode,
        1,
        reason: '${outcome.stdout}\n${outcome.stderr}',
      );
      expect(outcome.stamped, isFalse);
      expect(outcome.stdout, contains('analysis_options.yaml'));
      expect(outcome.stdout, contains('parse_error'));
      expect(outcome.stdout, isNot(contains('baselined')));
      expect(outcome.stdout, isNot(contains('baseline:')));
    },
  );
}

void _defineRunnerPrefixMatchingUnitTests(Directory Function() currentTmp) {
  _defineRunnerPrefixMatchingKeyedTest(currentTmp);
  _defineRunnerUnstageAndWindowsUnitTest();
  _defineRunnerPrefixMatchingUnkeyedTest();
  _defineRunnerBaselineReportUnkeyedTest();
}

void _defineRunnerPrefixMatchingKeyedTest(Directory Function() currentTmp) {
  test('resolves diagnostics under lexical and symlink-resolved roots as keyed', () {
    final String sep = Platform.pathSeparator;
    final String realTmp = Directory(currentTmp().path)
        .resolveSymbolicLinksSync();
    final privateSegment = Platform.isWindows
        ? 'private_sym_unit'
        : 'private$realTmp';
    final symTarget = Directory(
      '$realTmp/$privateSegment/sym_unit.proj'.replaceAll('/', sep),
    )..createSync(recursive: true);
    Directory('${symTarget.path}${sep}src${sep}lib')
        .createSync(recursive: true);
    final symLink = Link('$realTmp/sym_unit.proj'.replaceAll('/', sep))
      ..createSync(symTarget.path);

    final List<BaselineDiagnostic>? lexicalDiag = parseMachineDiagnostics(
      'INFO|LINT|AVOID_PRINT|${_escapeMachineField(symLink.path)}/src/lib/a.dart|1|1|1|msg\n',
      symLink.path,
    );
    expect(lexicalDiag!.single.path, 'lib/a.dart');
    expect(lexicalDiag.single.keyed, isTrue);

    final List<BaselineDiagnostic>? resolvedDiag = parseMachineDiagnostics(
      'INFO|LINT|AVOID_PRINT|${_escapeMachineField(symTarget.path)}/src/lib/a.dart|1|1|1|msg\n',
      symLink.path,
    );
    expect(resolvedDiag!.single.path, 'lib/a.dart');
    expect(resolvedDiag.single.keyed, isTrue);

    final List<BaselineDiagnostic> contextDiag = parseContextDiagnostics(
      '   info - ${symTarget.path}/src/lib/a.dart:1:1 - msg - avoid_print\n',
      symLink.path,
    );
    expect(contextDiag.single.path, 'lib/a.dart');
    expect(contextDiag.single.keyed, isTrue);

    // Also cover an unexpanded temp directory (e.g. Windows 8.3 `RUNNER~1`
    // or macOS `/var/folders`) where `Link.targetSync()` and
    // `resolveSymbolicLinksSync()` differ in ancestor spelling.
    final rawReal = Directory('${currentTmp().path}${sep}real_proj')
      ..createSync(recursive: true);
    Directory('${rawReal.path}${sep}src${sep}lib').createSync(recursive: true);
    final rawLink = Link('${currentTmp().path}${sep}link_proj')
      ..createSync(rawReal.path);
    final List<BaselineDiagnostic>? rawTargetDiag = parseMachineDiagnostics(
      'INFO|LINT|AVOID_PRINT|${_escapeMachineField(rawReal.path)}/src/lib/a.dart|1|1|1|msg\n',
      rawLink.path,
    );
    expect(rawTargetDiag!.single.path, 'lib/a.dart');
    expect(rawTargetDiag.single.keyed, isTrue);

    final List<BaselineDiagnostic>? relProjDiag = parseMachineDiagnostics(
      'INFO|LINT|AVOID_PRINT|rel.proj/src/lib/a.dart|1|1|1|msg\n',
      './rel.proj',
    );
    expect(relProjDiag!.single.path, 'lib/a.dart');
    expect(relProjDiag.single.keyed, isTrue);

    final String unstaged = unstage(
      "See '${symTarget.path}/src/lib/a.dart' and '/other${symLink.path}/src/lib/b.dart'",
      symLink.path,
    );
    expect(unstaged, contains("'lib/a.dart'"));
    expect(unstaged, contains("'/other${symLink.path}/src/lib/b.dart'"));
  });
}

void _defineRunnerUnstageAndWindowsUnitTest() {
  test('handles Windows drive prefixes, extended paths, and file URIs', () {
    final List<BaselineDiagnostic>? winCaseDiag = parseMachineDiagnostics(
      r'INFO|LINT|AVOID_PRINT|c:\\WORK\\demo.proj\\src\\lib\\Sample.dart|1|1|1|msg'
          '\n',
      r'C:\work\demo.proj',
    );
    expect(winCaseDiag!.single.path, 'lib/Sample.dart');
    expect(winCaseDiag.single.keyed, isTrue);

    final List<BaselineDiagnostic>? winExtDiag = parseMachineDiagnostics(
      r'INFO|LINT|AVOID_PRINT|\\\\?\\C:\\work\\demo.proj\\src\\lib\\a.dart|1|1|1|msg'
          '\n',
      r'C:\work\demo.proj',
    );
    expect(winExtDiag!.single.path, 'lib/a.dart');
    expect(winExtDiag.single.keyed, isTrue);

    final String winUnstaged = unstage(
      r'Cannot include file:///C:/work/demo.proj/src/pkg/opts.yaml or C:\WORK\demo.proj/src/lib\a.dart',
      r'C:\work\demo.proj',
    );
    expect(winUnstaged, r'Cannot include file:///pkg/opts.yaml or lib\a.dart');

    final String relUnstaged = unstage(
      "See 'rel.proj/src/lib/a.dart' and '/other/rel.proj/src/lib/b.dart'",
      './rel.proj',
    );
    expect(
      relUnstaged,
      "See 'lib/a.dart' and '/other/rel.proj/src/lib/b.dart'",
    );
  });
}

void _defineRunnerPrefixMatchingUnkeyedTest() {
  test('marks non-root, superstring, and wrapper files as unkeyed display paths', () {
    const project = '/work/stage.proj';
    final List<BaselineDiagnostic>? superstring = parseMachineDiagnostics(
      'INFO|LINT|AVOID_PRINT|/prefix/work/stage.proj/src/lib/a.dart|1|1|1|msg\n',
      project,
    );
    expect(superstring, isNotNull);
    expect(superstring!.single.path, '/prefix/work/stage.proj/src/lib/a.dart');
    expect(superstring.single.keyed, isFalse);

    final List<BaselineDiagnostic>? sibling = parseMachineDiagnostics(
      'INFO|LINT|AVOID_PRINT|/work/stage.proj2/src/lib/a.dart|1|1|1|msg\n',
      project,
    );
    expect(sibling, isNotNull);
    expect(sibling!.single.path, '/work/stage.proj2/src/lib/a.dart');
    expect(sibling.single.keyed, isFalse);

    final List<BaselineDiagnostic>? outside = parseMachineDiagnostics(
      'INFO|LINT|AVOID_PRINT|/outside/lib/a.dart|1|1|1|msg\n',
      project,
    );
    expect(outside, isNotNull);
    expect(outside!.single.path, '/outside/lib/a.dart');
    expect(outside.single.keyed, isFalse);

    final List<BaselineDiagnostic>? climbing = parseMachineDiagnostics(
      'ERROR|LINT|PARSE_ERROR|src/../pubspec.yaml|1|1|1|msg\n',
      project,
    );
    expect(climbing!.single.path, 'src/../pubspec.yaml');
    expect(climbing.single.keyed, isFalse);

    final List<BaselineDiagnostic>? wrapperAbs = parseMachineDiagnostics(
      'ERROR|LINT|PARSE_ERROR|/work/stage.proj/pubspec.yaml|1|1|1|msg\n',
      project,
    );
    expect(wrapperAbs, isNotNull);
    expect(wrapperAbs!.single.path, 'pubspec.yaml');
    expect(wrapperAbs.single.keyed, isFalse);

    final List<BaselineDiagnostic>? wrapperRel = parseMachineDiagnostics(
      'ERROR|LINT|PARSE_ERROR|pubspec.yaml|1|1|1|msg\n',
      project,
    );
    expect(wrapperRel, isNotNull);
    expect(wrapperRel!.single.path, 'pubspec.yaml');
    expect(wrapperRel.single.keyed, isFalse);

    final List<BaselineDiagnostic> wrapperCtx = parseContextDiagnostics(
      '  error - /work/stage.proj/pubspec.yaml:1:1 - bad yaml - parse_error\n',
      project,
    );
    expect(wrapperCtx.single.path, 'pubspec.yaml');
    expect(wrapperCtx.single.keyed, isFalse);

    final List<BaselineDiagnostic>? winWrapper = parseMachineDiagnostics(
      r'ERROR|LINT|PARSE_ERROR|C:\\work\\stage.proj\\pubspec.yaml|1|1|1|msg'
          '\n',
      r'C:\work\stage.proj',
    );
    expect(winWrapper!.single.path, 'pubspec.yaml');
    expect(winWrapper.single.keyed, isFalse);
  });
}

void _defineRunnerBaselineReportUnkeyedTest() {
  test(
    'BaselineReport rejects unkeyed diagnostics and excludes them from groups',
    () {
      final baseline = AnalysisBaseline.parse(
        '{"pubspec.yaml":{"parse_error":5},"lib/a.dart":{"avoid_print":5}}',
      );
      const unkeyedPubspec = BaselineDiagnostic(
        path: 'pubspec.yaml',
        code: 'parse_error',
        level: 'error',
        text: 'pubspec error',
        keyed: false,
      );
      final pubspecReport = BaselineReport.of([unkeyedPubspec], baseline);
      expect(pubspecReport.passes, isFalse);
      expect(pubspecReport.groups, isEmpty);
      expect(pubspecReport.groupFor('pubspec.yaml', 'parse_error'), isNull);

      const unkeyedLib = BaselineDiagnostic(
        path: 'lib/a.dart',
        code: 'avoid_print',
        level: 'info',
        text: 'avoid print',
        keyed: false,
      );
      final libReport = BaselineReport.of([unkeyedLib], baseline);
      expect(libReport.passes, isFalse);
      expect(libReport.groups, isEmpty);
      expect(libReport.groupFor('lib/a.dart', 'avoid_print'), isNull);
    },
  );
}
