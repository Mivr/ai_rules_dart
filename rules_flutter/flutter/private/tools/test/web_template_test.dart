import 'dart:io';

import 'package:test/test.dart';

// Import the library directly.
import '../web_template.dart';

late Directory _tmp;

void main() {
  setUp(() => _tmp = Directory.systemTemp.createTempSync('web_template_test'));
  tearDown(() => _tmp.deleteSync(recursive: true));

  group('dart2js stable scheme', () {
    test(
      'snapshot args compile the entry and packages under org-dartlang-app across every root',
      () {
        const binRootUri = 'file:///execroot/_main/bazel-out/k8-fastbuild/bin/';
        const execRootUri = 'file:///execroot/_main/';
        final List<String> args = buildDart2JsSnapshotArgs(
          forwardArgs: [
            '--packages=/tmp/rewritten/package_config.json',
            '--cfe-only',
            '-Ddart.vm.product=true',
            '-o',
            'out.dill',
          ],
          rewrittenPkgPath: '/tmp/rewritten/package_config.json',
          rootUris: [binRootUri, execRootUri],
          normMainDart: 'pkg/lib/main.dart',
        );

        expect(args, contains('--multi-root-scheme=org-dartlang-app'));
        // The generated root first, so a generated file shadows a source at
        // the same workspace path, then the exec root the sources sit in.
        final List<String> roots = [
          for (final a in args)
            if (a.startsWith('--multi-root=')) a,
        ];
        expect(roots, [
          '--multi-root=$binRootUri',
          '--multi-root=$execRootUri',
        ]);
        expect(args, contains('--packages=/tmp/rewritten/package_config.json'));
        for (final a in args) {
          expect(a, isNot(contains('sandbox')));
        }
        expect(args.last, 'org-dartlang-app:///pkg/lib/main.dart');
      },
    );

    test('root URIs name the directory, the exec root as `.`', () {
      final cwd = Uri.directory(
        Directory.current.absolute.path,
      ).normalizePath().toString();
      expect(rootDirUri('.'), cwd);
      expect(
        rootDirUri('bazel-out/k8-fastbuild/bin'),
        '${cwd}bazel-out/k8-fastbuild/bin/',
      );
      expect(
        rootDirUri('file:///execroot/_main/bazel-out/k8-fastbuild/bin'),
        'file:///execroot/_main/bazel-out/k8-fastbuild/bin/',
      );
    });
  });

  group('read set', () {
    test('dart2js .deps name their file: reads only', () {
      expect(
        dart2JsDepsReads(
          'file:///execroot/_main/pkg/lib/main.dart\n'
          'org-dartlang-app:///pkg/lib/main.dart\n'
          'file:///execroot/_main/a%20b/lib/x.dart\n'
          '\n',
        ),
        ['/execroot/_main/pkg/lib/main.dart', '/execroot/_main/a b/lib/x.dart'],
      );
    });

    test('a dart2wasm depfile names its prerequisites, escapes decoded', () {
      expect(
        depfileReads(
          'out/main.dart.wasm: /e/pkg/lib/main.dart /e/a\\ b/x.dart \\\n'
          ' /e/bazel-out/k8-fastbuild/bin/pkg/lib/gen.dart\n',
        ),
        [
          '/e/pkg/lib/main.dart',
          '/e/a b/x.dart',
          '/e/bazel-out/k8-fastbuild/bin/pkg/lib/gen.dart',
        ],
      );
    });

    test('only declared inputs and the scratch directory may be read', () {
      final manifest = File('${_tmp.path}/app.web_inputs')
        ..writeAsStringSync(
          'pkg/lib/main.dart\n'
          'bazel-out/k8-fastbuild/bin/pkg/lib/gen.dart\n'
          '# allowed-reads\n'
          'external/flutter_web_sdk/kernel/dart2js_platform.dill\n',
        );
      final Set<String> declared = readDeclaredInputs(manifest.path);
      expect(declared, {
        'pkg/lib/main.dart',
        'bazel-out/k8-fastbuild/bin/pkg/lib/gen.dart',
        'external/flutter_web_sdk/kernel/dart2js_platform.dill',
      });
      expect(
        undeclaredWebReads(
          [
            '/e/pkg/lib/main.dart',
            '/e/pkg//lib/../lib/main.dart',
            '/e/bazel-out/k8-fastbuild/bin/pkg/lib/gen.dart',
            'external/flutter_web_sdk/kernel/dart2js_platform.dill',
            '/e/out/_dart2js_tmp/package_config.json',
            // Undeclared: a source no target lists, a stale output, a host file.
            '/e/pkg/lib/undeclared.dart',
            '/e/bazel-out/k8-fastbuild/bin/pkg/lib/stale.dart',
            '/etc/passwd',
          ],
          declared,
          cwdPath: '/e',
          scratchPath: '/e/out/_dart2js_tmp',
        ),
        [
          '/e/pkg/lib/undeclared.dart',
          '/e/bazel-out/k8-fastbuild/bin/pkg/lib/stale.dart',
          '/etc/passwd',
        ],
      );
    });
  });

  group('scrubDart2JsOutputs', () {
    test(
      'rewrites temp package_config.json, output-directory and cwd file URIs in .deps, .map, and .info.json',
      () {
        final fakeCwd = Directory('${_tmp.path}/execroot/_main')
          ..createSync(recursive: true);
        final outDir = Directory(
          '${fakeCwd.path}/bazel-out/k8-fastbuild/bin/pkg/app_dart2js_fallback',
        )..createSync(recursive: true);
        final tmpDir = Directory('${outDir.path}/_dart2js_tmp')
          ..createSync(recursive: true);

        const relPkgPath =
            'bazel-out/k8-fastbuild/bin/pkg/app.package_config.json';
        final origPkgFile = File('${fakeCwd.path}/$relPkgPath')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('{"configVersion":2,"packages":[]}');
        final rewrittenPkgFile = File('${tmpDir.path}/package_config.json')
          ..writeAsStringSync('{"configVersion":2,"packages":[]}');
        tmpDir.deleteSync(recursive: true);

        final cwdUri = Uri.directory(fakeCwd.path).toString();
        final binUri = '${cwdUri}bazel-out/k8-fastbuild/bin/';
        final rewrittenPkgUri = Uri.file(rewrittenPkgFile.path).toString();

        final depsFile = File('${outDir.path}/main.dart.js.deps')
          ..writeAsStringSync(
            '${cwdUri}pkg/lib/main.dart\n'
            '${binUri}pkg/lib/main.g.dart\n'
            '$rewrittenPkgUri\n'
            '${cwdUri}external/flutter_sdk/lib/core.dart\n'
            'org-dartlang-sdk:///lib/core/core.dart\n',
          );
        final mapFile = File('${outDir.path}/main.dart.js.map')
          ..writeAsStringSync(
            '{"sources":["org-dartlang-app:///pkg/lib/main.dart","${binUri}pkg/lib/other.dart"]}',
          );
        final infoFile = File('${outDir.path}/main.dart.js.info.json')
          ..writeAsStringSync(
            '{"compilationMoment": "2026-04-18 12:34:56.789012", '
            '"compilationDuration": 12345, '
            '"toJsonDuration": 678, '
            '"dumpInfoDuration": 90, '
            '"uri": "${cwdUri}pkg/lib/main.dart", '
            '"rel": "bazel-out/k8-fastbuild/bin/pkg/lib/main.g.dart"}',
          );

        scrubDart2JsOutputs(
          outDir,
          cwdPath: fakeCwd.path,
          tmpDirPath: tmpDir.path,
          packagesPath: origPkgFile.path,
          rewrittenPkgPath: rewrittenPkgFile.path,
        );

        final List<String> depsLines = depsFile
            .readAsStringSync()
            .split('\n')
            .where((l) => l.isNotEmpty)
            .toList();
        expect(
          depsLines,
          equals([
            'org-dartlang-app:///external/flutter_sdk/lib/core.dart',
            'org-dartlang-app:///pkg/app.package_config.json',
            'org-dartlang-app:///pkg/lib/main.dart',
            'org-dartlang-app:///pkg/lib/main.g.dart',
            'org-dartlang-sdk:///lib/core/core.dart',
          ]),
        );

        final String mapContent = mapFile.readAsStringSync();
        expect(
          mapContent,
          equals(
            '{"sources":["org-dartlang-app:///pkg/lib/main.dart","org-dartlang-app:///pkg/lib/other.dart"]}',
          ),
        );

        final String infoContent = infoFile.readAsStringSync();
        expect(infoContent, isNot(contains('file:')));
        expect(infoContent, isNot(contains('bazel-out')));
        expect(
          infoContent,
          contains('"compilationMoment": "1970-01-01 00:00:00.000000"'),
        );
        expect(infoContent, contains('"compilationDuration": 0'));
        expect(infoContent, contains('"toJsonDuration": 0'));
        expect(infoContent, contains('"dumpInfoDuration": 0'));
      },
    );
  });

  group('scrubDart2JsFile', () {
    test(
      'normalizes only its own depfile, leaving a concurrent sibling untouched',
      () {
        // The base and canvaskit icon kernels compile concurrently into the
        // same `bin` dir, each with a private temp dir. A directory-wide scrub
        // is a read-modify-write of the sibling's depfile with only this
        // action's temp paths known: a scrub that read the sibling's file
        // while raw and wrote it back after the sibling's own scrub overwrote
        // the normalized file with a sorted-but-still-raw copy, and the
        // declared output differed per strategy (P-web-icon-dill-paths). The
        // `--cfe-only` path therefore scrubs exactly its own depfile.
        final fakeCwd = Directory('${_tmp.path}/execroot/_main')
          ..createSync(recursive: true);
        final binDir = Directory(
          '${fakeCwd.path}/bazel-out/k8-fastbuild/bin',
        )..createSync(recursive: true);

        const relPkgPath =
            'bazel-out/k8-fastbuild/bin/web_app.package_config.json';
        final origPkgFile = File('${fakeCwd.path}/$relPkgPath')
          ..createSync(recursive: true)
          ..writeAsStringSync('{"configVersion":2,"packages":[]}');

        final ownTmp = '${_tmp.path}/rules_flutter_dart2js_cfe_own';
        final ownPkgUri = Uri.file('$ownTmp/package_config.json').toString();
        final siblingTmp = '${_tmp.path}/rules_flutter_dart2js_cfe_sibling';
        final siblingPkgUri = Uri.file('$siblingTmp/package_config.json')
            .toString();

        final ownDeps =
            File(
              '${binDir.path}/web_app_icon_tree_shaking.dill.deps',
            )..writeAsStringSync(
              'org-dartlang-app:///pkg/lib/main.dart\n'
              '$ownPkgUri\n'
              'org-dartlang-sdk:///lib/core/core.dart\n',
            );
        final siblingDeps =
            File(
              '${binDir.path}/web_app_icon_tree_shaking_canvaskit.dill.deps',
            )..writeAsStringSync(
              'org-dartlang-app:///pkg/lib/main.dart\n'
              '$siblingPkgUri\n'
              'org-dartlang-sdk:///lib/core/core.dart\n',
            );
        final String siblingBefore = siblingDeps.readAsStringSync();

        scrubDart2JsFile(
          ownDeps,
          cwdPath: fakeCwd.path,
          tmpDirPath: ownTmp,
          packagesPath: origPkgFile.path,
          rewrittenPkgPath: '$ownTmp/package_config.json',
        );

        expect(
          ownDeps.readAsStringSync().split('\n').where((l) => l.isNotEmpty),
          equals([
            'org-dartlang-app:///pkg/lib/main.dart',
            'org-dartlang-app:///web_app.package_config.json',
            'org-dartlang-sdk:///lib/core/core.dart',
          ]),
        );
        // The sibling's raw depfile is byte-identical: this scrub never
        // touched a file its action does not own.
        expect(siblingDeps.readAsStringSync(), equals(siblingBefore));
        expect(siblingDeps.readAsStringSync(), contains(siblingPkgUri));
      },
    );
  });
}
