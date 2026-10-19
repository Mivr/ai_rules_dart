import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/sdk/build_sdk_summary.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:bazel_worker/bazel_worker.dart';
import 'package:build/build.dart';
import 'package:glob/glob.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:rules_dart_ext/builder_shim.dart';
import 'package:rules_dart_ext/worker_entry.dart';
import 'package:test/test.dart';

/// Minimum set of args any valid shim invocation must supply. Per-test
/// overrides are appended; omit an arg by not including it in `overrides`
/// and also naming it in a `removed` list (not needed for most tests).
List<String> _baseArgs({
  Map<String, String> overrides = const {},
  List<String> removed = const [],
}) {
  final args = {
    '--input': 'a.dart',
    '--input-asset': 'lib/a.dart',
    '--output': 'a.g.dart',
    '--package': 'p',
    '--root-language-version': '3.11',
  };
  args.addAll(overrides);
  for (final r in removed) {
    args.remove(r);
  }
  return [
    for (final e in args.entries) ...[e.key, e.value],
  ];
}

/// Stable URI string for a LibraryElement. Used by the Resolver.libraries
/// tests to compare yielded libraries by `package:foo/bar.dart` shape.
String _libUriString(LibraryElement lib) =>
    lib.firstFragment.source.uri.toString();

ShimArgs _shimArgs({
  required String inputPath,
  required String inputAssetPath,
  required String outputPath,
  List<String>? outputPaths,
  String packageName = 'fixture',
  List<({String exec, String asset})> depPaths = const [],
  Map<String, dynamic> config = const {},
  LanguageVersion? rootLanguageVersion,
  String? packageConfigPath,
}) => ShimArgs(
  inputPath: inputPath,
  inputAssetPath: inputAssetPath,
  outputPaths: outputPaths ?? [outputPath],
  packageName: packageName,
  depPaths: depPaths,
  config: config,
  rootLanguageVersion: rootLanguageVersion ?? LanguageVersion(3, 11),
  packageConfigUri: packageConfigPath,
);

/// Writes a fake foreign Dart package under [root] named [name] with a
/// single library file `lib/<name>.dart` (the conventional public
/// re-export location). Returns the package directory.
///
/// Used by the Resolver.libraries tests to exercise the cross-package
/// fallback without depending on whatever pub graph the test runner's
/// isolate happens to expose.
Directory _writeForeignPackage({
  required Directory root,
  required String name,
  String libBody = 'class Foo {}\n',
}) {
  final pkgDir = Directory(p.join(root.path, '${name}_pkg'))
    ..createSync(recursive: true);
  Directory(p.join(pkgDir.path, 'lib')).createSync(recursive: true);
  File(p.join(pkgDir.path, 'lib', '$name.dart')).writeAsStringSync(libBody);
  return pkgDir;
}

/// Writes a `package_config.json` at [root]/package_config.json that
/// includes [packages] (each a Directory whose name is `<pkg>_pkg`).
/// Returns the file path.
String _writePackageConfig({
  required Directory root,
  required List<Directory> packages,
}) {
  final entries = <Map<String, dynamic>>[];
  for (final pkg in packages) {
    // Strip the trailing marker only — `replaceAll` would also eat it out of
    // the middle of a package name that happens to contain `_pkg`.
    final dirName = p.basename(pkg.path);
    final name = dirName.endsWith('_pkg')
        ? dirName.substring(0, dirName.length - '_pkg'.length)
        : dirName;
    entries.add({
      'name': name,
      'rootUri': Uri.directory(pkg.path).toString(),
      'packageUri': 'lib/',
      'languageVersion': '3.0',
    });
  }
  final file = File(p.join(root.path, 'package_config.json'));
  file.writeAsStringSync(jsonEncode({'configVersion': 2, 'packages': entries}));
  return file.path;
}

