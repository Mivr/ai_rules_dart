import 'dart:io';

import 'package:flutter_dev/src/bazel.dart';
import 'package:flutter_dev/src/options.dart';
import 'package:flutter_dev/src/project_files.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('project_files_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  final bazelConfig = <String, Object?>{
    'configVersion': 2,
    'packages': <Object?>[
      <String, Object?>{
        'name': 'flutter',
        'rootUri': 'org-dartlang-app:///external/hub__flutter',
        'packageUri': 'lib/',
      },
      <String, Object?>{
        'name': 'counter_lib',
        'rootUri': 'org-dartlang-app:///packages/counter_lib',
        'packageUri': 'lib/',
      },
      <String, Object?>{
        'name': 'counter',
        'rootUri': 'org-dartlang-app:///',
        'packageUri': 'lib/',
      },
      <String, Object?>{
        'name': 'other',
        'rootUri': 'file:///elsewhere/',
        'packageUri': 'lib/',
      },
    ],
  };

  test('roots become file: URIs into the workspace and the output base, and sky_engine is added', () {
    final Map<String, Object?> config = idePackageConfig(
      bazelConfig,
      workspace: '/ws',
      outputBase: '/ob',
      flutterRoot: '/sdk',
    );
    final roots = <String, String>{
      for (final p
          in (config['packages']! as List<Object?>)
              .cast<Map<String, Object?>>())
        p['name']! as String: p['rootUri']! as String,
    };
    expect(roots, <String, String>{
      'flutter': 'file:///ob/external/hub__flutter/',
      'counter_lib': 'file:///ws/packages/counter_lib/',
      'counter': 'file:///ws/',
      'other': 'file:///elsewhere/',
      'sky_engine': 'file:///sdk/bin/cache/pkg/sky_engine/',
    });
    expect(config['generator'], 'flutter_dev');
    // The input is left as it was.
    expect(
      ((bazelConfig['packages']! as List<Object?>).first!
          as Map<String, Object?>)['rootUri'],
      startsWith('org-dartlang-app'),
    );
  });

  test('the package graph: the root depends on every other package', () {
    final Map<String, Object?> config = idePackageConfig(
      bazelConfig,
      workspace: '/ws',
      outputBase: '/ob',
      flutterRoot: '/sdk',
    );
    final Map<String, Object?> graph = packageGraph(config, 'counter');
    expect(graph['roots'], <String>['counter']);
    final List<Map<String, Object?>> packages =
        (graph['packages']! as List<Object?>).cast<Map<String, Object?>>();
    expect(packages.first['dependencies'], <String>[
      'counter_lib',
      'flutter',
      'other',
    ]);
    expect(packages.map((Map<String, Object?> p) => p['name']), <String>[
      'counter',
      'counter_lib',
      'flutter',
      'other',
    ]);
  });

  test('writeIfChanged leaves an equal file alone', () {
    final path = '${tmp.path}/a/b.json';
    expect(writeIfChanged(path, 'x'), isTrue);
    final DateTime stamp = File(path).lastModifiedSync();
    expect(writeIfChanged(path, 'x'), isFalse);
    expect(File(path).lastModifiedSync(), stamp);
    expect(writeIfChanged(path, 'y'), isTrue);
  });

  group('generated sources', () {
    late String ws;
    late String out;
    setUp(() {
      ws = '${tmp.path}/ws';
      out = '${tmp.path}/out';
      Directory(ws).createSync();
      for (final name in <String>['a.dart', 'b.dart', 'l10n.dart']) {
        File('$out/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync('// $name');
      }
    });
    GeneratedSource source(String path, String generator, String file) =>
        GeneratedSource(path: path, generator: generator, output: '$out/$file');
    String targetOf(GeneratedSource s) => s.output;

    test(
      'are linked at their workspace paths, and links no longer wanted go',
      () {
        final state = State.load(ws);
        linkGeneratedSources(
          workspace: ws,
          sources: <GeneratedSource>[
            source('lib/a.dart', '//:gen', 'a.dart'),
            source('lib/sub/b.dart', '//:gen', 'b.dart'),
          ],
          targetOf: targetOf,
          skip: const <String>{},
          state: state,
        );
        expect(Link('$ws/lib/a.dart').targetSync(), '$out/a.dart');
        expect(File('$ws/lib/sub/b.dart').readAsStringSync(), '// b.dart');
        expect(state.links, <String>['lib/a.dart', 'lib/sub/b.dart']);
        state.save();

        final again = State.load(ws);
        expect(again.links, <String>['lib/a.dart', 'lib/sub/b.dart']);
        linkGeneratedSources(
          workspace: ws,
          sources: <GeneratedSource>[source('lib/a.dart', '//:gen', 'a.dart')],
          targetOf: targetOf,
          skip: const <String>{},
          state: again,
        );
        expect(
          FileSystemEntity.typeSync('$ws/lib/sub/b.dart', followLinks: false),
          FileSystemEntityType.notFound,
        );
        expect(again.links, <String>['lib/a.dart']);
      },
    );

    test("the stock generator's outputs are not linked, and an earlier link of ours is removed", () {
      final state = State.load(ws);
      final GeneratedSource l10n = source(
        'lib/l10n/x.dart',
        '//:l10n',
        'l10n.dart',
      );
      linkGeneratedSources(
        workspace: ws,
        sources: <GeneratedSource>[l10n],
        targetOf: targetOf,
        skip: const <String>{},
        state: state,
      );
      expect(Link('$ws/lib/l10n/x.dart').existsSync(), isTrue);
      linkGeneratedSources(
        workspace: ws,
        sources: <GeneratedSource>[l10n],
        targetOf: targetOf,
        skip: const <String>{'//:l10n'},
        state: state,
      );
      expect(
        FileSystemEntity.typeSync('$ws/lib/l10n/x.dart', followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(state.links, isEmpty);
    });

    test('a file in the way is replaced only when it has the same bytes', () {
      final state = State.load(ws);
      File('$ws/lib/a.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('// a.dart');
      linkGeneratedSources(
        workspace: ws,
        sources: <GeneratedSource>[source('lib/a.dart', '//:gen', 'a.dart')],
        targetOf: targetOf,
        skip: const <String>{},
        state: state,
      );
      expect(FileSystemEntity.isLinkSync('$ws/lib/a.dart'), isTrue);

      File('$ws/lib/b.dart').writeAsStringSync('hand-written');
      expect(
        () => linkGeneratedSources(
          workspace: ws,
          sources: <GeneratedSource>[source('lib/b.dart', '//:gen', 'b.dart')],
          targetOf: targetOf,
          skip: const <String>{},
          state: state,
        ),
        throwsA(
          isA<UsageException>().having(
            (UsageException e) => e.message,
            'message',
            contains('lib/b.dart'),
          ),
        ),
      );
      expect(File('$ws/lib/b.dart').readAsStringSync(), 'hand-written');
    });
  });

  test('workspace paths of outputs', () {
    expect(
      workspacePath('bazel-out/k8-dbg-ST-1/bin/lib/l10n/x.dart'),
      'lib/l10n/x.dart',
    );
    expect(workspacePath('lib/x.dart'), 'lib/x.dart');
  });
}
