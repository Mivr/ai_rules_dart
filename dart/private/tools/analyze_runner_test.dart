import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

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
}
