// Tagged `runfiles`: the guard under test imports `package:rules_dart_guard`,
// which Bazel supplies via the `@rules_dart//dart/guard:directive_guard` dep
// its `dart_test` declares. A bare `dart test` resolves only this package's
// pubspec, where that import does not exist, so the file fails to load rather
// than failing a test.
// Coverage comes from //flutter/private/tools:kernel_filter_test.
@Tags(['runfiles'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../directive_guard.dart';
import '../kernel_filter.dart';

typedef _Errors = List<String>;

typedef _Run = ({int code, String err, String out});

const _id = '53d4fd45-0cd8-4542-bca7-7ba7c9385b70';

void main() {
  group('isBoundaryLine', () {
    test('matches the three lines frontend_server frames a compile with', () {
      expect(isBoundaryLine('result $_id'), isTrue);
      expect(isBoundaryLine(_id), isTrue);
      expect(
        isBoundaryLine('$_id bazel-out/x y/bin/app_flutter.dill 0'),
        isTrue,
      );
    });

    test('keeps everything else', () {
      expect(isBoundaryLine(''), isFalse);
      expect(
        isBoundaryLine('lib/main.dart:3:5: Error: Expected `;`.'),
        isFalse,
      );
      expect(isBoundaryLine('result'), isFalse);
      expect(isBoundaryLine('result $_id extra'), isFalse);
      expect(isBoundaryLine('see $_id'), isFalse);
      expect(isBoundaryLine('$_id out.dill'), isFalse);
    });
  });

  group('splitDependencyLines', () {
    test('separates reads from the rest', () {
      final ({List<String> reads, String rest}) split = splitDependencyLines(
        'result $_id\n'
        '$_id\n'
        '+file:///work/lib/main.dart\n'
        'lib/main.dart:3:5: Error: boom.\n'
        '+file:///work/lib/foo.dart\n'
        '$_id app_flutter.dill 1\n',
      );
      expect(split.reads, [
        '+file:///work/lib/main.dart',
        '+file:///work/lib/foo.dart',
      ]);
      expect(split.rest, contains('Error: boom.'));
      expect(split.rest, isNot(contains(_id)));
      expect(split.rest, isNot(contains('+file://')));
    });
  });

  group('dependencyExecPath', () {
    late Directory savedCwd;

    setUp(() => savedCwd = Directory.current);
    tearDown(() => Directory.current = savedCwd.path);

    test('maps a read under the working directory to its exec path', () {
      final Directory work = Directory.systemTemp.createTempSync(
        'kernel_filter_cwd_',
      );
      addTearDown(() => work.deleteSync(recursive: true));
      Directory.current = work.path;
      File('${work.path}/lib/main.dart').createSync(recursive: true);
      final String? p = dependencyExecPath(
        '+file://${work.path}/lib/main.dart',
      );
      expect(p, 'lib/main.dart');
      expect(p, isNot(startsWith('/')));
    });

    test('decodes percent escapes the way the front end spells them', () {
      final Directory work = Directory.systemTemp.createTempSync(
        'kernel_filter_pct_',
      );
      addTearDown(() => work.deleteSync(recursive: true));
      Directory.current = work.path;
      final String? p = dependencyExecPath(
        '+file://${work.path}/lib/my%20lib.dart',
      );
      expect(p, 'lib/my lib.dart');
      expect(p, isNot(contains('%')));
    });

    test('rejects reads outside the working directory', () {
      final Directory work = Directory.systemTemp.createTempSync(
        'kernel_filter_out_',
      );
      addTearDown(() => work.deleteSync(recursive: true));
      Directory.current = work.path;
      expect(dependencyExecPath('+file:///etc/hostname'), isNull);
      expect(dependencyExecPath('+dart:async'), isNull);
      expect(dependencyExecPath('not-a-uri'), isNull);
    });
  });

  group('findDisallowedFlutterDirectives', () {
    late Directory work;
    late Directory savedCwd;

    setUp(() {
      savedCwd = Directory.current;
      work = Directory.systemTemp.createTempSync('kernel_filter_guard_');
      Directory.current = work.path;
    });
    tearDown(() {
      Directory.current = savedCwd.path;
      work.deleteSync(recursive: true);
    });

    void write(String rel, String content) {
      File('${work.path}/$rel')
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    List<String> check(
      Map<String, String> files, [
      List<String> roots = const [],
    ]) {
      for (final MapEntry<String, String> entry in files.entries) {
        write(entry.key, entry.value);
      }
      return findDisallowedFlutterDirectives(files.keys.toList(), roots);
    }

    test('accepts package, dart, relative and app-scheme directives', () {
      const helper = 'int get answer => 42;\n';
      write('lib/helper.dart', helper);
      final _Errors errors = check({
        'lib/helper.dart': helper,
        'lib/main.dart': '''
import 'package:foo/foo.dart';
import 'dart:async';
import 'helper.dart';
import 'org-dartlang-app:///lib/helper.dart';
void main() {}
''',
      });
      expect(errors, isEmpty);
    });

    group('empty segments and a leading slash', () {
      const lib = 'class D {}\n';

      List<String> importsOf(
        String path,
        String directive, [
        Map<String, String> extra = const {},
      ]) => check({
        'demo/lib/src/d.dart': lib,
        'demo/lib/demo.dart': lib,
        ...extra,
        path: '$directive\n',
      });

      test('allows a doubled slash after the first package segment', () {
        expect(
          importsOf('demo/lib/m.dart', "import 'package:demo/src//d.dart';"),
          isEmpty,
        );
      });

      const emptyAfterPkg =
          'package:demo//src/d.dart package:demo///src/d.dart '
          'package:demo/.//etc/passwd package:demo/%2e//etc/passwd '
          'package:demo/%2E//etc/passwd package:demo/src/..//etc/passwd '
          'package:demo/src/%2e%2e//etc/passwd package:./demo//etc/passwd '
          'package:demo/src/%2E%2E//etc/passwd package:%2e/demo//etc/passwd '
          'package:%2E/demo//etc/passwd package:../demo//etc/passwd '
          'package:%2e%2e/demo//etc/passwd package:%2E%2E/demo//etc/passwd';

      void checkRefused(
        String uris, [
        List<String> kinds = const ['import', 'export', 'part', 'part of'],
      ]) {
        for (final String uri in uris.split(' ')) {
          for (final kind in kinds) {
            expect(importsOf('demo/lib/m.dart', "$kind '$uri';"), hasLength(1));
          }
        }
      }

      test('refuses an empty segment right after the package name', () {
        checkRefused(emptyAfterPkg);
      });

      test('refuses a package URI that climbs above its package', () {
        checkRefused(
          'package:demo/src//../../../x.dart package:demo/a//../../../x.dart '
          'package:demo//x package:demo///x package:demo%20/x.dart '
          'package:demo%2e/x.dart package:demo/%2f/x.dart '
          'package:demo/%5c/x.dart',
        );
        const safe = 'package:demo/src//../demo.dart';
        expect(importsOf('demo/lib/m.dart', "import '$safe';"), isEmpty);
      });

      test('refuses package names that are ., .. or empty', () {
        checkRefused(
          'package:. package:.. package: package:/ package:// '
          'package:%2e package:%2E package:%2e%2e package:%2E%2E '
          'package:./ package:../ package:%2e/ package:%2e%2e/ '
          'package:demo/.. package:demo/../ package:demo/../x.dart',
        );
      });

      test('matches Uri.normalizePath verdict for empty segment', () {
        for (final String uri
            in '$emptyAfterPkg '
                    'package:demo//x package:demo///x package:demo/src//d.dart '
                    'package:demo/a//b//c.dart package:demo/src//../d.dart '
                    'package:demo/./src/d.dart package:demo/a/../src/d.dart'
                .split(' ')) {
          final List<String> segs = Uri.parse(uri).normalizePath().pathSegments;
          expect(
            importsOf('demo/lib/m.dart', "import '$uri';").isNotEmpty,
            segs.length > 1 && segs[1].isEmpty,
            reason: uri,
          );
        }
      });

      test('allows a relative empty segment that names a declared source', () {
        const t = 'demo/test/t.dart';
        expect(importsOf(t, "import '../lib/src//d.dart';"), isEmpty);
        expect(importsOf('demo/lib/m.dart', "import 'src//d.dart';"), isEmpty);
      });

      test('refuses a relative empty segment naming no declared source', () {
        for (final uri in ['src//missing.dart', 'a//b.dart', 'src//d.dart/']) {
          expect(importsOf('demo/lib/m.dart', "import '$uri';"), hasLength(1));
        }
      });

      test('refuses app-scheme overshoots across kinds and depths', () {
        const decoys = {'app/lib/x.dart': lib, 'x.dart': lib};
        String msg(String f, String k, String u) =>
            "flutter: $f $k '$u' is not a declared input.";
        for (final (f, u) in const [
          ('app/test/c_test.dart', '../..//app/lib/x.dart'),
          ('app/test/c_test.dart', '../..//x.dart'),
          ('app/bin/main.dart', '../..//app/lib/x.dart'),
          ('app/test/sub/c_test.dart', '../../..//x.dart'),
        ]) {
          for (final k in const ['import', 'export', 'part']) {
            expect(importsOf(f, "$k '$u';", decoys), [msg(f, k, u)]);
          }
          final ok = '${'../' * ('/'.allMatches(f).length - 1)}lib/x.dart';
          final cond = "import '$ok' if (dart.library.io) '$u';";
          expect(importsOf(f, cond, decoys), [msg(f, 'import', u)]);
        }
        const stg = 'stage/app/test/c_test.dart';
        const esc = '../..//app/lib/x.dart';
        const stgMap = {'stage/app/lib/x.dart': lib, 'stage/x.dart': lib};
        final List<String> stgGot = check(
          {...stgMap, stg: "import '$esc';\n"},
          const ['stage'],
        );
        expect(stgGot, [msg(stg, 'import', esc)]);
        const ct = 'app/test/c_test.dart';
        expect(importsOf(ct, "import '../lib//x.dart';", decoys), isEmpty);
        const bm = 'app/bin/main.dart';
        expect(importsOf(bm, "import '../lib//x.dart';", decoys), isEmpty);
        const sub = 'app/test/sub/c_test.dart';
        expect(importsOf(sub, "import '../..//lib/x.dart';", decoys), isEmpty);
        final String cMsg = msg(ct, 'import', '..//x.dart');
        expect(importsOf(ct, "import '..//x.dart';", decoys), [cMsg]);
      });

      test('matches Uri.resolve verdict under the app scheme (table)', () {
        const dirs =
            ' test/ app/ app/test/ app/test/sub/ bin/ app/bin/ app/bin/sub/';
        final decoys = <String, String>{
          for (final String d in dirs.split(' ')) ...{
            '${d}x.dart': lib,
            '${d}app/lib/x.dart': lib,
          },
        };
        decoys.forEach(write);
        final List<String> keys = decoys.keys.toList();
        const importers =
            'test/t.dart app/test/c_test.dart app/test/sub/c_test.dart '
            'bin/main.dart app/bin/main.dart app/bin/sub/main.dart';
        const tails =
            '..//x.dart ..//app/lib/x.dart .//x.dart '
            '..///x.dart ..//../x.dart ..///../x.dart';
        for (final String from in importers.split(' ')) {
          final Uri base = Uri.parse('org-dartlang-app:///$from');
          for (final k in const ['import', 'part']) {
            for (var n = 0; n <= 4; n++) {
              for (final String tail in tails.split(' ')) {
                final ref = '${'../' * n}$tail';
                write(from, "$k '$ref';\n");
                final List<String> got = findDisallowedFlutterDirectives(
                  [...keys, from],
                  const [],
                );
                final bool bad = base.resolve(ref).pathSegments.first.isEmpty;
                expect(got.isNotEmpty, bad, reason: '$k $ref from $from');
              }
            }
          }
        }
      });

      test('counts an empty segment before .. as a segment', () {
        // The front end reads `src//../e.dart` as `src/e.dart`; skipping the
        // empty segment would name `lib/e.dart` instead.
        const m = 'demo/lib/m.dart';
        const e1 = {'demo/lib/e.dart': lib};
        const e2 = {'demo/lib/src/e.dart': lib};
        expect(importsOf(m, "import 'src//../e.dart';", e1), hasLength(1));
        expect(importsOf(m, "import 'src//../e.dart';", e2), isEmpty);
      });

      test(
        'refuses relative empty-segment overshoots past package root (table)',
        () {
          final decoys = <String, String>{
            for (final String p in 'demo/lib/ demo/ '.split(' '))
              '${p}x.dart': lib,
          };
          for (final (from, tgt) in const [
            ('demo/lib/c.dart', 'c.dart'),
            ('demo/lib/src/c.dart', 'src/c.dart'),
          ]) {
            for (final kind in const ['import', 'part']) {
              for (var extra = 0; extra <= 3; extra++) {
                final ref = '${'../' * extra}..//x.dart';
                final directive = "$kind '$ref';";
                final Uri base = Uri.parse('package:demo/$tgt');
                final List<String> segs = base.resolve(ref).pathSegments;
                expect(
                  importsOf(from, directive, decoys).isNotEmpty,
                  segs.length > 1 && segs[1].isEmpty,
                  reason: '$directive from $from',
                );
              }
            }
          }
        },
      );

      test(
        'refuses relative empty-segment overshoots at every depth and kind',
        () {
          final decoys = <String, String>{
            for (final String p in 'demo/lib/ demo/ '.split(' ')) ...{
              '${p}x.dart': lib,
              '${p}y.dart': lib,
            },
          };
          for (final (from, refs) in [
            ('demo/lib/c.dart', ['..//x.dart']),
            (
              'demo/lib/src/c.dart',
              '..//x.dart ../..//x.dart ../../..//x.dart ../..//y.dart ../../..//y.dart'
                  .split(' '),
            ),
          ]) {
            for (final ref in refs) {
              for (final k in const ['import', 'export', 'part']) {
                expect(importsOf(from, "$k '$ref';", decoys), hasLength(1));
              }
              final d = from.contains('src') ? 'd.dart' : 'demo.dart';
              final cond = "import '$d' if (dart.library.io) '$ref';";
              expect(importsOf(from, cond, decoys), hasLength(1));
            }
          }
        },
      );

      test('allows a relative empty segment that stays inside the package', () {
        const srcLib = {'demo/lib/src/src/b.dart': lib};
        const srcB = {'demo/lib/src/b.dart': lib};
        const c = 'demo/lib/src/c.dart';
        expect(importsOf(c, "import 'src//../b.dart';", srcLib), isEmpty);
        expect(importsOf(c, "import '../src//b.dart';", srcB), isEmpty);
        const sub = 'demo/lib/src/sub/c.dart';
        expect(importsOf(sub, "import '..//src/b.dart';", srcLib), isEmpty);
      });

      test('allows a leading slash that names a declared source in lib', () {
        expect(
          importsOf('demo/lib/demo.dart', "export '/src/d.dart';"),
          isEmpty,
        );
      });

      test('refuses leading-slash spellings that stay unsafe', () {
        const bad =
            '/src/missing.dart //src/d.dart /src//d.dart '
            '/src/ /../d.dart /etc/passwd';
        for (final String u in bad.split(' ')) {
          expect(
            importsOf('demo/lib/demo.dart', "export '$u';"),
            hasLength(1),
            reason: u,
          );
        }
        expect(
          importsOf('demo/tool/t.dart', "import '/src/d.dart';"),
          hasLength(1),
        );
      });
    });

    test('refuses a file: import of an undeclared workspace file', () {
      write('pkg/lib/secret.dart', 'const secret = 1;\n');
      const u = 'file:///proc/self/cwd/pkg/lib/secret.dart';
      final _Errors errors = check({
        'lib/main.dart': "import '$u';\nvoid main() {}\n",
      });
      expect(errors, hasLength(1));
      expect(errors.single, contains('lib/main.dart'));
      expect(errors.single, contains("import '$u'"));
    });

    test('refuses a file: import of a host path outside the workspace', () {
      final _Errors errors = check({
        'lib/main.dart': "import 'file:///etc/hostname';\nvoid main() {}\n",
      });
      expect(errors, hasLength(1));
      expect(errors.single, contains('is not a declared input'));
    });

    test('refuses file: spellings: case, authority, bare, backslash', () {
      for (final uri in [
        "FILE:///etc/hostname",
        "file://localhost/etc/hostname",
        "file:lib/../secret.dart",
        r"file:lib\..\secret.dart",
        "file:///etc/hostname?query",
        "file:///etc/hostname#fragment",
      ]) {
        final _Errors errors = check({
          'lib/main.dart': "import '$uri';\nvoid main() {}\n",
        });
        expect(errors, hasLength(1), reason: uri);
      }
    });

    test('refuses triple-quoted URIs with a whitespace first line', () {
      // The front end drops a whitespace-only first line of a multi-line
      // string literal and reads a different file than the resolvers see, so
      // a scanned URI holding a line break is refused however it spells its
      // target.
      write('secret.dart', 'const secret = 1;\n');
      for (final spelling in [
        "import '''   \n../secret.dart''';",
        'export """\t\n../secret.dart""";',
        "part '''   \n../secret.dart''';",
        "import '''../secret.dart\n''';",
      ]) {
        final _Errors errors = check({
          'lib/main.dart': '$spelling\nvoid main() {}\n',
        });
        expect(errors, hasLength(1), reason: spelling);
        expect(errors.single, contains('lib/main.dart'), reason: spelling);
        expect(
          errors.single,
          contains('is not a declared input'),
          reason: spelling,
        );
      }
    });

    test('refuses percent-encoded escapes naming a host file', () {
      const m = "import 'file:///etc%2fhostname';\nvoid main() {}\n";
      expect(check({'lib/main.dart': m}), hasLength(1));
    });

    test('refuses a relative import climbing out of the declared inputs', () {
      // On the host but declared by no target: readable under every strategy,
      // so only the guard can stop it.
      write('secret.dart', 'const secret = 1;\n');
      final _Errors errors = check({
        'lib/main.dart': "import '../secret.dart';\nvoid main() {}\n",
      });
      expect(errors, hasLength(1));
      expect(errors.single, contains('lib/main.dart'));
      expect(errors.single, contains("import '../secret.dart'"));
    });

    test('refuses an absolute path import', () {
      final _Errors errors = check({
        'lib/main.dart': "import '/etc/hostname';\nvoid main() {}\n",
      });
      expect(errors, hasLength(1));
    });

    test('refuses a package: URI climbing above its package', () {
      final _Errors errors = check({
        'lib/main.dart':
            "import 'package:foo/../../secret.dart';\nvoid main() {}\n",
      });
      expect(errors, hasLength(1));
    });

    test('refuses a file: URI in an untaken conditional branch', () {
      const helper = 'int get answer => 42;\n';
      write('lib/helper.dart', helper);
      const src =
          "import 'helper.dart' if (dart.library.html) 'file:///etc/hostname';\n"
          "import 'helper.dart';\nvoid main() {}\n";
      expect(
        check({'lib/helper.dart': helper, 'lib/main.dart': src}),
        hasLength(1),
      );
    });

    test('refuses file: exports and parts', () {
      final _Errors exportErrors = check({
        'lib/main.dart': "export 'file:///etc/hostname';\nvoid main() {}\n",
      });
      expect(exportErrors, hasLength(1));
      final _Errors partErrors = check({
        'lib/main.dart': "part 'file:///etc/hostname';\nvoid main() {}\n",
      });
      expect(partErrors, hasLength(1));
    });

    test('refuses an app-scheme URI naming no declared key', () {
      const helper = 'int get answer => 42;\n';
      write('lib/helper.dart', helper);
      const src =
          "import 'org-dartlang-app:///other/unlisted.dart';\n"
          "import 'helper.dart';\nvoid main() {}\n";
      expect(
        check({'lib/helper.dart': helper, 'lib/main.dart': src}),
        hasLength(1),
      );
    });

    test('accepts a generated part and its part of, in both directions', () {
      // A declared codegen sibling lives under bazel-out/<config>/bin/ and is
      // staged at its workspace-relative path: the source's `part` and the
      // sibling's `part of` name the same multi-root key the front end looks
      // up, so both directions are declared inputs.
      const stage = 'bazel-out/k8-fastbuild/bin/app.dill.1a2b3c4d.stage';
      final _Errors errors = check(
        {
          'lib/user.dart': "part 'user.g.dart';\n",
          'bazel-out/k8-fastbuild/bin/lib/user.g.dart':
              "part of 'user.dart';\n",
        },
        [stage],
      );
      expect(errors, isEmpty);
    });

    test('accepts generated parts in a dependency package', () {
      const stage = 'bazel-out/k8-fastbuild/bin/app.dill.1a2b3c4d.stage';
      final _Errors errors = check(
        {
          'dep_part/lib/settings.dart': "part 'settings.g.dart';\n",
          'bazel-out/k8-fastbuild/bin/dep_part/lib/settings.g.dart':
              "part of 'settings.dart';\n",
        },
        [stage],
      );
      expect(errors, isEmpty);
    });

    test('still refuses a part whose generated sibling is undeclared', () {
      final _Errors errors = check({'lib/user.dart': "part 'user.g.dart';\n"});
      expect(errors, hasLength(1));
      expect(errors.single, contains("part 'user.g.dart'"));
    });

    test('refuses a disallowed directive after an invalid byte', () {
      // The front end decodes malformed UTF-8 instead of reporting it, so the
      // guard scans what it can rather than skipping the file.
      final file = File('${work.path}/lib/main.dart')
        ..createSync(recursive: true)
        ..writeAsBytesSync([
          ...'// comment '.codeUnits,
          0xff,
          ...'\nimport \'file:///etc/hostname\';\nvoid main() {}\n'.codeUnits,
        ]);
      final _Errors errors = findDisallowedFlutterDirectives([
        'lib/main.dart',
      ], const []);
      expect(errors, hasLength(1));
      expect(errors.single, contains('lib/main.dart'));
      expect(errors.single, contains('is not a declared input'));
      expect(file.existsSync(), isTrue);
    });

    test('accepts a malformed source with no disallowed directive', () {
      // The compiler accepts malformed sources, so a clean one is not refused.
      final bytes = <int>[
        ...'// '.codeUnits,
        0xff,
        ...'\nvoid main() {}\n'.codeUnits,
      ];
      File('${work.path}/lib/main.dart')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      expect(
        findDisallowedFlutterDirectives(['lib/main.dart'], const []),
        isEmpty,
      );
    });

    test('accepts a valid source importing a malformed declared sibling', () {
      // A skipped file would be missing from the declared set, so a valid
      // importer of a malformed sibling would be refused as undeclared.
      final bytes = <int>[
        ...'// '.codeUnits,
        0xff,
        ...'\nint get answer => 42;\n'.codeUnits,
      ];
      File('${work.path}/lib/sibling.dart')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      write('lib/main.dart', "import 'sibling.dart';\nvoid main() {}\n");
      const srcs = ['lib/main.dart', 'lib/sibling.dart'];
      expect(findDisallowedFlutterDirectives(srcs, const []), isEmpty);
    });
  });

  group('runFiltered', () {
    late Directory dir;
    late Directory work;
    late Directory savedCwd;

    setUp(() {
      savedCwd = Directory.current;
      dir = Directory.systemTemp.createTempSync('kernel_filter_');
      work = Directory('${dir.path}/work')..createSync();
      Directory.current = work.path;
    });
    tearDown(() {
      Directory.current = savedCwd.path;
      dir.deleteSync(recursive: true);
    });

    void writeWork(String rel, String content) {
      File('${work.path}/$rel')
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    String writeManifest(
      List<String> sources, [
      List<String> staged = const [],
      List<String> reads = const [],
      List<String> roots = const [],
      String? output,
      List<String> entrypoint = const [],
    ]) {
      final lines = <String>[
        ...sources,
        '# staged',
        ...staged,
        '# allowed-reads',
        ...reads,
        '# filesystem-roots',
        ...roots,
        '# entrypoint',
        ...entrypoint,
        '# output',
        if (output != null) output,
      ];
      final manifest = File('${dir.path}/inputs.manifest')
        ..writeAsStringSync('${lines.join('\n')}\n');
      return manifest.path;
    }

    File fakeCompiler(String name, String body) =>
        File('${dir.path}/$name.dart')..writeAsStringSync(body);

    Future<({int code, String out, String err})> run(List<String> argv) async {
      final out = StringBuffer();
      final err = StringBuffer();
      final int code = await runFiltered(argv, out, err);
      return (code: code, out: '$out', err: '$err');
    }

    Future<({int code, String out, String err})> runSource(
      String stdoutText,
      int exitCode, {
      List<String> sources = const [],
      List<String> extraArgs = const [],
    }) async {
      final File script = fakeCompiler(
        'fake',
        'import "dart:io";\n'
            'void main() {\n'
            '  stdout.write(r"""$stdoutText""");\n'
            '  stderr.writeln("to stderr");\n'
            '  exit($exitCode);\n'
            '}\n',
      );
      return run([
        '--declared-inputs',
        writeManifest(sources),
        '--',
        Platform.resolvedExecutable,
        script.path,
        ...extraArgs,
      ]);
    }

    File fakeReads(String name, List<String> paths) {
      final String body = [for (final p in paths) '+file://$p'].join(r'\n');
      final out = 'result $_id\\n$_id\\n$body\\n$_id app.dill 0';
      return fakeCompiler(
        name,
        'import "dart:io";\nvoid main() => stdout.writeln("$out");\n',
      );
    }

    test('a successful compile prints nothing', () async {
      writeWork('lib/main.dart', 'void main() {}\n');
      final _Run r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart']),
        '--',
        Platform.resolvedExecutable,
        fakeCompiler(
          'clean',
          'import "dart:io";\n'
              'void main() {\n'
              '  stdout.writeln("result $_id");\n'
              '  stdout.writeln("$_id");\n'
              '  stdout.writeln("+file://${work.path}/lib/main.dart");\n'
              '  stdout.writeln("$_id app_flutter.dill 0");\n'
              '}\n',
        ).path,
      ]);
      expect(r.code, 0);
      expect(r.out.trim(), isEmpty);
    });

    test('a compile error still shows, with its exit code', () async {
      const error = 'lib/main.dart:3:5: Error: Expected `;` after this.';
      final _Run r = await runSource(
        'result $_id\n$_id\n$error\n$_id app_flutter.dill 1\n',
        1,
      );
      expect(r.code, 1);
      expect(r.out, contains(error));
      expect(r.out, isNot(contains(_id)));
      expect(r.err, contains('to stderr'));
    });

    test('refuses a call with no command', () async {
      final err = StringBuffer();
      expect(await runFiltered(['--'], StringBuffer(), err), 2);
      expect(err.toString(), contains('Usage'));
    });

    test('refuses a call with no declared-inputs manifest', () async {
      final _Run r = await run(['--', Platform.resolvedExecutable, 'x.dart']);
      expect(r.code, 2);
      expect(r.err, contains('--declared-inputs'));
    });

    test('refuses a file: import before running the compiler', () async {
      writeWork('lib/main.dart', """
import 'file:///etc/hostname';
void main() {}
""");
      final invoked = File('${dir.path}/invoked');
      final File script = fakeCompiler(
        'counting',
        'import "dart:io";\n'
            'void main() {\n'
            '  File(r"${invoked.path}").writeAsStringSync("ran");\n'
            '}\n',
      );
      final _Run r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart']),
        '--',
        Platform.resolvedExecutable,
        script.path,
      ]);
      expect(r.code, 1);
      expect(r.err, contains('lib/main.dart'));
      expect(r.err, contains("import 'file:///etc/hostname'"));
      expect(r.err, contains('is not a declared input'));
      expect(invoked.existsSync(), isFalse);
    });

    test('refuses a triple-quoted import with a whitespace first line before running the compiler', () async {
      writeWork('secret.dart', 'const secret = 1;\n');
      writeWork(
        'lib/main.dart',
        "import '''   \n../secret.dart''';\nvoid main() {}\n",
      );
      final invoked = File('${dir.path}/invoked');
      final File script = fakeCompiler(
        'counting',
        'import "dart:io";\n'
            'void main() {\n'
            '  File(r"${invoked.path}").writeAsStringSync("ran");\n'
            '}\n',
      );
      final _Run r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart']),
        '--',
        Platform.resolvedExecutable,
        script.path,
      ]);
      expect(r.code, 1);
      expect(r.err, contains('lib/main.dart'));
      expect(r.err, contains('is not a declared input'));
      expect(invoked.existsSync(), isFalse);
    });

    test(
      'fails a read outside the declared inputs and drops the dill',
      () async {
        writeWork('lib/main.dart', 'void main() {}\n');
        final output = File('${work.path}/app.dill')
          ..writeAsStringSync('stale bytes');
        final File script = fakeReads('reader', [
          '${work.path}/lib/main.dart',
          '/etc/hostname',
        ]);
        final _Run r = await run([
          '--declared-inputs',
          writeManifest(['lib/main.dart'], [], [], [], 'app.dill'),
          '--',
          Platform.resolvedExecutable,
          script.path,
          '--output-dill',
          output.path,
        ]);
        expect(r.code, 1);
        expect(r.err, contains('+file:///etc/hostname'));
        expect(r.err, contains('not a declared input'));
        expect(output.existsSync(), isFalse);
      },
    );

    test('accepts a read named by the manifest', () async {
      writeWork('lib/main.dart', 'void main() {}\n');
      final summary = File('${work.path}/app_summary.dill')
        ..writeAsStringSync('compiled bytes');
      final File script = fakeReads('import_reader', [
        '${work.path}/lib/main.dart',
        summary.path,
      ]);
      final _Run r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart'], [], ['app_summary.dill']),
        '--',
        Platform.resolvedExecutable,
        script.path,
        '--output-dill',
        '${work.path}/app.dill',
        '--import-dill=app_summary.dill',
      ]);
      expect(r.code, 0, reason: r.err);
      expect(r.out.trim(), isEmpty);
    });

    test('allows a manifest read the argv never names', () async {
      // The argv carries no `--import-dill` at all: the manifest alone
      // allows the summary read.
      writeWork('lib/main.dart', 'void main() {}\n');
      final summary = File('${work.path}/app_summary.dill')
        ..writeAsStringSync('compiled bytes');
      final File script = fakeReads('manifest_only_reader', [
        '${work.path}/lib/main.dart',
        summary.path,
      ]);
      final _Run r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart'], [], ['app_summary.dill']),
        '--',
        Platform.resolvedExecutable,
        script.path,
        '--output-dill',
        '${work.path}/app.dill',
      ]);
      expect(r.code, 0, reason: r.err);
      expect(r.out.trim(), isEmpty);
    });

    test('an argv-only flag allow-lists nothing', () async {
      // Every smuggle spelling in the argv — `vm_flags` position (before
      // any snapshot) and `extra_flags` position alike, `=` and space
      // forms — while the manifest names no such read.
      writeWork('lib/main.dart', 'void main() {}\n');
      final sneak = File('${work.path}/sneak.dill')..writeAsStringSync('sneak');
      final output = File('${work.path}/app.dill')
        ..writeAsStringSync('stale bytes');
      final File script = fakeReads('argv_spoof', [
        '${work.path}/lib/main.dart',
        sneak.path,
      ]);
      final _Run r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart'], [], [], [], 'app.dill'),
        '--',
        Platform.resolvedExecutable,
        script.path,
        '--packages=sneak.dill',
        '--platform',
        'sneak.dill',
        '--from-dill=sneak.dill',
        '--import-dill=sneak.dill',
        '--native-assets',
        'sneak.dill',
        '--output-dill',
        '${work.path}/app.dill',
      ]);
      expect(r.code, 1);
      expect(r.err, contains('+file://${sneak.path}'));
      expect(r.err, contains('not a declared input'));
      expect(output.existsSync(), isFalse);
    });

    test('a read under an argv-only root is refused', () async {
      // The argv mounts the mirror via `--filesystem-root`, but the manifest
      // names no such read: allowances come only from the manifest, so the
      // mount buys the compile no read.
      writeWork('lib/main.dart', 'void main() {}\n');
      final mirror = Directory('${dir.path}/mirror')
        ..createSync(recursive: true);
      final output = File('${work.path}/app.dill')
        ..writeAsStringSync('stale bytes');
      final File script = fakeReads('mirror_reader', [
        '${work.path}/lib/main.dart',
        '${mirror.path}/evil.dart',
      ]);
      final _Run r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart'], [], [], [], 'app.dill'),
        '--',
        Platform.resolvedExecutable,
        script.path,
        '--filesystem-root',
        mirror.path,
        '--output-dill',
        output.path,
      ]);
      expect(r.code, 1);
      expect(r.err, contains('+file://${mirror.path}/evil.dart'));
      expect(r.err, contains('not a declared input'));
      expect(output.existsSync(), isFalse);
    });

    test(
      'the refusal deletes the manifest output, not the argv --output-dill',
      () async {
        writeWork('lib/main.dart', 'void main() {}\n');
        final decoy = File('${work.path}/decoy.dill')
          ..writeAsStringSync('decoy bytes');
        final output = File('${work.path}/app.dill')
          ..writeAsStringSync('stale bytes');
        final File script = fakeReads('spoofed_output', [
          '${work.path}/lib/main.dart',
          '/etc/hostname',
        ]);
        final _Run r = await run([
          '--declared-inputs',
          writeManifest(['lib/main.dart'], [], [], [], 'app.dill'),
          '--',
          Platform.resolvedExecutable,
          script.path,
          '--output-dill',
          decoy.path,
        ]);
        expect(r.code, 1);
        expect(r.err, contains('+file:///etc/hostname'));
        expect(r.err, contains('not a declared input'));
        expect(decoy.readAsStringSync(), 'decoy bytes');
        expect(output.existsSync(), isFalse);
      },
    );

    test(
      'an undeclared source beside the --import-dill is still refused',
      () async {
        writeWork('lib/main.dart', 'void main() {}\n');
        final summary = File('${work.path}/app_summary.dill')
          ..writeAsStringSync('compiled bytes');
        final File script = fakeReads('import_sneak_reader', [
          '${work.path}/lib/main.dart',
          summary.path,
          '${work.path}/lib/sneak.dart',
        ]);
        final _Run r = await run([
          '--declared-inputs',
          writeManifest(['lib/main.dart'], [], ['app_summary.dill']),
          '--',
          Platform.resolvedExecutable,
          script.path,
          '--output-dill',
          '${work.path}/app.dill',
          '--import-dill',
          'app_summary.dill',
        ]);
        expect(r.code, 1);
        expect(r.err, contains('+file://${work.path}/lib/sneak.dart'));
        expect(r.err, contains('not a declared input'));
      },
    );

    test('accepts reads of declared sources and staged copies', () async {
      writeWork('lib/main.dart', 'void main() {}\n');
      final File script = fakeCompiler(
        'clean_reader',
        'import "dart:io";\n'
            'void main() {\n'
            '  stdout.writeln("result $_id");\n'
            '  stdout.writeln("$_id");\n'
            '  stdout.writeln("+file://${work.path}/lib/main.dart");\n'
            '  stdout.writeln("$_id app.dill 0");\n'
            '}\n',
      );
      final _Run r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart'], ['out/stage/lib/main.dart']),
        '--',
        Platform.resolvedExecutable,
        script.path,
        '--output-dill',
        '${work.path}/app.dill',
      ]);
      expect(r.code, 0, reason: r.err);
      expect(r.out.trim(), isEmpty);
    });

    test('an unavailable plugin fails loudly: no retry, no registrant rewrite', () async {
      writeWork('lib/main.dart', 'void main() {}\n');
      final registrant = File('${work.path}/plugin_registrant.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          "import 'package:webby/webby.dart';\n"
          'void register() => WebbyPlugin.registerWith();\n',
        );
      const original = "import 'package:webby/webby.dart';\n";
      final invocations = File('${dir.path}/invocations');
      final File script = fakeCompiler(
        'unavailable',
        'import "dart:io";\n'
            'void main() {\n'
            '  File(r"${invocations.path}").writeAsStringSync("x", mode: FileMode.append);\n'
            '  stdout.writeln("result $_id");\n'
            '  stdout.writeln("lib/main.dart: Error: package:webby is not available on this platform.");\n'
            '  stdout.writeln("$_id app.dill 1");\n'
            '  exit(1);\n'
            '}\n',
      );
      final _Run r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart']),
        '--',
        Platform.resolvedExecutable,
        script.path,
      ]);
      expect(r.code, 1);
      // The frontend's error passes through, with a hint that the build
      // fails instead of shipping without the plugin.
      expect(r.out, contains('is not available on this platform.'));
      expect(r.err, contains('not available on the compiled platform'));
      // No retry: the compiler ran exactly once ...
      expect(invocations.readAsStringSync(), 'x');
      // ... and the registrant is untouched.
      expect(registrant.readAsStringSync(), contains(original));
      expect(
        registrant.readAsStringSync(),
        contains('WebbyPlugin.registerWith();'),
      );
    });

    test('leaves staged flutter_web_plugins sources untouched', () async {
      writeWork('lib/main.dart', 'void main() {}\n');
      const originalRegistry =
          "import 'dart:ui_web' as ui_web;\n"
          'void register() => ui_web.setPluginHandler((a, b, c) {});\n';
      final stagedDir = Directory(
        '${work.path}/stage/external/x__flutter_web_plugins/lib',
      )..createSync(recursive: true);
      final stagedRegistry = File('${stagedDir.path}/plugin_registry.dart')
        ..writeAsStringSync(originalRegistry);
      final stub = File('${work.path}/stage/app/plugin_web_ui_web_stub.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('// stub\n');
      final File script = fakeCompiler(
        'nop',
        'import "dart:io";\n'
            'void main() {\n'
            '  stdout.writeln("result $_id");\n'
            '  stdout.writeln("$_id");\n'
            '  stdout.writeln("+file://${work.path}/lib/main.dart");\n'
            '  stdout.writeln("$_id app.dill 0");\n'
            '}\n',
      );
      final _Run r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart']),
        '--',
        Platform.resolvedExecutable,
        script.path,
        '--filesystem-root',
        '${work.path}/stage',
        '--filesystem-scheme',
        'org-dartlang-app',
      ]);
      expect(r.code, 0, reason: r.err);
      expect(stagedRegistry.readAsStringSync(), originalRegistry);
      expect(stub.readAsStringSync(), '// stub\n');
    });

    test('fails closed when a successful compile reported no reads', () async {
      // A real compile reads at least its entrypoint: zero `+` lines means
      // the report was silenced, so the build fails instead of caching
      // unverified bytes.
      writeWork('lib/main.dart', 'void main() {}\n');
      final output = File('${work.path}/app.dill')
        ..writeAsStringSync('stale bytes');
      final File script = fakeCompiler(
        'silent',
        'import "dart:io";\n'
            'void main() {\n'
            '  stdout.writeln("result $_id");\n'
            '  stdout.writeln("$_id");\n'
            '  stdout.writeln("$_id app.dill 0");\n'
            '}\n',
      );
      final _Run r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart'], [], [], [], 'app.dill'),
        '--',
        Platform.resolvedExecutable,
        script.path,
        '--output-dill',
        output.path,
      ]);
      expect(r.code, 1);
      expect(r.err, contains('no dependency reads'));
      expect(r.err, contains('--print-incremental-dependencies'));
      expect(output.existsSync(), isFalse);
    });

    test('fails closed when the report names no declared source', () async {
      writeWork('lib/main.dart', 'void main() {}\n');
      final output = File('${work.path}/app.dill')
        ..writeAsStringSync('stale bytes');
      final File script = fakeCompiler(
        'sourceless',
        'import "dart:io";\n'
            'void main() {\n'
            '  stdout.writeln("result $_id");\n'
            '  stdout.writeln("$_id");\n'
            '  stdout.writeln("+file://${work.path}/pkg_config.json");\n'
            '  stdout.writeln("$_id app.dill 0");\n'
            '}\n',
      );
      final _Run r = await run([
        '--declared-inputs',
        writeManifest(
          ['lib/main.dart'],
          [],
          ['pkg_config.json'],
          [],
          'app.dill',
        ),
        '--',
        Platform.resolvedExecutable,
        script.path,
        '--output-dill',
        output.path,
      ]);
      expect(r.code, 1);
      expect(r.err, contains('none names a declared source'));
      expect(output.existsSync(), isFalse);
    });

    test('fails closed when the report does not name the entrypoint', () async {
      writeWork('lib/main.dart', 'void main() {}\n');
      writeWork('lib/a.dart', 'int get answer => 42;\n');
      final output = File('${work.path}/app.dill')
        ..writeAsStringSync('stale bytes');
      final File script = fakeCompiler(
        'entryless',
        'import "dart:io";\n'
            'void main() {\n'
            '  stdout.writeln("result $_id");\n'
            '  stdout.writeln("$_id");\n'
            '  stdout.writeln("+file://${work.path}/lib/a.dart");\n'
            '  stdout.writeln("$_id app.dill 0");\n'
            '}\n',
      );
      final _Run r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart', 'lib/a.dart'], [], [], [], 'app.dill'),
        '--',
        Platform.resolvedExecutable,
        script.path,
        '--output-dill',
        output.path,
      ]);
      expect(r.code, 1);
      expect(r.err, contains('lib/main.dart'));
      expect(output.existsSync(), isFalse);
    });

    test(
      'fails closed on a report entry that names no parseable file',
      () async {
        writeWork('lib/main.dart', 'void main() {}\n');
        final output = File('${work.path}/app.dill')
          ..writeAsStringSync('stale bytes');
        final File script = fakeCompiler(
          'badentry',
          'import "dart:io";\n'
              'void main() {\n'
              '  stdout.writeln("result $_id");\n'
              '  stdout.writeln("$_id");\n'
              '  stdout.writeln("+file://${work.path}/lib/main.dart");\n'
              '  stdout.writeln("+dart:async");\n'
              '  stdout.writeln("$_id app.dill 0");\n'
              '}\n',
        );
        final _Run r = await run([
          '--declared-inputs',
          writeManifest(['lib/main.dart'], [], [], [], 'app.dill'),
          '--',
          Platform.resolvedExecutable,
          script.path,
          '--output-dill',
          output.path,
        ]);
        expect(r.code, 1);
        expect(r.err, contains('+dart:async'));
        expect(output.existsSync(), isFalse);
      },
    );

    test('accepts the entrypoint under its staged twin spelling', () async {
      writeWork('lib/main.dart', 'void main() {}\n');
      final File script = fakeCompiler(
        'stagedentry',
        'import "dart:io";\n'
            'void main() {\n'
            '  stdout.writeln("result $_id");\n'
            '  stdout.writeln("$_id");\n'
            '  stdout.writeln("+file://${work.path}/out/stage/lib/main.dart");\n'
            '  stdout.writeln("$_id app.dill 0");\n'
            '}\n',
      );
      final _Run r = await run([
        '--declared-inputs',
        writeManifest(
          ['lib/main.dart'],
          ['out/stage/lib/main.dart'],
          [],
          [],
          null,
          ['lib/main.dart', 'out/stage/lib/main.dart'],
        ),
        '--',
        Platform.resolvedExecutable,
        script.path,
      ]);
      expect(r.code, 0, reason: r.err);
      expect(r.out.trim(), isEmpty);
    });

    test(
      'forces --print-incremental-dependencies after the caller flags',
      () async {
        writeWork('lib/main.dart', 'void main() {}\n');
        final seen = File('${dir.path}/seen_args.txt');
        final File script = fakeCompiler(
          'recorder',
          'import "dart:io";\n'
              'void main(List<String> args) {\n'
              '  File(r"${seen.path}").writeAsStringSync(args.join("\\n"));\n'
              '  stdout.writeln("result $_id");\n'
              '  stdout.writeln("$_id");\n'
              '  stdout.writeln("+file://${work.path}/lib/main.dart");\n'
              '  stdout.writeln("$_id app.dill 0");\n'
              '}\n',
        );
        final _Run r = await run([
          '--declared-inputs',
          writeManifest(['lib/main.dart']),
          '--',
          Platform.resolvedExecutable,
          script.path,
          '--incremental',
          '--no-print-incremental-dependencies',
          'entry.dart',
        ]);
        expect(r.code, 0, reason: r.err);
        final _Errors args = seen.readAsStringSync().split('\n');
        final int forced = args.lastIndexOf('--print-incremental-dependencies');
        expect(forced, isNot(-1));
        expect(args.last, 'entry.dart');
        expect(forced, args.length - 2);
        expect(
          args.indexOf('--no-print-incremental-dependencies'),
          lessThan(forced),
        );
      },
    );

    test('withForcedDependencyReport inserts the flag before the entry', () {
      const flag = '--print-incremental-dependencies';
      expect(withForcedDependencyReport([]), [flag]);
      expect(withForcedDependencyReport(['script.dart']), [
        'script.dart',
        flag,
      ]);
      expect(
        withForcedDependencyReport(['snap', '--incremental', 'main.dart']),
        ['snap', '--incremental', flag, 'main.dart'],
      );
    });

    test('--incremental does not silence the check', () async {
      // The e2e/smoke consumer passes `--incremental`: an undeclared read
      // beside it is still refused.
      writeWork('lib/main.dart', 'void main() {}\n');
      final File script = fakeCompiler(
        'incremental_reader',
        'import "dart:io";\n'
            'void main() {\n'
            '  stdout.writeln("result $_id");\n'
            '  stdout.writeln("$_id");\n'
            '  stdout.writeln("+file://${work.path}/lib/main.dart");\n'
            '  stdout.writeln("+file://${work.path}/lib/sneak.dart");\n'
            '  stdout.writeln("$_id app.dill 0");\n'
            '}\n',
      );
      final _Run r = await run([
        '--declared-inputs',
        writeManifest(['lib/main.dart']),
        '--',
        Platform.resolvedExecutable,
        script.path,
        '--incremental',
      ]);
      expect(r.code, 1);
      expect(r.err, contains('+file://${work.path}/lib/sneak.dart'));
      expect(r.err, contains('not a declared input'));
    });
  });

  group('resolveFlutterKeyRelativeTarget', () {
    String? r(String u, String f) => resolveFlutterKeyRelativeTarget(u, f);
    test('resolves a sibling against the importing file', () {
      expect(r('b.dart', 'app/lib/main.dart'), 'app/lib/b.dart');
      expect(r('c.dart', 'app/lib/main.dart'), 'app/lib/c.dart');
    });

    test('an empty reference names the importing file itself', () {
      expect(r('', 'app/lib/main.dart'), 'app/lib/main.dart');
      expect(r('', 'main.dart'), 'main.dart');
    });

    test('a query resolves its path part', () {
      expect(r('b.dart?x=1', 'app/lib/main.dart'), 'app/lib/b.dart');
      expect(
        r('b.dart', 'app/lib/main.dart'),
        r('b.dart?x=1', 'app/lib/main.dart'),
      );
    });

    test('dot segments stay inside the key root', () {
      expect(r('sub/./b.dart', 'app/main.dart'), 'app/sub/b.dart');
      expect(r('../x.dart', 'app/lib/main.dart'), 'app/x.dart');
      expect(r('../../x.dart', 'main.dart'), 'x.dart');
    });

    test('backslashes separate like slashes', () {
      expect(r(r'sub\b.dart', 'app/main.dart'), 'app/sub/b.dart');
    });

    test('percent escapes decode once', () {
      expect(r('my%20lib.dart', 'app/main.dart'), 'app/my lib.dart');
    });

    test('refuses non-relative spellings', () {
      expect(r('dart:async', 'app/main.dart'), isNull);
      expect(r('package:a/b.dart', 'app/main.dart'), isNull);
      expect(r('//x/y.dart', 'app/main.dart'), isNull);
      expect(r('/x.dart', 'app/main.dart'), isNull);
      expect(r('a.dart#frag', 'app/main.dart'), isNull);
    });

    test('counts an empty path segment as a segment, then drops it', () {
      expect(r('a//b.dart', 'app/main.dart'), 'app/a/b.dart');
      expect(r('src//../b.dart', 'app/main.dart'), 'app/src/b.dart');
      expect(r('../lib/src//d.dart', 'app/t/m.dart'), 'app/lib/src/d.dart');
    });

    test('refuses a directory, a leading slash and a fragment', () {
      for (final uri in ['a//', 'a//b.dart/', '/a/b.dart', '//a/b.dart']) {
        expect(r(uri, 'app/main.dart'), isNull);
      }
      expect(r('a//b.dart#x', 'app/main.dart'), isNull);
    });

    test('refuses an escape that decodes to a slash', () {
      expect(r('a%2Fb.dart', 'app/main.dart'), isNull);
    });
  });

  group('flutterSourceKey', () {
    String k(String p, List<String> r) => flutterSourceKey(p, r);
    late Directory savedCwd;

    setUp(() => savedCwd = Directory.current);
    tearDown(() => Directory.current = savedCwd.path);

    test('strips the working directory', () {
      final Directory work = Directory.systemTemp.createTempSync(
        'kernel_filter_key_',
      );
      addTearDown(() => work.deleteSync(recursive: true));
      Directory.current = work.path;
      expect(k('${work.path}/app/lib/main.dart', []), 'app/lib/main.dart');
    });

    test('strips the longest filesystem root', () {
      expect(
        k('out.stage/app/lib/main.dart', ['out.stage']),
        'app/lib/main.dart',
      );
      expect(k('a/b/c.dart', ['a', 'a/b']), 'c.dart');
    });

    test('strips the bazel-out bin prefix', () {
      expect(
        k('bazel-out/k8-fastbuild/bin/app/lib/main.dart', []),
        'app/lib/main.dart',
      );
    });

    test('a bare root without the slash is not a prefix', () {
      expect(k('ab/c.dart', ['a']), 'ab/c.dart');
    });

    test('dot roots never strip', () {
      expect(k('a/b.dart', ['.', '']), 'a/b.dart');
    });
  });

  group('stripFsRootPrefix', () {
    test('strips the longest root with the slash', () {
      expect(stripFsRootPrefix('a/b/c.dart', ['a']), 'b/c.dart');
      expect(stripFsRootPrefix('a/b/c.dart', ['a', 'a/b']), 'c.dart');
    });

    test('keeps paths under no root', () {
      expect(stripFsRootPrefix('ab/c.dart', ['a']), 'ab/c.dart');
      expect(stripFsRootPrefix('a/b.dart', ['.', '']), 'a/b.dart');
    });

    test('strips leading dot-slash and trailing root slashes', () {
      expect(stripFsRootPrefix('./a/b.dart', []), 'a/b.dart');
      expect(stripFsRootPrefix('a/b.dart', ['a/']), 'b.dart');
    });
  });
}