void main() {
  group('stagedPath', () {
    test(
      'joins a POSIX asset under a native Windows dir, no mixed separators',
      () {
        final dest = stagedPath(
          p.windows,
          r'C:\tmp\shim_x',
          'test/nice_mock_test.dart',
        );
        expect(dest, r'C:\tmp\shim_x\test\nice_mock_test.dart');
        expect(dest, isNot(contains('/')));
      },
    );

    test('handles a nested lib/ asset under a native Windows dir', () {
      expect(
        stagedPath(p.windows, r'C:\s', 'lib/src/models/user.dart'),
        r'C:\s\lib\src\models\user.dart',
      );
    });

    test('is a plain join in the posix context', () {
      expect(
        stagedPath(p.posix, '/tmp/shim_x', 'lib/src/a.dart'),
        '/tmp/shim_x/lib/src/a.dart',
      );
    });

    test('the naive p.join leaves the mixed separators we must avoid', () {
      // platform-context join inserts `\` but does not transcode the asset
      // path's inner `/`, producing the mixed path the analyzer rejects.
      expect(
        p.windows.join(r'C:\tmp\shim_x', 'test/nice_mock_test.dart'),
        r'C:\tmp\shim_x\test/nice_mock_test.dart',
      );
    });
  });

  group('ShimArgs.parse', () {
    test('parses the minimal required arg set', () {
      final args = ShimArgs.parse(_baseArgs());
      expect(args.inputPath, 'a.dart');
      expect(args.outputPaths, ['a.g.dart']);
      expect(args.packageName, 'p');
      expect(args.rootLanguageVersion.major, 3);
      expect(args.rootLanguageVersion.minor, 11);
      expect(args.depPaths, isEmpty);
      expect(args.config, isEmpty);
    });

    test('parses repeatable --output (one per declared Bazel output)', () {
      final args = ShimArgs.parse([
        ..._baseArgs(removed: ['--output']),
        '--output',
        'a.config.dart',
        '--output',
        'a.module.dart',
      ]);
      expect(args.outputPaths, ['a.config.dart', 'a.module.dart']);
    });

    test('--package is required (no silent basename fallback)', () {
      expect(
        () => ShimArgs.parse(_baseArgs(removed: ['--package'])),
        throwsA(isA<FormatException>()),
      );
    });

    test('--root-language-version is required (no silent 3.0 default)', () {
      expect(
        () => ShimArgs.parse(_baseArgs(removed: ['--root-language-version'])),
        throwsA(isA<FormatException>()),
      );
    });

    test('--root-language-version rejects malformed input', () {
      expect(
        () => ShimArgs.parse(
          _baseArgs(overrides: {'--root-language-version': 'not-a-version'}),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ShimArgs.parse(
          _baseArgs(overrides: {'--root-language-version': '3'}),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ShimArgs.parse(
          _baseArgs(overrides: {'--root-language-version': 'abc.def'}),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('--config rejects non-object JSON', () {
      expect(
        () => ShimArgs.parse(
          _baseArgs(overrides: {'--config': '"a string is not an object"'}),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('JSON object'),
          ),
        ),
      );
    });

    test('--config rejects malformed JSON', () {
      expect(
        () => ShimArgs.parse(_baseArgs(overrides: {'--config': '{not valid'})),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Parse error'),
          ),
        ),
      );
    });

    test('parses --config JSON object', () {
      final args = ShimArgs.parse(
        _baseArgs(overrides: {'--config': '{"createFactory": false}'}),
      );
      expect(args.config, {'createFactory': false});
    });

    test('parses repeatable --dep (exec|asset form)', () {
      final args = ShimArgs.parse([
        ..._baseArgs(),
        '--dep',
        'exec/sibling1.dart|lib/sibling1.dart',
        '--dep',
        'exec/sibling2.dart|lib/src/sibling2.dart',
      ]);
      expect(args.depPaths.map((d) => d.exec), [
        'exec/sibling1.dart',
        'exec/sibling2.dart',
      ]);
      expect(args.depPaths.map((d) => d.asset), [
        'lib/sibling1.dart',
        'lib/src/sibling2.dart',
      ]);
    });

    test('--dep without pipe separator rejected', () {
      expect(
        () => ShimArgs.parse([..._baseArgs(), '--dep', 'no-pipe.dart']),
        throwsA(isA<FormatException>()),
      );
    });

    test('--input-asset is required', () {
      expect(
        () => ShimArgs.parse(_baseArgs(removed: ['--input-asset'])),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects unknown flags', () {
      expect(
        () => ShimArgs.parse([..._baseArgs(), '--bogus', 'x']),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects positional args', () {
      expect(
        () => ShimArgs.parse([..._baseArgs(), 'extra']),
        throwsA(isA<FormatException>()),
      );
    });

    test('requires --input', () {
      expect(
        () => ShimArgs.parse(_baseArgs(removed: ['--input'])),
        throwsA(isA<FormatException>()),
      );
    });

    test('requires --output', () {
      expect(
        () => ShimArgs.parse(_baseArgs(removed: ['--output'])),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('runShimWithArgs', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('shim_test_');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('a no-op Builder writes an empty output file', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: "lib/src.dart",
          outputPath: output.path,
        ),
        (_) => _NoopBuilder(),
      );

      expect(output.existsSync(), isTrue);
      expect(output.readAsStringSync(), isEmpty);
    });

    test('a fixed-output Builder writes its emitted contents', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: "lib/src.dart",
          outputPath: output.path,
        ),
        (_) => _FixedOutputBuilder('// emitted by fixed builder\n'),
      );

      expect(output.readAsStringSync(), '// emitted by fixed builder\n');
    });

    test('a throwing Builder propagates the error', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      await expectLater(
        runShimWithArgs(
          _shimArgs(
            inputPath: input.path,
            inputAssetPath: "lib/src.dart",
            outputPath: output.path,
          ),
          (_) => _ThrowingBuilder(),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('reader exposes declared deps to the Builder', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final dep = File(p.join(tmp.path, 'sibling.dart'))
        ..writeAsStringSync('class Bar {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      String? siblingContent;
      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/src.dart',
          outputPath: output.path,
          depPaths: [(exec: dep.path, asset: 'lib/sibling.dart')],
        ),
        (_) => _CapturingBuilder((step) async {
          final id = AssetId('fixture', 'lib/sibling.dart');
          siblingContent = await step.readAsString(id);
        }),
      );

      expect(siblingContent, 'class Bar {}');
    });

    test('routes each emitted asset to the matching declared output', () async {
      // Mirrors a multi-output builder shape: one input → two outputs
      // (.config.dart + .module.dart). Each declared Bazel output must end
      // up with the bytes of the matching emission.
      final input = File(p.join(tmp.path, 'app.dart'))
        ..writeAsStringSync('class App {}');
      final configOut = File(p.join(tmp.path, 'app.config.dart'));
      final moduleOut = File(p.join(tmp.path, 'app.module.dart'));

      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/app.dart',
          outputPath: configOut.path,
          outputPaths: [configOut.path, moduleOut.path],
        ),
        (_) => _MultiOutputBuilder({
          '.config.dart': '// config body\n',
          '.module.dart': '// module body\n',
        }),
      );

      expect(configOut.readAsStringSync(), '// config body\n');
      expect(moduleOut.readAsStringSync(), '// module body\n');
    });

    test(
      'declared output with no matching emission writes empty bytes',
      () async {
        final input = File(p.join(tmp.path, 'app.dart'))
          ..writeAsStringSync('class App {}');
        final configOut = File(p.join(tmp.path, 'app.config.dart'));
        final moduleOut = File(p.join(tmp.path, 'app.module.dart'));

        await runShimWithArgs(
          _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/app.dart',
            outputPath: configOut.path,
            outputPaths: [configOut.path, moduleOut.path],
          ),
          (_) => _MultiOutputBuilder({'.config.dart': '// only config\n'}),
        );

        expect(configOut.readAsStringSync(), '// only config\n');
        expect(moduleOut.existsSync(), isTrue);
        expect(moduleOut.readAsStringSync(), isEmpty);
      },
    );

    test('reader rejects undeclared assets', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      Object? caught;
      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: "lib/src.dart",
          outputPath: output.path,
        ),
        (_) => _CapturingBuilder((step) async {
          try {
            await step.readAsString(AssetId('fixture', 'lib/missing.dart'));
          } catch (e) {
            caught = e;
          }
        }),
      );

      expect(caught, isA<AssetNotFoundException>());
    });
  });

  group('Resolver.libraries', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('shim_resolver_libs_');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('yields same-package staged libraries (input + each --dep)', () async {
      // Baseline: the input file and every --dep file in the same package
      // must appear in Resolver.libraries.
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final dep = File(p.join(tmp.path, 'sibling.dart'))
        ..writeAsStringSync('class Bar {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      Set<String> uris = {};
      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/src.dart',
          outputPath: output.path,
          depPaths: [(exec: dep.path, asset: 'lib/sibling.dart')],
        ),
        (_) => _CapturingBuilder((step) async {
          final libs = await step.resolver.libraries.toList();
          uris = libs.map(_libUriString).toSet();
        }),
      );

      // Both staged files, by name. `any(startsWith('package:fixture/'))`
      // would also be satisfied by the synthetic `package:fixture/fixture.dart`
      // the config loop yields for the root package, so it would pass with the
      // staged loop removed entirely.
      expect(
        uris,
        containsAll(<String>[
          'package:fixture/src.dart',
          'package:fixture/sibling.dart',
        ]),
        reason: 'expected both staged libraries, got $uris',
      );
    });

    test(
      'yields cross-package public re-export libraries from PackageConfig',
      () async {
        // A third-party package whose conventional main library exists
        // (`package:<name>/<name>.dart`) is yielded even though it never
        // appears in _assetIdToPath.
        final fooPkg = _writeForeignPackage(root: tmp, name: 'foo');
        final pkgConfig = _writePackageConfig(root: tmp, packages: [fooPkg]);

        final input = File(p.join(tmp.path, 'src.dart'))
          ..writeAsStringSync(
            "import 'package:foo/foo.dart';\nclass Bar extends Foo {}\n",
          );
        final output = File(p.join(tmp.path, 'src.g.dart'));

        Set<String> uris = {};
        await runShimWithArgs(
          _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/src.dart',
            outputPath: output.path,
            packageConfigPath: pkgConfig,
          ),
          (_) => _CapturingBuilder((step) async {
            final libs = await step.resolver.libraries.toList();
            uris = libs.map(_libUriString).toSet();
          }),
        );

        expect(
          uris,
          contains('package:foo/foo.dart'),
          reason: 'expected package:foo/foo.dart to be yielded, got $uris',
        );
      },
    );

    test('skips a staged non-Dart dep, and keeps going', () async {
      // The staged loop has always claimed to skip non-library assets such
      // as plain-text deps, but nothing staged one, so deleting its catch
      // broke no test. Predates the cross-package change; covered here
      // because the same drain now reaches further and an escaping
      // exception would take the whole stream with it.
      //
      // The `.txt` sorts before `src.dart` in the staged map, so an escape
      // aborts the drain before any library is yielded.
      final data = File(p.join(tmp.path, 'data.txt'))
        ..writeAsStringSync('not dart at all\n');
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}\n');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      Set<String> uris = {};
      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/src.dart',
          outputPath: output.path,
          depPaths: [(exec: data.path, asset: 'lib/data.txt')],
        ),
        (_) => _CapturingBuilder((step) async {
          uris = (await step.resolver.libraries.toList())
              .map(_libUriString)
              .toSet();
        }),
      );

      expect(
        uris,
        contains('package:fixture/src.dart'),
        reason: 'the staged .txt aborted the drain, got $uris',
      );
      expect(uris, isNot(contains('package:fixture/data.txt')));
    });

    test('does not double-yield a library covered by both paths', () async {
      // If a library is reachable both via `_assetIdToPath` and via the
      // PackageConfig fallback, it should be yielded once. Guards against
      // the analyzer caller observing duplicate elements.
      //
      // The collision has to be constructed deliberately. `_buildPackageConfig`
      // puts a synthetic entry for the root package (`fixture`) into the
      // config, so the fallback loop asks for `package:fixture/fixture.dart`.
      // Staging a `--dep` at exactly that asset path is what makes one library
      // reachable both ways; without it the two loops cover disjoint URIs and
      // this test passes whether or not the dedup exists.
      final fooPkg = _writeForeignPackage(root: tmp, name: 'foo');
      final pkgConfig = _writePackageConfig(root: tmp, packages: [fooPkg]);

      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync("import 'package:foo/foo.dart';\nclass Bar {}\n");
      final collide = File(p.join(tmp.path, 'fixture.dart'))
        ..writeAsStringSync('class Collide {}\n');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      List<String> uriList = [];
      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/src.dart',
          outputPath: output.path,
          depPaths: [(exec: collide.path, asset: 'lib/fixture.dart')],
          packageConfigPath: pkgConfig,
        ),
        (_) => _CapturingBuilder((step) async {
          final libs = await step.resolver.libraries.toList();
          uriList = libs.map(_libUriString).toList();
        }),
      );

      // Assert the collision actually got set up: if this URI stops being
      // reachable both ways, the no-duplicates check below goes vacuous and
      // would keep passing with the dedup deleted.
      expect(
        uriList,
        contains('package:fixture/fixture.dart'),
        reason: 'fixture no longer collides across both paths, got $uriList',
      );

      // Set length == list length means no duplicates.
      expect(
        uriList.length,
        equals(uriList.toSet().length),
        reason: 'duplicate URIs in libraries: $uriList',
      );
    });

    test(
      'skips a package whose main library is a part, and keeps going',
      () async {
        // `libraryFor` throws `NonLibraryAssetException` when the file at the
        // conventional path parses as a `part of` rather than a library. The
        // loop must swallow that and continue, or one oddly-laid-out package
        // truncates the stream for every package after it.
        //
        // Ordering is the whole point: `partpkg` sorts before `zfoo`, so if the
        // catch is removed the exception escapes before `zfoo` is ever reached
        // and the assertion below fails. A fixture with only the bad package
        // would still pass with no catch at all, since nothing would follow it.
        final partPkg = Directory(p.join(tmp.path, 'partpkg_pkg'))
          ..createSync(recursive: true);
        Directory(p.join(partPkg.path, 'lib')).createSync(recursive: true);
        File(
          p.join(partPkg.path, 'lib', 'partpkg.dart'),
        ).writeAsStringSync("part of 'somewhere.dart';\n");
        final zfooPkg = _writeForeignPackage(root: tmp, name: 'zfoo');
        final pkgConfig = _writePackageConfig(
          root: tmp,
          packages: [partPkg, zfooPkg],
        );

        final input = File(p.join(tmp.path, 'src.dart'))
          ..writeAsStringSync('class Foo {}');
        final output = File(p.join(tmp.path, 'src.g.dart'));

        Set<String> uris = {};
        await runShimWithArgs(
          _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/src.dart',
            outputPath: output.path,
            packageConfigPath: pkgConfig,
          ),
          (_) => _CapturingBuilder((step) async {
            uris = (await step.resolver.libraries.toList())
                .map(_libUriString)
                .toSet();
          }),
        );

        expect(
          uris,
          contains('package:zfoo/zfoo.dart'),
          reason: 'iteration stopped at the part-only package, got $uris',
        );
        expect(uris, isNot(contains('package:partpkg/partpkg.dart')));
        expect(output.existsSync(), isTrue);
      },
    );

    test(
      'yields a synthetic empty library for a missing main library',
      () async {
        // A package declared in the config with no `lib/<name>.dart` on disk
        // does NOT throw, and so is not skipped: the analyzer answers
        // `getLibraryByUri` for a nonexistent file with an empty library, and
        // the loop yields it. Recorded because it is the opposite of what the
        // surrounding comments would lead you to expect, and because it is
        // what makes both `catch` arms unreachable for this shape.
        //
        // Harmless in practice — an empty library contributes no elements to a
        // generator walking the stream for types — so this pins the behavior
        // rather than asserting it is the behavior we would have chosen.
        final emptyPkgDir = Directory(p.join(tmp.path, 'empty_pkg'))
          ..createSync(recursive: true);
        Directory(p.join(emptyPkgDir.path, 'lib')).createSync(recursive: true);
        final pkgConfig = _writePackageConfig(
          root: tmp,
          packages: [emptyPkgDir],
        );

        final input = File(p.join(tmp.path, 'src.dart'))
          ..writeAsStringSync('class Foo {}');
        final output = File(p.join(tmp.path, 'src.g.dart'));

        Set<String> uris = {};
        await runShimWithArgs(
          _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/src.dart',
            outputPath: output.path,
            packageConfigPath: pkgConfig,
          ),
          (_) => _CapturingBuilder((step) async {
            uris = (await step.resolver.libraries.toList())
                .map(_libUriString)
                .toSet();
          }),
        );

        expect(uris, contains('package:empty/empty.dart'));
        expect(output.existsSync(), isTrue);
      },
    );
  });

  group('runShim diagnostic sink', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('shim_sink_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('argv parse failure routes to sink, not stderr', () async {
      final captured = <String>[];
      await runShim(
        const [],
        (_) => _NoopBuilder(),
        writeDiagnostic: captured.add,
      );
      expect(exitCode, 2);
      expect(captured, isNotEmpty);
      expect(captured.join('\n'), contains('--input'));
      exitCode = 0;
    });

    test('staging root bounds analysis-options discovery', () async {
      // The staging dir is created under a temp root, so its ancestors are
      // whatever the machine happens to have there. Without an options file of
      // its own the analyzer's walk-up reaches them, and codegen would be
      // configured by a stray file — differently on different machines. The
      // stub written at the staging root is what ends that walk.
      //
      // `exclude: '**'` is planted above deliberately: it is the ancestor
      // setting most likely to change generation if it were ever consulted.
      final stage = await Directory(p.join(tmp.path, 'stage')).create();
      File(
        p.join(tmp.path, 'analysis_options.yaml'),
      ).writeAsStringSync('analyzer:\n  exclude:\n    - "**"\n');

      final input = File(p.join(tmp.path, 'a.dart'))
        ..writeAsStringSync('class Foo {}');
      final out = p.join(tmp.path, 'a.g.dart');

      var stagedOptions = false;
      await runShim(
        [
          '--input',
          input.path,
          '--input-asset',
          'lib/a.dart',
          '--output',
          out,
          '--package',
          'p',
          '--root-language-version',
          '3.11',
        ],
        (_) => _FixedOutputBuilder('// generated'),
        stagingRoot: stage,
        buildAnalysisContext:
            ({
              required List<String> includedPaths,
              required String? sdkPath,
              String? sdkSummaryPath,
              required List<String> librarySummaryPaths,
            }) async {
              // Checked here rather than after the run: the staging dir is deleted
              // as soon as `runShim` returns.
              stagedOptions = File(
                p.join(includedPaths.single, 'analysis_options.yaml'),
              ).existsSync();
              return AnalysisContextCollection(
                includedPaths: includedPaths,
                sdkPath: sdkPath,
              );
            },
      );

      expect(
        stagedOptions,
        isTrue,
        reason:
            'no analysis_options.yaml at the staging root, so the '
            'analyzer walks up into the system temp dir',
      );
      expect(File(out).existsSync(), isTrue);
      expect(File(out).readAsStringSync(), contains('// generated'));
    });

    test('builder throw routes message + stack trace to sink', () async {
      final input = File(p.join(tmp.path, 'a.dart'))
        ..writeAsStringSync('class Foo {}');
      final out = p.join(tmp.path, 'a.g.dart');
      final stage = await Directory(p.join(tmp.path, 'stage')).create();
      final captured = <String>[];
      await runShim(
        [
          '--input',
          input.path,
          '--input-asset',
          'lib/a.dart',
          '--output',
          out,
          '--package',
          'p',
          '--root-language-version',
          '3.11',
        ],
        (_) => _ThrowingBuilder(),
        stagingRoot: stage,
        writeDiagnostic: captured.add,
      );
      expect(exitCode, 1);
      final combined = captured.join('\n');
      expect(combined, contains('Builder failed for'));
      expect(combined, contains('intentional failure'));
      exitCode = 0;
    });

    test('--config JSON is surfaced to the Builder via BuilderOptions', () async {
      // Guards ShimArgs.parse's JSON-object validation + the
      // builder-factory's BuilderOptions wiring. A regression anywhere
      // along `--config '{...}'` → `ShimArgs.config` → `BuilderOptions(config)`
      // would land a different structure at the Builder.
      final input = File(p.join(tmp.path, 'a.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'a.g.dart'));
      const configJson = '{"foo":"bar","nested":{"k":1}}';
      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/a.dart',
          outputPath: output.path,
          config: jsonDecode(configJson) as Map<String, dynamic>,
        ),
        (options) => _ConfigEchoBuilder(options),
      );
      final got = jsonDecode(output.readAsStringSync()) as Map<String, dynamic>;
      expect(got['foo'], 'bar');
      expect(got['nested'], {'k': 1});
    });

    test(
      'multi-dot buildExtensions suffix is correctly routed to output',
      () async {
        // Complements dart_sqlcodegen's dotfile-stem fail-loud (write side)
        // with the read-side equivalent: an output whose builder-declared
        // suffix contains multiple dots (`.foo.bar.baz`) must route
        // correctly through the shim's extension-match logic.
        final input = File(p.join(tmp.path, 'x.dart'))
          ..writeAsStringSync('class X {}');
        final output = File(p.join(tmp.path, 'x.foo.bar.baz'));
        await runShimWithArgs(
          _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/x.dart',
            outputPath: output.path,
          ),
          (_) => _MultiDotExtensionBuilder(),
        );
        expect(output.existsSync(), isTrue);
        expect(output.readAsStringSync(), '// multi-dot payload\n');
      },
    );

    test(
      'builder log.warning / log.severe reach the diagnostic sink',
      () async {
        // Regression guard for `gotcha_build_log_zone_value.md`. Without
        // the `#buildLog` Zone wiring, `package:build`'s top-level `log`
        // sinks into a silent fallback Logger and warnings from shimmed
        // Builders vanish.
        final input = File(p.join(tmp.path, 'a.dart'))
          ..writeAsStringSync('class Foo {}');
        final out = p.join(tmp.path, 'a.g.dart');
        final stage = await Directory(p.join(tmp.path, 'stage')).create();
        final captured = <String>[];
        await runShim(
          [
            '--input',
            input.path,
            '--input-asset',
            'lib/a.dart',
            '--output',
            out,
            '--package',
            'p',
            '--root-language-version',
            '3.11',
          ],
          (_) => _LoggingBuilder(),
          stagingRoot: stage,
          writeDiagnostic: captured.add,
        );
        final combined = captured.join('\n');
        expect(combined, contains('[WARNING]'));
        expect(combined, contains('builder-emitted warning'));
        expect(combined, contains('[SEVERE]'));
        expect(combined, contains('builder-emitted severe'));
        // exitCode may have been bumped by the SEVERE record; reset.
        exitCode = 0;
      },
    );
  });

  group('expandFlagFiles', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('flagfile_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('non-flagfile args pass through unchanged', () {
      expect(expandFlagFiles(const ['--foo', 'bar', '--baz']), [
        '--foo',
        'bar',
        '--baz',
      ]);
    });

    test('@<path> expands one-arg-per-line', () {
      final ff = File(p.join(tmp.path, 'args'))
        ..writeAsStringSync('--input\nsrc.dart\n--output\nsrc.g.dart\n');
      final expanded = expandFlagFiles(['@${ff.path}']);
      expect(expanded, ['--input', 'src.dart', '--output', 'src.g.dart']);
    });

    test('--flagfile= form matches @ form', () {
      final ff = File(p.join(tmp.path, 'args'))
        ..writeAsStringSync('--input\nsrc.dart\n');
      expect(expandFlagFiles(['--flagfile=${ff.path}']), [
        '--input',
        'src.dart',
      ]);
    });

    test('strips trailing \\r so CRLF flagfiles do not corrupt tokens', () {
      // Regression guard: a trailing \r would make ArgParser.parse reject
      // `--input\r` as an unknown flag.
      final ff = File(p.join(tmp.path, 'args'))
        ..writeAsStringSync('--input\r\nsrc.dart\r\n');
      final expanded = expandFlagFiles(['@${ff.path}']);
      expect(expanded, ['--input', 'src.dart']);
      for (final t in expanded) {
        expect(t, isNot(endsWith('\r')));
      }
    });

    test('empty lines are dropped', () {
      final ff = File(p.join(tmp.path, 'args'))
        ..writeAsStringSync('--input\n\nsrc.dart\n\n');
      expect(expandFlagFiles(['@${ff.path}']), ['--input', 'src.dart']);
    });

    test('mixes flagfile expansion with inline args, preserving order', () {
      final ff = File(p.join(tmp.path, 'args'))
        ..writeAsStringSync('--input\nsrc.dart\n');
      expect(expandFlagFiles(['--before', '@${ff.path}', '--after']), [
        '--before',
        '--input',
        'src.dart',
        '--after',
      ]);
    });
  });

  group('factoryOrFactories normalisation', () {
    // _normaliseFactories is exercised via the public runShimWithArgs
    // surface — passing a bad type must surface ArgumentError rather than
    // silently no-op'ing (silent no-op would mean Bazel sees an empty
    // output file and treats the action as successful).
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('norm_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('a non-factory, non-list object throws ArgumentError', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));
      await expectLater(
        runShimWithArgs(
          _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/src.dart',
            outputPath: output.path,
          ),
          'not a factory',
        ),
        throwsArgumentError,
      );
    });

    test(
      'a List<BuilderFactory> runs each factory against the same BuildStep',
      () async {
        // drift's shim_drift passes [discover, analyzer, driftBuilder]; each
        // factory produces a distinct output extension, and the combining
        // output routing downstream relies on every declared ext being
        // emitted by *some* factory in the list.
        final input = File(p.join(tmp.path, 'app.dart'))
          ..writeAsStringSync('class App {}');
        final firstOut = File(p.join(tmp.path, 'app.first.g.dart'));
        final secondOut = File(p.join(tmp.path, 'app.second.g.dart'));

        await runShimWithArgs(
          _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/app.dart',
            outputPath: firstOut.path,
            outputPaths: [firstOut.path, secondOut.path],
          ),
          [
            (_) => _FixedExtensionBuilder('.first.g.dart', '// first\n'),
            (_) => _FixedExtensionBuilder('.second.g.dart', '// second\n'),
          ],
        );

        expect(firstOut.readAsStringSync(), '// first\n');
        expect(secondOut.readAsStringSync(), '// second\n');
      },
    );
  });

  group('unemitted outputs', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('empty_output_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test(
      'declared outputs the Builder left unemitted are written empty',
      () async {
        final input = File(p.join(tmp.path, 'src.dart'))
          ..writeAsStringSync('class Foo {}');
        final output = File(p.join(tmp.path, 'src.g.dart'));

        await runShimWithArgs(
          _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/src.dart',
            outputPath: output.path,
          ),
          (_) => _NoopBuilder(),
        );

        expect(output.readAsStringSync(), isEmpty);
      },
    );
  });

  group('fetchResource across pipeline stages', () {
    // build_runner shares one ResourceManager per build session, so a
    // Resource fetched by stage 1 and stage 2 of the same pipeline is the
    // same instance (drift's shared analysis state relies on this). The
    // shim mirrors that: one manager per runShim invocation, disposed once
    // after the whole pipeline.
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('shim_resource_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('stages observe the same Resource instance and state', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      final resource = Resource<List<String>>(() => <String>[]);
      List<String>? stage1Instance;
      List<String>? stage2Instance;

      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/src.dart',
          outputPath: output.path,
        ),
        [
          (_) => _CapturingBuilder((step) async {
            stage1Instance = await step.fetchResource(resource);
            stage1Instance!.add('stage1');
          }),
          (_) => _CapturingBuilder((step) async {
            stage2Instance = await step.fetchResource(resource);
          }),
        ],
      );

      expect(
        identical(stage1Instance, stage2Instance),
        isTrue,
        reason: 'both stages must fetch the same Resource instance',
      );
      expect(stage2Instance, ['stage1']);
    });

    test('Resource dispose runs exactly once after the pipeline', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      var disposeCount = 0;
      final resource = Resource<Object>(
        () => Object(),
        dispose: (_) {
          disposeCount++;
        },
      );

      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/src.dart',
          outputPath: output.path,
        ),
        [
          (_) => _CapturingBuilder((step) async {
            await step.fetchResource(resource);
          }),
          (_) => _CapturingBuilder((step) async {
            await step.fetchResource(resource);
          }),
        ],
      );

      expect(
        disposeCount,
        1,
        reason: 'one shared manager disposes the Resource once',
      );
    });
  });

  group('intermediate-stage buildExtensions validation', () {
    // `_expectedOutputsFor` derives intermediate AssetIds by suffix
    // replacement. An empty-string key (PackageBuilder pattern) makes
    // `endsWith('')` always true and a `$lib$`/`$package$` placeholder key
    // never matches a real path suffix — both silently corrupt the derived
    // AssetId. The shim must reject them loudly for non-final stages.
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('build_ext_keys_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('empty-string key in a non-final stage throws StateError', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      await expectLater(
        runShimWithArgs(
          _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/src.dart',
            outputPath: output.path,
          ),
          [
            (_) => _ExtensionMapBuilder(const {
              '': ['.meta'],
            }),
            (_) => _NoopBuilder(),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unsupported for intermediate pipeline stages'),
          ),
        ),
      );
    });

    test(r'$-placeholder key in a non-final stage throws StateError', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      await expectLater(
        runShimWithArgs(
          _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/src.dart',
            outputPath: output.path,
          ),
          [
            (_) => _ExtensionMapBuilder(const {
              r'$lib$': ['lib/gen.dart'],
            }),
            (_) => _NoopBuilder(),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unsupported for intermediate pipeline stages'),
          ),
        ),
      );
    });

    test(
      'empty-string key is fine when the builder is the final/only stage',
      () async {
        // Final-stage allowedOutputs come from the rule-declared --output
        // paths, so the buildExtensions map is never consulted for AssetId
        // derivation and the PackageBuilder pattern works.
        final input = File(p.join(tmp.path, 'src.dart'))
          ..writeAsStringSync('class Foo {}');
        final output = File(p.join(tmp.path, 'src.g.dart'));

        await runShimWithArgs(
          _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/src.dart',
            outputPath: output.path,
          ),
          (_) => _ExtensionMapBuilder(
            const {
              '': ['.meta'],
            },
            write: (step) async {
              await step.writeAsString(
                step.inputId.changeExtension('.g.dart'),
                '// final stage\n',
              );
            },
          ),
        );

        expect(output.readAsStringSync(), '// final stage\n');
      },
    );
  });

  group('ShimWorkerLoop.performRequest', () {
    // Covers the production hot path (Bazel's persistent-worker protocol).
    // We call performRequest directly — the AsyncWorkerLoop stdin/stdout
    // framing is bazel_worker's responsibility, not ours.
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('worker_loop_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    WorkRequest requestFor(File input, File output, {String? sandboxDir}) =>
        WorkRequest(
          arguments: [
            '--input',
            input.path,
            '--input-asset',
            'lib/${p.basename(input.path)}',
            '--output',
            output.path,
            '--package',
            'fixture',
            '--root-language-version',
            '3.11',
          ],
          sandboxDir: sandboxDir,
        );

    test('happy path: exitCode 0, output captured is empty', () async {
      final loop = ShimWorkerLoop(factoryOrFactories: (_) => _NoopBuilder());
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      final resp = await loop.performRequest(requestFor(input, output));

      expect(resp.exitCode, 0);
      expect(resp.output, isEmpty);
      expect(output.existsSync(), isTrue);
    });

    test(
      'builder throw: exitCode non-zero, stack trace in WorkResponse.output',
      () async {
        final loop = ShimWorkerLoop(
          factoryOrFactories: (_) => _ThrowingBuilder(),
        );
        final input = File(p.join(tmp.path, 'src.dart'))
          ..writeAsStringSync('class Foo {}');
        final output = File(p.join(tmp.path, 'src.g.dart'));

        final resp = await loop.performRequest(requestFor(input, output));

        expect(resp.exitCode, isNonZero);
        // Builder throw surfaces through runShim's own sink, which here is
        // the loop's stderrBuffer → WorkResponse.output. Matches the
        // worker-protocol contract (clean stdout/stderr; diagnostics go in
        // the response).
        expect(resp.output, contains('intentional failure'));
      },
    );

    test('sandboxDir is honoured when Bazel populates it', () async {
      final sandbox = await Directory.systemTemp.createTemp('wr_sandbox_');
      addTearDown(() async {
        if (await sandbox.exists()) await sandbox.delete(recursive: true);
      });

      final loop = ShimWorkerLoop(factoryOrFactories: (_) => _NoopBuilder());
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      final resp = await loop.performRequest(
        requestFor(input, output, sandboxDir: sandbox.path),
      );

      expect(resp.exitCode, 0);
      // The shim chdirs into a staging dir under sandboxDir; when the
      // directory didn't exist we'd expect it to be created.
      expect(sandbox.existsSync(), isTrue);
    });

    test('exitCode is reset between requests — a prior failure does not '
        'taint the next success', () async {
      // Uses a swappable factory: first call throws, second is a no-op.
      var call = 0;
      Builder factory(BuilderOptions _) {
        call++;
        return call == 1 ? _ThrowingBuilder() : _NoopBuilder();
      }

      final loop = ShimWorkerLoop(factoryOrFactories: factory);
      final input1 = File(p.join(tmp.path, 'a.dart'))
        ..writeAsStringSync('class A {}');
      final output1 = File(p.join(tmp.path, 'a.g.dart'));
      final respFail = await loop.performRequest(requestFor(input1, output1));
      expect(respFail.exitCode, isNonZero);

      final input2 = File(p.join(tmp.path, 'b.dart'))
        ..writeAsStringSync('class B {}');
      final output2 = File(p.join(tmp.path, 'b.g.dart'));
      final respOk = await loop.performRequest(requestFor(input2, output2));
      expect(
        respOk.exitCode,
        0,
        reason: 'second request must not inherit first request\'s exit code',
      );
    });

    test(
      'cross-package requests in the same persistent worker are history-independent for both lib/ and test/ assets',
      () async {
        final recorded = <String, Map<String, Object?>>{};
        String? cachedRootPackageName;

        final loop = ShimWorkerLoop(
          factoryOrFactories: (_) => _CapturingBuilder((step) async {
            final lib = await step.resolver.libraryFor(step.inputId);
            final libUri = lib.firstFragment.source.uri;
            final cls = lib.classes.first;
            final assetId = await step.resolver.assetIdForElement(cls);
            final isLib = await step.resolver.isLibrary(step.inputId);

            // Simulate source_gen's top-level `final String rootPackageName`
            // (which reads CWD's `pubspec.yaml` only on the first request) and
            // `_fileToAssetUrl`'s `p.join(rootPackageName, p.relative(url.path))`.
            if (cachedRootPackageName == null) {
              final pubspecText = File('pubspec.yaml').readAsStringSync();
              final match = RegExp(
                r'^name:\s*"?([^"\n]*)"?',
                multiLine: true,
              ).firstMatch(pubspecText);
              cachedRootPackageName = match?.group(1) ?? '';
            }
            final sourceGenAssetPath = libUri.scheme == 'file'
                ? p.posix.joinAll(
                    p.split(
                      p.join(
                        cachedRootPackageName!,
                        p.relative(
                          libUri.toFilePath(windows: Platform.isWindows),
                        ),
                      ),
                    ),
                  )
                : '${assetId.package}/${assetId.path}';

            recorded[step.inputId.package] = {
              'uriScheme': libUri.scheme,
              'assetId': assetId.toString(),
              'isLibrary': isLib,
              'sourceGenAssetPath': sourceGenAssetPath,
            };
          }),
        );

        final testA = File(p.join(tmp.path, 'a_test.dart'))
          ..writeAsStringSync('class MockA {}\n');
        final outA = File(p.join(tmp.path, 'a_test.mocks.dart'));
        final respA = await loop.performRequest(
          WorkRequest(
            arguments: [
              '--input',
              testA.path,
              '--input-asset',
              'test/a_test.dart',
              '--output',
              outA.path,
              '--package',
              'pkg_a',
              '--root-language-version',
              '3.11',
            ],
          ),
        );
        expect(respA.exitCode, 0, reason: respA.output);

        final testB = File(p.join(tmp.path, 'b_test.dart'))
          ..writeAsStringSync('class MockB {}\n');
        final outB = File(p.join(tmp.path, 'b_test.mocks.dart'));
        final respB = await loop.performRequest(
          WorkRequest(
            arguments: [
              '--input',
              testB.path,
              '--input-asset',
              'test/b_test.dart',
              '--output',
              outB.path,
              '--package',
              'pkg_b',
              '--root-language-version',
              '3.11',
            ],
          ),
        );
        expect(respB.exitCode, 0, reason: respB.output);

        expect(recorded['pkg_a'], {
          'uriScheme': 'asset',
          'assetId': 'pkg_a|test/a_test.dart',
          'isLibrary': true,
          'sourceGenAssetPath': 'pkg_a/test/a_test.dart',
        });
        expect(
          recorded['pkg_b'],
          {
            'uriScheme': 'asset',
            'assetId': 'pkg_b|test/b_test.dart',
            'isLibrary': true,
            'sourceGenAssetPath': 'pkg_b/test/b_test.dart',
          },
          reason:
              'second package in persistent worker must resolve to pkg_b '
              'asset URI without inheriting pkg_a',
        );
      },
    );

    test(
      'passes sdkSummaryPath separately from librarySummaryPaths and disposes AnalysisContextCollection',
      () async {
        final input = File(p.join(tmp.path, 'a.dart'))
          ..writeAsStringSync('class Foo {}');
        final out = p.join(tmp.path, 'a.g.dart');
        final sdkSum = File(p.join(tmp.path, 'sdk.sum'))..writeAsBytesSync([]);
        final pkgSum = File(p.join(tmp.path, 'pkg.sum'))..writeAsBytesSync([]);

        String? observedSdkSummary;
        List<String>? observedSummaries;
        var disposeCalled = false;

        await runShim(
          [
            '--input',
            input.path,
            '--input-asset',
            'lib/a.dart',
            '--output',
            out,
            '--package',
            'p',
            '--root-language-version',
            '3.11',
            '--summary',
            pkgSum.path,
            '--sdk-summary',
            sdkSum.path,
          ],
          (_) => _FixedOutputBuilder('// generated'),
          buildAnalysisContext:
              ({
                required List<String> includedPaths,
                required String? sdkPath,
                String? sdkSummaryPath,
                required List<String> librarySummaryPaths,
              }) async {
                observedSdkSummary = sdkSummaryPath;
                observedSummaries = librarySummaryPaths;
                final inner = AnalysisContextCollection(
                  includedPaths: includedPaths,
                  sdkPath: sdkPath,
                );
                return _DisposeTrackingCollection(
                  inner,
                  onDispose: () => disposeCalled = true,
                );
              },
        );

        expect(
          observedSdkSummary,
          p.normalize(sdkSum.absolute.path),
          reason:
              'sdkSummaryPath must be forwarded so AnalysisContextCollectionImpl creates a SummaryBasedDartSdk',
        );
        expect(observedSummaries, [p.normalize(pkgSum.absolute.path)]);
        expect(
          disposeCalled,
          isTrue,
          reason:
              'AnalysisContextCollection.dispose() must run even when librarySummaryPaths is non-empty',
        );
      },
    );

    test(
      'drives several codegen requests with real sdk and library summaries through the same ShimWorkerLoop instance and disposes contexts cleanly',
      () async {
        final sdkDir = File(Platform.resolvedExecutable).parent.parent;
        final sdkSummaryFile = File(p.join(tmp.path, 'sdk.sum'));
        final sdkSummaryBytes = await buildSdkSummary(
          resourceProvider: PhysicalResourceProvider.INSTANCE,
          sdkPath: sdkDir.path,
        );
        sdkSummaryFile.writeAsBytesSync(sdkSummaryBytes);

        // Build three distinct dependency package summaries (dep_0, dep_1, dep_2).
        final depSummaryFiles = <File>[];
        final depPackages = <Directory>[];
        for (var i = 0; i < 3; i++) {
          final depName = 'dep_$i';
          final depPkg = _writeForeignPackage(
            root: tmp,
            name: depName,
            libBody: 'class Base$i {\n  int get tag$i => $i;\n}\n',
          );
          depPackages.add(depPkg);
          final depConfig = _writePackageConfig(
            root: depPkg,
            packages: [depPkg],
          );
          final depSrc = p.normalize(
            p.absolute(p.join(depPkg.path, 'lib', '$depName.dart')),
          );
          final depCollection = AnalysisContextCollectionImpl(
            resourceProvider: PhysicalResourceProvider.INSTANCE,
            includedPaths: [depSrc],
            sdkPath: sdkDir.path,
            sdkSummaryPath: sdkSummaryFile.path,
            packageConfigFile: depConfig,
            librarySummaryPaths: const [],
          );
          try {
            final driver = depCollection.contexts.single.driver;
            final bundleBytes = await driver.buildPackageBundle(
              uriList: [Uri.parse('package:$depName/$depName.dart')],
            );
            final sumFile = File(p.join(tmp.path, '$depName.sum'))
              ..writeAsBytesSync(bundleBytes);
            depSummaryFiles.add(sumFile);
          } finally {
            await depCollection.dispose();
          }
          // Delete the source file after summarizing so codegen MUST resolve
          // `package:dep_i/dep_i.dart` from its `.sum` bundle rather than disk.
          File(depSrc).deleteSync();
        }

        final sharedPkgConfig = _writePackageConfig(
          root: tmp,
          packages: depPackages,
        );

        final loop = ShimWorkerLoop(
          factoryOrFactories: (_) => _CapturingBuilder((step) async {
            final lib = await step.resolver.libraryFor(step.inputId);
            final cls = lib.classes.single;
            final superName = cls.supertype?.element.name ?? 'none';
            await step.writeAsString(
              step.inputId.changeExtension('.g.dart'),
              '// class=${cls.name} extends=$superName\n',
            );
          }),
        );

        for (var reqIdx = 0; reqIdx < 4; reqIdx++) {
          final depIdx = reqIdx % 3;
          final input = File(p.join(tmp.path, 'model_$reqIdx.dart'))
            ..writeAsStringSync(
              "import 'package:dep_$depIdx/dep_$depIdx.dart';\n"
              'class Model$reqIdx extends Base$depIdx {}\n',
            );
          final output = File(p.join(tmp.path, 'model_$reqIdx.g.dart'));
          final resp = await loop.performRequest(
            WorkRequest(
              arguments: [
                '--input',
                input.path,
                '--input-asset',
                'lib/model_$reqIdx.dart',
                '--output',
                output.path,
                '--package',
                'codegen_pkg_$reqIdx',
                '--package-config',
                sharedPkgConfig,
                '--root-language-version',
                '3.11',
                '--sdk-path',
                sdkDir.path,
                '--sdk-summary',
                sdkSummaryFile.path,
                for (final sum in depSummaryFiles) ...['--summary', sum.path],
              ],
            ),
          );
          // Pump the event queue so AnalysisDriverScheduler._run executes
          // _maybeDispose() before the next request starts.
          await pumpEventQueue();
          expect(resp.exitCode, 0, reason: resp.output);
          expect(
            output.readAsStringSync(),
            '// class=Model$reqIdx extends=Base$depIdx\n',
          );
        }
      },
    );
  });

  group('read-only inputs and staged root config files', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('shim_readonly_');
    });

    tearDown(() async {
      if (!Platform.isWindows && await tmp.exists()) {
        await Process.run('chmod', ['-R', 'u+w', tmp.path]);
      }
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    void makeReadOnly(File file) {
      if (Platform.isWindows) {
        final res = Process.runSync('attrib', ['+R', file.path]);
        expect(res.exitCode, 0, reason: '${res.stderr}');
      } else {
        final res = Process.runSync('chmod', ['0444', file.path]);
        expect(res.exitCode, 0, reason: '${res.stderr}');
      }
    }

    test(
      'read-only pubspec.yaml and analysis_options.yaml in --dep do not fail '
      'and preserve caller contents (matching writable inputs)',
      () async {
        const pubspecContent =
            'name: fixture\nversion: 2.3.4\ncustom_meta: hello\n'
            'environment:\n  sdk: ^3.0.0\n';
        const optionsContent =
            '# custom options\nlinter:\n  rules:\n    - camel_case_types\n';

        Future<Map<String, String>> runVariant({required bool readOnly}) async {
          final sub = await Directory(
            p.join(tmp.path, readOnly ? 'ro' : 'rw'),
          ).create();
          final input = File(p.join(sub.path, 'src.dart'))
            ..writeAsStringSync('class Foo {}\n');
          final pubspec = File(p.join(sub.path, 'pubspec.yaml'))
            ..writeAsStringSync(pubspecContent);
          final options = File(p.join(sub.path, 'analysis_options.yaml'))
            ..writeAsStringSync(optionsContent);
          if (readOnly) {
            makeReadOnly(input);
            makeReadOnly(pubspec);
            makeReadOnly(options);
          }
          final output = File(p.join(sub.path, 'src.g.dart'));

          String? observedPubspec;
          String? observedOptions;
          List<String>? foundYamlPaths;

          await runShimWithArgs(
            _shimArgs(
              inputPath: input.path,
              inputAssetPath: 'lib/src.dart',
              outputPath: output.path,
              depPaths: [
                (exec: pubspec.path, asset: 'pubspec.yaml'),
                (exec: options.path, asset: 'analysis_options.yaml'),
              ],
            ),
            (_) => _CapturingBuilder((step) async {
              observedPubspec = await step.readAsString(
                AssetId('fixture', 'pubspec.yaml'),
              );
              observedOptions = await step.readAsString(
                AssetId('fixture', 'analysis_options.yaml'),
              );
              foundYamlPaths =
                  (await step.findAssets(Glob('*.yaml')).toList())
                      .map((id) => id.path)
                      .toList()
                    ..sort();
              await step.writeAsString(
                step.inputId.changeExtension('.g.dart'),
                '// pubspec=${observedPubspec!.trim()}\n'
                '// options=${observedOptions!.trim()}\n',
              );
            }),
          );

          return {
            'pubspec': observedPubspec!,
            'options': observedOptions!,
            'found': foundYamlPaths!.join(','),
            'output': output.readAsStringSync(),
          };
        }

        final roResult = await runVariant(readOnly: true);
        final rwResult = await runVariant(readOnly: false);

        expect(roResult['pubspec'], pubspecContent);
        expect(roResult['options'], optionsContent);
        expect(roResult['found'], 'analysis_options.yaml,pubspec.yaml');
        expect(
          roResult,
          equals(rwResult),
          reason:
              'read-only (remote/sandbox) and writable (local) inputs must '
              'produce identical Builder observations and outputs',
        );
      },
    );

    test('read-only primary --input and --input-asset-extra at root yaml paths '
        'succeed in worker mode and do not leak across requests', () async {
      const customPubspec =
          'name: pkg_agg\nversion: 9.9.9\nenvironment:\n  sdk: ^3.0.0\n';
      const customOptions = '# aggregate options\n';

      final input = File(p.join(tmp.path, 'pubspec.yaml'))
        ..writeAsStringSync(customPubspec);
      final extraOptions = File(p.join(tmp.path, 'analysis_options.yaml'))
        ..writeAsStringSync(customOptions);
      final extraDart = File(p.join(tmp.path, 'a.dart'))
        ..writeAsStringSync('class A {}\n');
      makeReadOnly(input);
      makeReadOnly(extraOptions);
      makeReadOnly(extraDart);

      final out1 = File(p.join(tmp.path, 'out1.g.dart'));
      final observed = <String, Map<String, String>>{};

      final loop = ShimWorkerLoop(
        factoryOrFactories: (_) => _CapturingBuilder((step) async {
          final pkg = step.inputId.package;
          final pubspec = await step.readAsString(AssetId(pkg, 'pubspec.yaml'));
          final options = await step.readAsString(
            AssetId(pkg, 'analysis_options.yaml'),
          );
          observed[pkg] = {'pubspec': pubspec, 'options': options};
          await step.writeAsString(step.allowedOutputs.first, '// ok:$pkg\n');
        }),
      );

      final resp1 = await loop.performRequest(
        WorkRequest(
          arguments: [
            '--input',
            input.path,
            '--input-asset',
            'pubspec.yaml',
            '--input-asset-extra',
            '${extraOptions.path}|analysis_options.yaml',
            '--input-asset-extra',
            '${extraDart.path}|lib/a.dart',
            '--output',
            out1.path,
            '--package',
            'pkg_agg',
            '--root-language-version',
            '3.11',
          ],
        ),
      );
      expect(resp1.exitCode, 0, reason: resp1.output);
      expect(observed['pkg_agg']!['pubspec'], customPubspec);
      expect(observed['pkg_agg']!['options'], customOptions);
      expect(out1.readAsStringSync(), '// ok:pkg_agg\n');

      // Follow-up request in the same worker without staged root yamls
      // must still get the synthesized fallback stubs.
      final input2 = File(p.join(tmp.path, 'b.dart'))
        ..writeAsStringSync('class B {}\n');
      makeReadOnly(input2);
      final out2 = File(p.join(tmp.path, 'b.g.dart'));

      final resp2 = await loop.performRequest(
        WorkRequest(
          arguments: [
            '--input',
            input2.path,
            '--input-asset',
            'lib/b.dart',
            '--output',
            out2.path,
            '--package',
            'pkg_plain',
            '--root-language-version',
            '3.11',
          ],
        ),
      );
      expect(resp2.exitCode, 0, reason: resp2.output);
      expect(observed['pkg_plain']!['pubspec'], contains('name: pkg_plain'));
      expect(
        observed['pkg_plain']!['options'],
        contains('bounds analysis_options.yaml discovery'),
      );
    });

    test(
      'symlinked systemTemp, sandboxDir, and stagingRoot resolve to canonical paths so p.relative(libUri.path) has no ../ segments',
      () async {
        final realTmp = await Directory(
          p.join(tmp.path, 'real_private_var_folders'),
        ).create(recursive: true);
        final symlinkTmp = Link(p.join(tmp.path, 'symlink_var_folders'))
          ..createSync(realTmp.path);
        final savedCwd = Directory.current;
        addTearDown(() {
          Directory.current = savedCwd;
        });

        await IOOverrides.runZoned(() async {
          // 1. prepareSourceGenCwd under symlinked Directory.systemTemp
          final prepBase = await Directory.systemTemp.createTemp('prep_');
          final prepared = await prepareSourceGenCwd(
            baseDir: prepBase,
            packageName: 'pkg_prep',
          );
          expect(
            p.relative(prepared.path),
            'pkg_prep',
            reason:
                'prepareSourceGenCwd must align returned Directory.path with canonical Directory.current.path',
          );
          expect(
            p.normalize(prepared.path),
            p.join(p.normalize(Directory.current.path), 'pkg_prep'),
          );
          Directory.current = savedCwd;

          // 2. ShimWorkerLoop with symlinked Directory.systemTemp and symlinked sandboxDir
          final recorded = <String, Map<String, Object?>>{};
          String? cachedRootPackageName;
          final loop = ShimWorkerLoop(
            factoryOrFactories: (_) => _CapturingBuilder((step) async {
              final lib = await step.resolver.libraryFor(step.inputId);
              final libUri = lib.firstFragment.source.uri;
              final cls = lib.classes.first;
              final assetId = await step.resolver.assetIdForElement(cls);
              if (cachedRootPackageName == null) {
                final pubspecText = File('pubspec.yaml').readAsStringSync();
                final match = RegExp(
                  r'^name:\s*"?([^"\n]*)"?',
                  multiLine: true,
                ).firstMatch(pubspecText);
                cachedRootPackageName = match?.group(1) ?? '';
              }
              final relPath = p.relative(
                libUri.scheme == 'file'
                    ? libUri.toFilePath(windows: Platform.isWindows)
                    : lib.firstFragment.source.fullName,
              );
              final sourceGenAssetPath = libUri.scheme == 'file'
                  ? p.posix.joinAll(
                      p.split(p.join(cachedRootPackageName!, relPath)),
                    )
                  : '${assetId.package}/${assetId.path}';
              recorded[step.inputId.package] = {
                'relPath': relPath,
                'sourceGenAssetPath': sourceGenAssetPath,
                'assetId': assetId.toString(),
              };
            }),
          );

          final testA = File(p.join(tmp.path, 'sym_a_test.dart'))
            ..writeAsStringSync('class SymMockA {}\n');
          final outA = File(p.join(tmp.path, 'sym_a_test.mocks.dart'));
          final respA = await loop.performRequest(
            WorkRequest(
              arguments: [
                '--input',
                testA.path,
                '--input-asset',
                'test/a_test.dart',
                '--output',
                outA.path,
                '--package',
                'pkg_a',
                '--root-language-version',
                '3.11',
              ],
            ),
          );
          expect(respA.exitCode, 0, reason: respA.output);

          final symlinkSandbox = Link(p.join(tmp.path, 'symlink_sandbox'))
            ..createSync(realTmp.path);
          final testB = File(p.join(tmp.path, 'sym_b_test.dart'))
            ..writeAsStringSync('class SymMockB {}\n');
          final outB = File(p.join(tmp.path, 'sym_b_test.mocks.dart'));
          final respB = await loop.performRequest(
            WorkRequest(
              sandboxDir: symlinkSandbox.path,
              arguments: [
                '--input',
                testB.path,
                '--input-asset',
                'test/b_test.dart',
                '--output',
                outB.path,
                '--package',
                'pkg_b',
                '--root-language-version',
                '3.11',
              ],
            ),
          );
          expect(respB.exitCode, 0, reason: respB.output);

          expect(recorded['pkg_a'], {
            'relPath': p.join('pkg_a', 'test', 'a_test.dart'),
            'sourceGenAssetPath': 'pkg_a/test/a_test.dart',
            'assetId': 'pkg_a|test/a_test.dart',
          });
          expect(recorded['pkg_b'], {
            'relPath': p.join('pkg_b', 'test', 'b_test.dart'),
            'sourceGenAssetPath': 'pkg_b/test/b_test.dart',
            'assetId': 'pkg_b|test/b_test.dart',
          });

          // 3. One-shot runShimWithArgs with a symlinked stagingRoot
          final realOneShotDir = await Directory(
            p.join(realTmp.path, 'oneshot_real'),
          ).create(recursive: true);
          final symlinkOneShotDir = Link(p.join(tmp.path, 'oneshot_symlink'))
            ..createSync(realOneShotDir.path);
          String? oneShotRelPath;
          final outC = File(p.join(tmp.path, 'sym_c_test.g.dart'));
          await runShimWithArgs(
            _shimArgs(
              inputPath: testA.path,
              inputAssetPath: 'test/a_test.dart',
              outputPath: outC.path,
              packageName: 'pkg_c',
            ),
            (_) => _CapturingBuilder((step) async {
              final lib = await step.resolver.libraryFor(step.inputId);
              final libUri = lib.firstFragment.source.uri;
              oneShotRelPath = p.relative(
                libUri.scheme == 'file'
                    ? libUri.toFilePath(windows: Platform.isWindows)
                    : lib.firstFragment.source.fullName,
              );
              await step.writeAsString(
                outC.path.endsWith('.g.dart')
                    ? step.inputId.changeExtension('.g.dart')
                    : step.allowedOutputs.first,
                '// ok\n',
              );
            }),
            stagingRoot: Directory(symlinkOneShotDir.path),
          );
          expect(oneShotRelPath, p.join('pkg_c', 'test', 'a_test.dart'));
        }, getSystemTempDirectory: () => Directory(symlinkTmp.path));
      },
    );

    test(
      'non-lib assets (bin/, web/, test/, tool/) and their relative imports resolve to asset:/package: URIs without leaking staging paths',
      () async {
        final binApp = File(p.join(tmp.path, 'app.dart'))
          ..writeAsStringSync(
            "import 'sub/helper.dart';\n"
            "import '../lib/shared.dart';\n"
            'class App { Helper? h; Shared? s; }\n',
          );
        final binHelper = File(p.join(tmp.path, 'helper.dart'))
          ..writeAsStringSync('class Helper {}\n');
        final libShared = File(p.join(tmp.path, 'shared.dart'))
          ..writeAsStringSync('class Shared {}\n');
        final webMain = File(p.join(tmp.path, 'main.dart'))
          ..writeAsStringSync('class WebEntry {}\n');
        final out = File(p.join(tmp.path, 'app.locator.dart'));

        Uri? inputLibUri;
        Uri? inputSourceUri;
        final libraryUris = <String>[];
        final elementAssets = <String, String>{};
        final stackedResolvedImports = <String, String>{};

        await runShimWithArgs(
          _shimArgs(
            inputPath: binApp.path,
            inputAssetPath: 'bin/app.dart',
            outputPath: out.path,
            packageName: 'app_pkg',
            depPaths: [
              (exec: binHelper.path, asset: 'bin/sub/helper.dart'),
              (exec: libShared.path, asset: 'lib/shared.dart'),
              (exec: webMain.path, asset: 'web/main.dart'),
            ],
          ),
          (_) => _CapturingBuilder((step) async {
            final lib = await step.resolver.libraryFor(step.inputId);
            inputLibUri = lib.uri;
            inputSourceUri = lib.firstFragment.source.uri;
            final libs = await step.resolver.libraries.toList();
            for (final l in libs) {
              libraryUris.add(l.uri.toString());
              for (final cls in l.classes) {
                final id = await step.resolver.assetIdForElement(cls);
                elementAssets[cls.name!] = id.toString();
              }
            }

            // Replicate stacked_generator's ImportResolver over `libs` and
            // `targetFilePath = inputSourceUri.path` to verify that generated
            // imports for classes in `bin/`, `bin/sub/`, and `lib/` never
            // fall back to `file:///<TMPDIR>/shim_...`.
            final targetFilePath = inputSourceUri!.path;
            String? resolveStackedImport(Element element) {
              final elementUri =
                  element.firstFragment.libraryFragment?.source.uri;
              if (elementUri == null) return null;
              for (final l in libs) {
                if (l.exportNamespace.definedNames2.values.contains(element)) {
                  final pkgUri = l.firstFragment.source.uri;
                  final pkg = pkgUri.pathSegments.first;
                  if (targetFilePath.startsWith(RegExp('^$pkg/'))) {
                    return p.posix
                        .relative(elementUri.path, from: targetFilePath)
                        .replaceFirst('../', '');
                  }
                  return elementUri.toString();
                }
              }
              return null;
            }

            final appCls = lib.classes.single;
            stackedResolvedImports['App'] = resolveStackedImport(appCls)!;
            for (final field in appCls.fields) {
              final fieldCls = field.type.element!;
              stackedResolvedImports[fieldCls.name!] = resolveStackedImport(
                fieldCls,
              )!;
            }

            final buf = StringBuffer();
            for (final imp in stackedResolvedImports.values) {
              buf.writeln("import '$imp';");
            }
            await step.writeAsString(
              step.allowedOutputs.single,
              buf.toString(),
            );
          }),
        );

        expect(inputLibUri, Uri.parse('asset:app_pkg/bin/app.dart'));
        expect(inputSourceUri, Uri.parse('asset:app_pkg/bin/app.dart'));
        expect(
          libraryUris,
          containsAll([
            'asset:app_pkg/bin/app.dart',
            'asset:app_pkg/bin/sub/helper.dart',
            'package:app_pkg/shared.dart',
            'asset:app_pkg/web/main.dart',
          ]),
        );
        expect(
          libraryUris.where(
            (u) => u.startsWith('file:') || u.contains('shim_'),
          ),
          isEmpty,
          reason: 'no library URI may expose file:// or staging directory',
        );
        expect(elementAssets, {
          'App': 'app_pkg|bin/app.dart',
          'Helper': 'app_pkg|bin/sub/helper.dart',
          'Shared': 'app_pkg|lib/shared.dart',
          'WebEntry': 'app_pkg|web/main.dart',
        });
        expect(stackedResolvedImports['App'], '.');
        expect(stackedResolvedImports['Helper'], 'sub/helper.dart');
        final generated = out.readAsStringSync();
        expect(generated, isNot(contains('file:')));
        expect(generated, isNot(contains('shim_')));
        expect(generated, isNot(contains(tmp.path)));
      },
    );

    test(
      'Windows file:// URI converts via toFilePath(windows: true) to relative asset path without drive-letter traversal',
      () {
        final winContext = p.Context(
          style: p.Style.windows,
          current:
              r'C:\Users\runneradmin\AppData\Local\Temp\builder_shim_work_1\pkg_a',
        );
        final winLibUri = Uri.file(
          r'C:\Users\runneradmin\AppData\Local\Temp\builder_shim_work_1\pkg_a\test\a_test.dart',
          windows: true,
        );
        final relFromFilePath = winContext.relative(
          winLibUri.toFilePath(windows: true),
        );
        final assetPath = p.posix.joinAll(
          winContext.split(winContext.join('pkg_a', relFromFilePath)),
        );
        expect(relFromFilePath, r'test\a_test.dart');
        expect(assetPath, 'pkg_a/test/a_test.dart');
      },
    );
  });

  group('findStagedShimViolations', () {
    late Directory staging;

    setUp(() {
      staging = Directory.systemTemp.createTempSync('shim_guard_');
    });

    tearDown(() {
      staging.deleteSync(recursive: true);
    });

    Future<void> stage(String relative, String content) async {
      final file = File(p.joinAll([staging.path, ...relative.split('/')]));
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    }

    test('allows directives inside the declared staging dir', () async {
      await stage('lib/a.dart', '''
import 'b.dart';
import 'dart:core';
import 'package:p/c.dart';
''');
      await stage('lib/b.dart', 'library b;\n');
      await stage('lib/sub/d.dart', '''
import '../b.dart';
part 'e.dart';
''');
      await stage('lib/sub/e.dart', "part of 'd.dart';\n");
      expect(
        await findStagedShimViolations(staging, tool: 'builder_shim'),
        isEmpty,
      );
    });

    test('refuses escapes in every directive kind and branch', () async {
      await stage('lib/a.dart', "import '../../evil.dart';\n");
      await stage(
        'lib/b.dart',
        "export 'dart:core' if (dart.library.io) '../../evil.dart';\n",
      );
      await stage('lib/c.dart', "part '../../evil_part.dart';\n");
      await stage('lib/d.dart', "part of '../../evil_lib.dart';\n");
      await stage('lib/e.dart', "import 'package:p/sub/../../evil.dart';\n");
      await stage('lib/f.dart', "import 'file:///etc/hosts';\n");
      await stage('lib/g.dart', "import '/etc/hostname';\n");
      final violations = await findStagedShimViolations(
        staging,
        tool: 'builder_shim',
      );
      expect(violations, hasLength(7));
      for (final violation in violations) {
        expect(violation, startsWith('builder_shim: '));
        expect(violation, endsWith('is not a declared input.'));
      }
      expect(
        violations,
        contains(contains("import '../../evil.dart' is not a declared input.")),
      );
    });
  });
}

