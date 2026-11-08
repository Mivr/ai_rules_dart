import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main(List<String> args) {
  test('intentional violation is caught and reported in both summary and source modes', () {
    final runfiles = Runfiles.create();
    final String analyzerSummaryPath = runfiles.rlocation(args[0]);
    final String sdkSummaryPath = runfiles.rlocation(args[1]);
    final String sdkRoot = p.dirname(p.dirname(Platform.resolvedExecutable));

    final Directory tmp = Directory.systemTemp.createTempSync(
      'lint_parity_neg_',
    );
    try {
      final srcDir = Directory(p.join(tmp.path, 'src', 'lib'))
        ..createSync(recursive: true);
      final dotTool = Directory(p.join(tmp.path, '.dart_tool'))
        ..createSync(recursive: true);

      File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync(
        'name: parity_negative\nenvironment:\n  sdk: ^3.7.0\n',
      );
      File(p.join(tmp.path, 'analysis_options.yaml')).writeAsStringSync(
        'analyzer:\n  language:\n    strict-casts: true\nlinter:\n  rules:\n    no_dynamic_casts: true\n',
      );
      File(p.join(srcDir.path, 'negative.dart')).writeAsStringSync(
        'int triggerViolation(dynamic value) {\n  int num = value;\n  return num;\n}\n',
      );
      File(p.join(dotTool.path, 'package_config.json')).writeAsStringSync('''

{
  "configVersion": 2,
  "packages": [
    {
      "name": "parity_negative",
      "rootUri": "../",
      "packageUri": "src/lib/",
      "languageVersion": "3.7"
    }
  ]
}''');

      // 1. Source mode (zero --summary flags)
      final ProcessResult sourceResult = Process.runSync(
        Platform.resolvedExecutable,
        [
          analyzerSummaryPath,
          'analyze',
          '--sdk',
          sdkRoot,
          '--project',
          tmp.path,
          '--sdk-summary',
          sdkSummaryPath,
          '--source',
          'src/lib/negative.dart',
          '--stamp',
          p.join(tmp.path, 'source.stamp'),
        ],
      );
      expect(
        sourceResult.exitCode,
        isNot(0),
        reason: 'source mode must fail on violation',
      );
      expect(sourceResult.stdout, contains('no_dynamic_casts'));

      // 2. Summary mode
      final ProcessResult summaryResult = Process.runSync(
        Platform.resolvedExecutable,
        [
          analyzerSummaryPath,
          'analyze',
          '--sdk',
          sdkRoot,
          '--project',
          tmp.path,
          '--sdk-summary',
          sdkSummaryPath,
          '--source',
          'src/lib/negative.dart',
          '--stamp',
          p.join(tmp.path, 'summary.stamp'),
        ],
      );
      expect(
        summaryResult.exitCode,
        isNot(0),
        reason: 'summary mode must fail on violation',
      );
      expect(summaryResult.stdout, contains('no_dynamic_casts'));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
