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
      'snapshot args compile the staged entry and packages under org-dartlang-app',
      () {
        const stageRootUri =
            'file:///execroot/_main/bazel-out/k8-fastbuild/bin/pkg/app.dart2js_cfe.1234.stage/';
        final List<String> args = buildDart2JsSnapshotArgs(
          forwardArgs: [
            '--packages=/tmp/rewritten/package_config.json',
            '--cfe-only',
            '-Ddart.vm.product=true',
            '-o',
            'out.dill',
          ],
          rewrittenPkgPath: '/tmp/rewritten/package_config.json',
          stageRootUri: stageRootUri,
          normMainDart: 'pkg/lib/main.dart',
        );

        expect(args, contains('--multi-root-scheme=org-dartlang-app'));
        // The js frontend mounts the staging tree itself as a `file:`
        // multi-root — never the execroot — so the compile reads only
        // declared inputs whatever the strategy.
        expect(args, contains('--multi-root=$stageRootUri'));
        expect(args, contains('org-dartlang-app:///pkg/lib/main.dart'));
        expect(args, contains('--packages=/tmp/rewritten/package_config.json'));
        for (final a in args) {
          expect(a, isNot(contains('sandbox')));
        }
        expect(
          args.last,
          'org-dartlang-app:///pkg/lib/main.dart',
        );
      },
    );

    test('stage root URIs name the staging directory', () {
      expect(
        stageRootUri('pkg/app.dart2js.1234.stage'),
        startsWith('file:'),
      );
      expect(
        stageRootUri('pkg/app.dart2js.1234.stage'),
        endsWith('/pkg/app.dart2js.1234.stage/'),
      );
      expect(
        stageRootUri(
          'file:///execroot/_main/bazel-out/k8-fastbuild/bin/pkg/app.stage/',
        ),
        'file:///execroot/_main/bazel-out/k8-fastbuild/bin/pkg/app.stage/',
      );
    });
  });

  group('scrubDart2JsOutputs', () {
    test(
      'rewrites temp package_config.json, stage, and cwd file URIs in .deps, .map, and .info.json',
      () {
        final fakeCwd = Directory('${_tmp.path}/execroot/_main')
          ..createSync(recursive: true);
        final stageDir = Directory(
          '${fakeCwd.path}/bazel-out/k8-fastbuild/bin/pkg/app_stage',
        )..createSync(recursive: true);
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

        final stageUri = Uri.directory(stageDir.path).toString();
        final cwdUri = Uri.directory(fakeCwd.path).toString();
        final rewrittenPkgUri = Uri.file(rewrittenPkgFile.path).toString();

        final depsFile = File('${outDir.path}/main.dart.js.deps')
          ..writeAsStringSync(
            '${stageUri}pkg/lib/main.dart\n'
            '$rewrittenPkgUri\n'
            '${cwdUri}external/flutter_sdk/lib/core.dart\n'
            'org-dartlang-sdk:///lib/core/core.dart\n',
          );
        final mapFile = File('${outDir.path}/main.dart.js.map')
          ..writeAsStringSync(
            '{"sources":["../../app_stage/pkg/lib/main.dart","${stageUri}pkg/lib/other.dart"]}',
          );
        final infoFile = File('${outDir.path}/main.dart.js.info.json')
          ..writeAsStringSync(
            '{"compilationMoment": "2026-04-18 12:34:56.789012", '
            '"compilationDuration": 12345, '
            '"toJsonDuration": 678, '
            '"dumpInfoDuration": 90, '
            '"uri": "${stageUri}pkg/lib/main.dart", '
            '"rel": "bazel-out/k8-fastbuild/bin/pkg/app_stage/pkg/lib/main.dart"}',
          );

        scrubDart2JsOutputs(
          outDir,
          cwdPath: fakeCwd.path,
          rootDirPath: stageDir.path,
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
        expect(infoContent, isNot(contains('app_stage')));
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

    test(
      'staged app-scheme URIs normalize to their unstaged form in .deps',
      () {
        final fakeCwd = Directory('${_tmp.path}/execroot/_main')
          ..createSync(recursive: true);
        final outDir = Directory(
          '${fakeCwd.path}/bazel-out/k8-fastbuild/bin/pkg/app_dart2js_cfe',
        )..createSync(recursive: true);
        final depsFile = File('${outDir.path}/app.dill.deps')
          ..writeAsStringSync(
            'org-dartlang-app:///flutter/tests/pkg/app.dart2js_cfe.1234.stage/flutter/tests/pkg/lib/main.dart\n'
            'org-dartlang-app:///flutter/tests/pkg/lib/main.dart\n'
            'org-dartlang-sdk:///lib/core/core.dart\n',
          );

        scrubDart2JsOutputs(outDir, cwdPath: fakeCwd.path);

        final List<String> depsLines = depsFile
            .readAsStringSync()
            .split('\n')
            .where((l) => l.isNotEmpty)
            .toList();
        expect(
          depsLines,
          equals([
            'org-dartlang-app:///flutter/tests/pkg/lib/main.dart',
            'org-dartlang-sdk:///lib/core/core.dart',
          ]),
        );
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