class _DisposeTrackingCollection implements AnalysisContextCollection {
  _DisposeTrackingCollection(this._inner, {required this.onDispose});

  final AnalysisContextCollection _inner;
  final void Function() onDispose;

  @override
  List<AnalysisContext> get contexts => _inner.contexts;

  @override
  AnalysisContext contextFor(String path) => _inner.contextFor(path);

  @override
  Future<void> dispose() async {
    onDispose();
    await _inner.dispose();
  }
}

/// A Builder declared to produce `.g.dart` outputs but that emits nothing.
class _NoopBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep step) async {}
}

class _FixedOutputBuilder implements Builder {
  _FixedOutputBuilder(this._contents);
  final String _contents;

  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep step) async {
    final outId = step.inputId.changeExtension('.g.dart');
    await step.writeAsString(outId, _contents);
  }
}

/// Like `_FixedOutputBuilder` but parameterised by output extension so a
/// multi-factory `runShim` list can fan out to distinct declared outputs.
class _FixedExtensionBuilder implements Builder {
  _FixedExtensionBuilder(this._ext, this._contents);
  final String _ext;
  final String _contents;

  @override
  Map<String, List<String>> get buildExtensions => {
    '.dart': [_ext],
  };

  @override
  Future<void> build(BuildStep step) async {
    final outId = step.inputId.changeExtension(_ext);
    await step.writeAsString(outId, _contents);
  }
}

