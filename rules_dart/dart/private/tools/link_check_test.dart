// Tests the `link_modules` check beside `link_check.dart`: which uses of
// `dart:mirrors` it reports with their line, which it leaves alone, and what
// the command line does.

import 'dart:io';

import 'package:test/test.dart';

import 'link_check.dart';

List<String> lines(String source, {String path = 'lib/a.dart'}) =>
    findMirrorsUses(path, source).map(hitLine).toList();

void main() {
  group('reported shapes', () {
    test('an import of dart:mirrors gives path:line', () {
      expect(lines("import 'dart:io';\nimport 'dart:mirrors';\n"), [
        'lib/a.dart:2: imports dart:mirrors',
      ]);
    });

    test('an export, a prefix and a double quote are reported', () {
      expect(lines('export "dart:mirrors";\nimport \'dart:mirrors\' as m;\n'), [
        'lib/a.dart:1: exports dart:mirrors',
        'lib/a.dart:2: imports dart:mirrors',
      ]);
    });

    test('dart.library.mirrors as a configuration key is reported', () {
      expect(
        lines(
          "import 'a.dart'\n"
          "    if (dart.library.io) 'io.dart'\n"
          "    if (dart.library.mirrors) 'mirrors.dart';\n",
        ),
        ['lib/a.dart:3: dart.library.mirrors is a configuration key'],
      );
    });

    test('a comparison in the configuration is still the key', () {
      expect(
        lines("export 'a.dart' if (dart.library.mirrors == 'true') 'b.dart';"),
        ['lib/a.dart:1: dart.library.mirrors is a configuration key'],
      );
    });

    test('bool.fromEnvironment naming the key is reported', () {
      expect(
        lines(
          'void main() {\n'
          "  const m = bool.fromEnvironment('dart.library.mirrors');\n"
          '}\n',
        ),
        ["lib/a.dart:2: bool.fromEnvironment('dart.library.mirrors')"],
      );
    });

    test('one file can report each shape in source order', () {
      expect(
        lines(
          "import 'dart:mirrors';\n"
          "import 'a.dart' if (dart.library.mirrors) 'b.dart';\n"
          'const x = bool.fromEnvironment("dart.library.mirrors");\n',
        ),
        [
          'lib/a.dart:1: imports dart:mirrors',
          'lib/a.dart:2: dart.library.mirrors is a configuration key',
          "lib/a.dart:3: bool.fromEnvironment('dart.library.mirrors')",
        ],
      );
    });
  });

  group('left alone', () {
    test('the other dart.library keys and dart.vm.product give none', () {
      expect(
        lines(
          "import 'dart:io';\n"
          "import 'dart:html';\n"
          "import 'dart:js_interop';\n"
          "import 'a.dart'\n"
          "    if (dart.library.io) 'io.dart'\n"
          "    if (dart.library.html) 'html.dart'\n"
          "    if (dart.library.js_interop) 'js.dart'\n"
          "    if (dart.library.ffi) 'ffi.dart';\n"
          "const p = bool.fromEnvironment('dart.vm.product');\n"
          "const i = bool.fromEnvironment('dart.library.io');\n",
        ),
        isEmpty,
      );
    });

    test('comments are skipped, nested block comments included', () {
      expect(
        lines(
          "// import 'dart:mirrors';\n"
          "/* import 'dart:mirrors';\n"
          "   /* nested */ if (dart.library.mirrors) 'x.dart'\n"
          '*/\n'
          "/// bool.fromEnvironment('dart.library.mirrors')\n"
          "import 'dart:io';\n",
        ),
        isEmpty,
      );
    });

    test('text inside a string is not a use', () {
      expect(
        lines(
          "const a = \"import 'dart:mirrors';\";\n"
          "const b = '''\nimport 'dart:mirrors';\n''';\n"
          "const c = r'if (dart.library.mirrors)';\n"
          "const d = '// \${'x' + \"import 'dart:mirrors'\"}';\n",
        ),
        isEmpty,
      );
    });

    test('a comment marker inside a string does not hide a later use', () {
      expect(lines("const u = 'http://x';\nimport 'dart:mirrors';\n"), [
        'lib/a.dart:2: imports dart:mirrors',
      ]);
    });

    test('a similar library name is not dart:mirrors', () {
      expect(
        lines("import 'dart:mirrors_extra';\nimport 'package:a/dart:mirrors';"),
        isEmpty,
      );
    });
  });

  group('command line', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('link_check'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('a clean closure writes the stamp', () {
      File('${dir.path}/ok.dart').writeAsStringSync("import 'dart:io';\n");
      final stamp = '${dir.path}/stamp';
      expect(
        run([
          '--label',
          '//a:b',
          '--src',
          '${dir.path}/ok.dart',
          '--output',
          stamp,
        ]),
        0,
      );
      expect(File(stamp).existsSync(), isTrue);
    });

    test('a source directory is expanded and a hit fails the run', () {
      Directory('${dir.path}/src').createSync();
      File('${dir.path}/src/bad.dart')
          .writeAsStringSync("\nimport 'dart:mirrors';\n");
      final stamp = '${dir.path}/stamp';
      expect(
        run([
          '--label',
          '//a:b',
          '--src',
          '${dir.path}/src',
          '--output',
          stamp,
        ]),
        1,
      );
      expect(File(stamp).existsSync(), isFalse);
    });

    test('the summary names the target and the way out', () {
      final String line = summaryLine('//a:b', 2);
      expect(line, contains('//a:b'));
      expect(line, contains('Unset link_modules'));
    });

    test('a missing value or flag is a usage error', () {
      expect(run(['--label']), 64);
      expect(run(['--bogus', 'x']), 64);
      expect(run(['--label', '//a:b']), 64);
    });
  });
}
