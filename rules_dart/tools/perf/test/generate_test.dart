import 'dart:io';

import 'package:perf/src/generate.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('gen'));
  tearDown(() => dir.deleteSync(recursive: true));

  int lines(String root) =>
      Directory(root)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .fold(0, (n, f) => n + f.readAsLinesSync().length);

  test('deep and wide shapes', () {
    const deep = GraphSpec(libraries: 2000);
    const wide = GraphSpec(libraries: 5000, shape: Shape.wide);
    expect((deep.layers, deep.width), (100, 20));
    expect((wide.layers, wide.width), (4, 1250));
    expect(deep.deps(0, 3), isEmpty);
    expect(deep.deps(5, 19), [(4, 19), (4, 6), (4, 13)]);
    expect(wide.name, 'wide-5000');
  });

  test('a Bazel graph: one library per package, three imports of the layer below, a test per top library', () {
    const s = GraphSpec(libraries: 60);
    writeBazelGraph(s, dir.path, '/repo');
    final libs = Directory(dir.path)
        .listSync(recursive: true)
        .where((e) => e.path.endsWith('/lib/x.dart'))
        .length;
    expect(libs, 60);
    final top = File('${dir.path}/l2/p2_4/lib/x.dart').readAsStringSync();
    expect(RegExp("import 'package:p1_").allMatches(top), hasLength(3));
    expect(top, contains(bodyAnchor));
    expect(
      File('${dir.path}/l2/p2_4/BUILD.bazel').readAsStringSync(),
      contains('"//l1/p1_4"'),
    );
    expect(
      File('${dir.path}/tests/BUILD.bazel').readAsStringSync(),
      contains('name = "t19_test"'),
    );
    expect(
      File('${dir.path}/MODULE.bazel').readAsStringSync(),
      contains('path = "/repo/rules_dart"'),
    );
    expect(File('${dir.path}/pubspec.lock').existsSync(), isFalse);
  });

  test('the 500k knob gives about the lines asked for', () {
    final m = GraphSpec.methodsFor(50000, 200);
    final s = GraphSpec(libraries: 200, methods: m, packageTest: true);
    final lock = File('${dir.path}/in.lock')
      ..writeAsStringSync('packages: {}\n');
    writeBazelGraph(s, '${dir.path}/ws', '/repo', lock: lock.path);
    final n = lines('${dir.path}/ws');
    expect(n, inInclusiveRange(45000, 55000));
    expect(
      File('${dir.path}/ws/tests/test/t0_test.dart').readAsStringSync(),
      contains('package:test/test.dart'),
    );
    expect(
      () => writeBazelGraph(s, '${dir.path}/x', '/repo'),
      throwsArgumentError,
    );
  });

  test('the stock twin is a pub workspace of the same libraries', () {
    const s = GraphSpec(libraries: 40, packageTest: true);
    writeBazelGraph(
      s,
      '${dir.path}/bazel',
      '/repo',
      lock: (File('${dir.path}/l')..writeAsStringSync('')).path,
    );
    writeStockTwin(s, '${dir.path}/twin');
    final root = File('${dir.path}/twin/pubspec.yaml').readAsStringSync();
    expect(RegExp(r'^  - ', multiLine: true).allMatches(root), hasLength(41));
    expect(
      File('${dir.path}/twin/l1/p1_0/pubspec.yaml').readAsStringSync(),
      allOf(contains('resolution: workspace'), contains('  p0_0: any')),
    );
    expect(
      File('${dir.path}/twin/tests/pubspec.yaml').readAsStringSync(),
      contains('  test: any'),
    );
    expect(
      File('${dir.path}/twin/l1/p1_3/lib/x.dart').readAsStringSync(),
      File('${dir.path}/bazel/l1/p1_3/lib/x.dart').readAsStringSync(),
    );
  });

  test(
    'a Flutter graph has an app over the top layer, here and in the twin',
    () {
      const s = GraphSpec(libraries: 40, flutter: true);
      writeBazelGraph(
        s,
        '${dir.path}/b',
        '/repo',
        lock: (File('${dir.path}/l')..writeAsStringSync('')).path,
      );
      writeStockTwin(s, '${dir.path}/t');
      expect(
        File('${dir.path}/b/app/BUILD.bazel').readAsStringSync(),
        contains('"//l1/p1_19"'),
      );
      expect(
        File('${dir.path}/b/l0/p0_0/BUILD.bazel').readAsStringSync(),
        contains('flutter_library('),
      );
      expect(
        File('${dir.path}/t/app/lib/main.dart').readAsStringSync(),
        contains('p1_19.View1x19()'),
      );
      expect(
        File('${dir.path}/t/app/pubspec.yaml').readAsStringSync(),
        contains('sdk: flutter'),
      );
    },
  );

  test('the per-source probe has 10 and 20 files', () {
    writePerSourceProbe(dir.path, '/repo');
    expect(Directory('${dir.path}/src10/lib').listSync(), hasLength(10));
    expect(Directory('${dir.path}/src20/lib').listSync(), hasLength(20));
  });

  test('the code generation package has its models and outputs', () {
    final lock = File('${dir.path}/in.lock')
      ..writeAsStringSync('packages: {}\n');
    writeCodegenPackage('${dir.path}/cg', '/repo', lock: lock.path);
    writeCodegenPackage(
      '${dir.path}/st',
      '/repo',
      lock: lock.path,
      bazel: false,
    );
    expect(File('${dir.path}/st/MODULE.bazel').existsSync(), isFalse);
    expect(File('${dir.path}/st/${codegenModel(0)}').existsSync(), isTrue);
    expect(
      Directory('${dir.path}/cg/$codegenPackage/lib/src').listSync(),
      hasLength(codegenFiles + 1),
    );
    expect(
      File('${dir.path}/cg/$codegenPackage/${codegenModel(7)}')
          .readAsStringSync(),
      contains("part 'm7.g.dart';"),
    );
    expect(
      RegExp(r'\.g\.dart"').allMatches(
        File('${dir.path}/cg/$codegenPackage/BUILD.bazel').readAsStringSync(),
      ),
      hasLength(codegenFiles),
    );
  });
}