class _ThrowingBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep step) async {
    throw StateError('intentional failure');
  }
}

/// Emits log records via `package:build`'s top-level `log`, which only
/// resolves to a captured Logger when the Builder runs inside the
/// `#buildLog` Zone value wired by the shim. Used to guard against the
/// silent-fallback regression documented in
/// `gotcha_build_log_zone_value.md`.
class _LoggingBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep step) async {
    log.warning('builder-emitted warning');
    log.severe('builder-emitted severe');
  }
}

/// Serialises its own `BuilderOptions.config` as JSON into the declared
/// `.g.dart` output. Used to assert the shim correctly plumbs `--config`
/// → `ShimArgs.config` → `BuilderOptions(config)`.
class _ConfigEchoBuilder implements Builder {
  _ConfigEchoBuilder(this._options);
  final BuilderOptions _options;

  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep step) async {
    final outId = step.inputId.changeExtension('.g.dart');
    await step.writeAsString(outId, jsonEncode(_options.config));
  }
}

/// Declares a multi-dot output suffix. Used to verify the shim's output-
/// routing logic matches `.foo.bar.baz` against the declared Bazel output
/// without fracturing on intermediate dots.
class _MultiDotExtensionBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.foo.bar.baz'],
  };

  @override
  Future<void> build(BuildStep step) async {
    final outId = step.inputId.changeExtension('.foo.bar.baz');
    await step.writeAsString(outId, '// multi-dot payload\n');
  }
}

