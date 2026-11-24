import 'dart:io';

import 'package:test/test.dart';

import 'project_layout.dart';

/// Lays out real projects from manifests and checks the tree: where each
/// input is linked, and what the generated package config, pubspec stubs,
/// manifests and wrapper options say.

late Directory tmp;

/// Writes `tmp/in/<path>` and returns its path.
String input(String path, [String content = '// x\n']) {
  final file = File('${tmp.path}/in/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(content);
  return file.path;
}

String read(String path) => File(path).readAsStringSync();

/// [path] spelled with `/` only: Windows reports a link's target and a
/// listing's entries with `\`, a path built from `tmp.path` and `/` has both.
String fwd(String path) => path.replaceAll(r'\', '/');

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('project_layout.'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('stages main and external files, stubs and options', () {
    final String lib = input('pkg/a/lib/a.dart');
    final String dep = input('pkg/b/lib/b.dart');
    final String ext = input('external/ext/lib/e.dart');
    final String opts = input('analysis_options.yaml', 'linter: {}\n');
    final project = '${tmp.path}/out/t.proj';
    final manifest = LayoutManifest.parse(
      [
        'name\tt',
        'sdk\t3.13.5',
        'named\t0',
        'pkg\ta\tpkg/a\t3.11\t',
        'pkg\tb\tpkg/b\t\t',
        'pkg\text\t../ext\t3.0\t',
        'pkg\ta\tpkg/other\t\t',
        'file\t$dep\tpkg/b/lib/b.dart\t\t0',
        'file\t$ext\t../ext/lib/e.dart\texternal/ext\t0',
        'file\t$lib\tpkg/a/lib/a.dart\t\t0',
        'file\t$opts\tanalysis_options.yaml\t\t0',
        'own\t$lib\tpkg/a/lib/a.dart',
        'options\t$opts\tanalysis_options.yaml',
      ].join('\n'),
    );
    layOutProject(manifest, project);

    expect(fwd(Link('$project/src/pkg/a/lib/a.dart').targetSync()), fwd(lib));
    expect(fwd(Link('$project/src/pkg/b/lib/b.dart').targetSync()), fwd(dep));
    expect(
      fwd(Link('${tmp.path}/out/t.extpkgs/ext/lib/e.dart').targetSync()),
      fwd(ext),
    );
    expect(
      read('$project/.dart_tool/src_manifest.txt'),
      'analysis_options.yaml\npkg/a/lib/a.dart\npkg/a/pubspec.yaml\n'
      'pkg/b/lib/b.dart\npkg/b/pubspec.yaml\n',
    );
    expect(
      read('$project/.dart_tool/extpkgs_manifest.txt'),
      'ext/lib/e.dart\n',
    );
    expect(
      read('$project/.dart_tool/package_config.json'),
      '{\n  "configVersion": 2,\n  "packages": [\n'
      '    {"name": "a", "rootUri": "../src/pkg/a", "packageUri": "lib/", '
      '"languageVersion": "3.11"},\n'
      '    {"name": "b", "rootUri": "../src/pkg/b", "packageUri": "lib/"},\n'
      '    {"name": "ext", "rootUri": "../../t.extpkgs/ext", '
      '"packageUri": "lib/", "languageVersion": "3.0"}\n'
      '  ]\n}\n',
    );
    expect(
      read('$project/src/pkg/a/pubspec.yaml'),
      'name: a\nenvironment:\n  sdk: "^3.11.0"\n'
      'dependencies:\n  b: any\n  ext: any\n',
    );
    expect(
      read('$project/pubspec.yaml'),
      'name: analyze_stub\nenvironment:\n  sdk: "^3.13.0"\n'
      'dependencies:\n  a: any\n  b: any\n  ext: any\n',
    );
    // The options file above the own file governs it and is analyzed; the
    // dependency and the stubs are not.
    expect(
      read('$project/analysis_options.yaml'),
      '# rules_dart: staged project root\nanalyzer:\n  exclude:\n'
      '    - "src/pkg/b/lib/b.dart"\n'
      '    - "src/pkg/a/pubspec.yaml"\n'
      '    - "src/pkg/b/pubspec.yaml"\n',
    );

    removeLayout(project);
    expect(Directory('${tmp.path}/out').listSync(), isEmpty);
  });

  test('names unstaged external packages when asked', () {
    final String lib = input('lib/a.dart');
    final project = '${tmp.path}/out/t.proj';
    layOutProject(
      LayoutManifest.parse(
        [
          'name\tt',
          'named\t1',
          'pkg\ta\t\t\t',
          'pkg\text\t../ext/sub\t\t',
          'file\t$lib\tlib/a.dart\t\t0',
          'own\t$lib\tlib/a.dart',
        ].join('\n'),
      ),
      project,
    );
    expect(
      read('$project/.dart_tool/package_config.json'),
      contains('{"name": "ext", "rootUri": "../../t.extpkgs/ext/sub"'),
    );
    expect(read('$project/src/pubspec.yaml'), startsWith('name: a\n'));
  });

  test('links the files of a directory input and lists no manifest', () {
    input('gen/pkg/lib/x.dart');
    input('gen/pkg/lib/y/z.dart');
    final project = '${tmp.path}/out/t.proj';
    layOutProject(
      LayoutManifest.parse(
        [
          'name\tt',
          'pkg\tpkg\tgen/pkg\t\t',
          'file\t${tmp.path}/in/gen/pkg\tgen/pkg\t\t1',
        ].join('\n'),
      ),
      project,
    );
    expect(File('$project/src/gen/pkg/lib/y/z.dart').existsSync(), isTrue);
    expect(read('$project/.dart_tool/src_manifest.txt'), '*\n');
  });

  test('applyLayoutArgs strips the flag and lays out --project', () {
    final String lib = input('lib/a.dart');
    final manifest = File('${tmp.path}/m')
      ..writeAsStringSync('name\tt\nfile\t$lib\tlib/a.dart\t\t0\n');
    final project = '${tmp.path}/out/t.proj';
    final ({List<String> args, String? project}) laidOut = applyLayoutArgs([
      '--dart',
      'd',
      '--layout',
      manifest.path,
      '--project',
      project,
    ]);
    expect(laidOut.args, ['--dart', 'd', '--project', project]);
    expect(laidOut.project, project);
    expect(File('$project/src/lib/a.dart').existsSync(), isTrue);
  });

  group('package records', () {
    String manifest(List<String> pkgs) => [
      'name\tt',
      'origin\tthe dependencies of //app:app',
      ...pkgs.take(1),
      'origin\tthe analysis config //:analysis_config',
      ...pkgs.skip(1),
    ].join('\n');

    test('that state different versions fail, naming both', () {
      expect(
        () => LayoutManifest.parse(
          manifest([
            'pkg\text\t../hub_a\t3.0\t\t1.0.0',
            'pkg\text\t../hub_b\t3.0\t\t2.0.0',
          ]),
        ),
        throwsA(
          isA<LayoutException>().having(
            (e) => fwd(e.message),
            'message',
            allOf(
              startsWith(
                'Package "ext" is supplied more than once with different '
                'versions:\n'
                '  - 1.0.0 (../hub_a, from the dependencies of //app:app)\n'
                '  - 2.0.0 (../hub_b, from the analysis config '
                '//:analysis_config)\n',
              ),
              contains('Reconcile the lock files'),
            ),
          ),
        ),
      );
    });

    test('that state different language versions fail', () {
      expect(
        () => LayoutManifest.parse(
          manifest(['pkg\ta\tpkg/a\t3.11\t\t', 'pkg\ta\tpkg/a\t3.13\t\t']),
        ),
        throwsA(
          isA<LayoutException>().having(
            (e) => e.message,
            'message',
            startsWith(
              'Package "a" is supplied more than once with different '
              'language versions:\n'
              '  - 3.11 (pkg/a, from the dependencies of //app:app)\n'
              '  - 3.13 (pkg/a, from the analysis config //:analysis_config)\n',
            ),
          ),
        ),
      );
    });

    test('that agree keep the first, even at another root', () {
      // One package supplied by two pub hubs: unknown values agree with any.
      final m = LayoutManifest.parse(
        manifest([
          'pkg\text\t../hub_a\t3.0\t\t1.0.0',
          'pkg\text\t../hub_b\t\t\t',
        ]),
      );
      expect([for (final p in m.packages) p.libRoot], ['../hub_a']);
    });
  });

  test('a directory input keeps its own pubspec.yaml over the stub', () {
    input('gen/pkg/pubspec.yaml', 'name: pkg\n');
    final String x = input('gen/pkg/lib/x.dart');
    final project = '${tmp.path}/out/t.proj';
    layOutProject(
      LayoutManifest.parse(
        [
          'name\tt',
          'pkg\tpkg\tgen/pkg\t\t',
          'file\t${tmp.path}/in/gen/pkg\tgen/pkg\t\t1',
          'own\t$x\tgen/pkg/lib/x.dart',
        ].join('\n'),
      ),
      project,
    );
    expect(
      fwd(Link('$project/src/gen/pkg/pubspec.yaml').targetSync()),
      fwd('${tmp.path}/in/gen/pkg/pubspec.yaml'),
    );
    expect(
      read('$project/analysis_options.yaml'),
      isNot(contains('"src/gen/pkg/pubspec.yaml"')),
    );
  });

  group('two inputs on one staged path', () {
    // A file listed beside the directory that also holds it: one short path.
    String layOut(String fileContent) {
      input('gen/pkg/lib/x.dart', '// dir\n');
      final String file = input('copy/x.dart', fileContent);
      final project = '${tmp.path}/out/t.proj';
      layOutProject(
        LayoutManifest.parse(
          [
            'name\tt',
            'pkg\tpkg\tgen/pkg\t\t',
            'file\t${tmp.path}/in/gen/pkg\tgen/pkg\t\t1',
            'file\t$file\tgen/pkg/lib/x.dart\t\t0',
          ].join('\n'),
        ),
        project,
      );
      return project;
    }

    test('with the same bytes stage one', () {
      final String project = layOut('// dir\n');
      expect(read('$project/src/gen/pkg/lib/x.dart'), '// dir\n');
    });

    test('with different bytes fail, naming the path', () {
      expect(
        () => layOut('// other\n'),
        throwsA(
          isA<LayoutException>().having(
            (e) => fwd(e.message),
            'message',
            allOf(
              startsWith(
                'Two inputs would be staged at '
                '`${fwd(tmp.path)}/out/t.proj/src/gen/pkg/lib/x.dart`:\n',
              ),
              contains('${fwd(tmp.path)}/in/gen/pkg/lib/x.dart'),
              contains('${fwd(tmp.path)}/in/copy/x.dart'),
            ),
          ),
        ),
      );
    });
  });
}
