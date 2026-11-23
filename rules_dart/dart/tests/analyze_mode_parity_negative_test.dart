import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const String _depSource =
    'class Base {\n  void configure(bool a, bool b) {}\n}\n';

const String _consumerSource = '''
import 'package:parity_dep/dep.dart';

class Impl extends Base {
  @override
  void configure(bool a, bool b) {}
}

class Holder {
  void flag(bool enabled) {}
  void both(bool a, bool b) {}
  void withInt(int x, bool b) {}
}

int triggerViolation(dynamic value) {
  int num = value;
  return num;
}
''';

const String _options =
    'analyzer:\n  language:\n    strict-casts: true\n'
    'linter:\n  rules:\n    no_dynamic_casts: true\n'
    '    avoid_positional_boolean_parameters: true\n';

String _packageConfig(String depRoot) =>
    '''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "parity_negative",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.7"
    },
    {
      "name": "parity_dep",
      "rootUri": "$depRoot",
      "packageUri": "lib/",
      "languageVersion": "3.7"
    }
  ]
}''';

/// Writes a project directory; the dependency's source is present only when
/// [withDepSource] (source mode). Summary mode supplies it as a `.sum` instead.
Directory _project(Directory root, String name, {required bool withDepSource}) {
  final dir = Directory(p.join(root.path, name))..createSync();
  Directory(p.join(dir.path, 'lib')).createSync(recursive: true);
  Directory(p.join(dir.path, '.dart_tool')).createSync();
  File(
    p.join(dir.path, 'pubspec.yaml'),
  ).writeAsStringSync('name: parity_negative\nenvironment:\n  sdk: ^3.7.0\n');
  File(p.join(dir.path, 'analysis_options.yaml')).writeAsStringSync(_options);
  File(p.join(dir.path, 'lib', 'negative.dart'))
      .writeAsStringSync(_consumerSource);
  File(p.join(dir.path, '.dart_tool', 'package_config.json'))
      .writeAsStringSync(_packageConfig('../../${name}_dep/'));
  if (withDepSource) {
    final String depLib = p.join(root.path, '${name}_dep', 'lib');
    Directory(depLib).createSync(recursive: true);
    File(p.join(depLib, 'dep.dart')).writeAsStringSync(_depSource);
  }
  return dir;
}

/// The sorted diagnostic lines (rule and message, without paths) of [result].
List<String> _diagnostics(ProcessResult result) {
  final lines = <String>[
    for (final String line in '${result.stdout}'.split('\n'))
      if (line.contains('no_dynamic_casts') ||
          line.contains('avoid_positional_boolean_parameters'))
        line.trim().split(' - ').where((s) => !s.contains(':')).join(' - '),
  ]..sort();
  return lines;
}

void main(List<String> args) {
  test('violations are reported identically from dependency summaries and from staged dependency sources', () {
    final runfiles = Runfiles.create();
    final String tool = runfiles.rlocation(args[0]);
    final String sdkSummary = runfiles.rlocation(args[1]);
    final String sdkRoot = p.dirname(p.dirname(Platform.resolvedExecutable));
    // `analyzer_summary` is an AOT snapshot: `dart` refuses to run it.
    final String aotRuntime = p.join(
      sdkRoot,
      'bin',
      Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
    );
    final Directory tmp = Directory.systemTemp.createTempSync('lint_parity_');
    try {
      final Directory sourceProject = _project(
        tmp,
        'source',
        withDepSource: true,
      );
      final Directory summaryProject = _project(
        tmp,
        'summary',
        withDepSource: false,
      );

      // Summary mode: the dependency arrives only as a `.sum` bundle.
      final String depSum = p.join(tmp.path, 'dep.sum');
      final ProcessResult built = Process.runSync(aotRuntime, [
        tool,
        'summarize',
        '--sdk',
        sdkRoot,
        '--sdk-summary',
        sdkSummary,
        '--packages',
        p.join(sourceProject.path, '.dart_tool', 'package_config.json'),
        '--source',
        p.join(tmp.path, 'source_dep', 'lib', 'dep.dart'),
        '--uri',
        'package:parity_dep/dep.dart',
        '--out',
        depSum,
      ]);
      expect(built.exitCode, 0, reason: '${built.stdout}${built.stderr}');

      ProcessResult analyze(Directory project, List<String> summaries) =>
          Process.runSync(aotRuntime, [
            tool,
            'analyze',
            '--sdk',
            sdkRoot,
            '--project',
            project.path,
            '--sdk-summary',
            sdkSummary,
            for (final String s in summaries) ...['--summary', s],
            '--source',
            'lib/negative.dart',
            '--stamp',
            p.join(project.path, 'out.stamp'),
          ]);

      final ProcessResult source = analyze(sourceProject, const []);
      final ProcessResult summary = analyze(summaryProject, [depSum]);

      for (final (String mode, ProcessResult r) in [
        ('source', source),
        ('summary', summary),
      ]) {
        expect(r.exitCode, isNot(0), reason: '$mode mode must fail');
        expect(r.stdout, contains('no_dynamic_casts'), reason: mode);
        expect(
          r.stdout,
          contains('avoid_positional_boolean_parameters'),
          reason: mode,
        );
      }
      expect(_diagnostics(source), isNotEmpty);
      expect(_diagnostics(summary), _diagnostics(source));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