/// Builder with a caller-supplied `buildExtensions` map and an optional
/// write callback. Used to exercise the shim's validation of unsupported
/// buildExtensions key shapes (empty string, `$lib$`/`$package$`).
class _ExtensionMapBuilder implements Builder {
  _ExtensionMapBuilder(this.buildExtensions, {this.write});

  @override
  final Map<String, List<String>> buildExtensions;
  final Future<void> Function(BuildStep)? write;

  @override
  Future<void> build(BuildStep step) async {
    await write?.call(step);
  }
}

class _CapturingBuilder implements Builder {
  _CapturingBuilder(this._fn);
  final Future<void> Function(BuildStep) _fn;

  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep step) => _fn(step);
}

/// Builder that emits one asset per entry in [_bodies]; keys are the
/// output extensions (e.g. `.config.dart`), values are the bytes written.
/// Used to exercise the shim's multi-output routing.
class _MultiOutputBuilder implements Builder {
  _MultiOutputBuilder(this._bodies);
  final Map<String, String> _bodies;

  @override
  Map<String, List<String>> get buildExtensions => {
    '.dart': _bodies.keys.toList(growable: false),
  };

  @override
  Future<void> build(BuildStep step) async {
    for (final entry in _bodies.entries) {
      final outId = step.inputId.changeExtension(entry.key);
      await step.writeAsString(outId, entry.value);
    }
  }
}
