// Tests the strict-layering check beside `import_check.dart`: what a target
// may import, how a violation reads, and what the command line does.

import 'dart:io';

import 'package:test/test.dart';

import 'import_check.dart';

List<String> check(
  Map<String, String> sources, {
  Set<String> allowed = const {'own', 'mid'},
}) => checkImports((
  label: '//pkg:user',
  allowedPackages: allowed,
  sources: sources,
));

const _leafViolation =
    "//pkg:user: lib/a.dart imports 'package:leaf/leaf.dart', but package "
    "'leaf' is not a direct dependency of //pkg:user, only of something it "
    "depends on. Add the target that provides package 'leaf' to "
    "//pkg:user's deps.";

void main() {
  group('checkImports', () {
    test('a direct dep, the own package and dart: pass', () {
      expect(
        check({
          'lib/a.dart':
              "import 'dart:io';\n"
              "import 'package:mid/mid.dart';\n"
              "import 'package:own/own.dart';\n"
              "import 'b.dart';\n",
        }),
        isEmpty,
      );
    });

    test('a transitive-only package fails with the full line', () {
      expect(check({'lib/a.dart': "import 'package:leaf/leaf.dart';\n"}), [
        _leafViolation,
      ]);
    });

    test('a facade dep allows what the facade reaches', () {
      expect(
        check(
          {'lib/a.dart': "import 'package:leaf/leaf.dart';\n"},
          allowed: {'leaf', 'mid'},
        ),
        isEmpty,
      );
    });

    test('a merged multi-package target allows every member name', () {
      final sources = {
        'lib/a.dart':
            "import 'package:one/one.dart';\n"
            "import 'package:two/two.dart';\n",
      };
      expect(check(sources, allowed: {'one', 'two'}), isEmpty);
      expect(check(sources, allowed: {'one'}), hasLength(1));
    });

    test('an export is checked', () {
      expect(check({'lib/a.dart': "export 'package:leaf/leaf.dart';\n"}), [
        _leafViolation,
      ]);
    });

    test('both branches of a conditional import are checked', () {
      final List<String> lines = check({
        'lib/a.dart':
            "import 'package:mid/mid.dart'\n"
            "    if (dart.library.io) 'package:leaf/io.dart'\n"
            "    if (dart.library.html) 'package:web_leaf/web.dart';\n",
      });
      expect(lines, hasLength(2));
      expect(lines[0], contains("package 'leaf'"));
      expect(lines[1], contains("package 'web_leaf'"));
    });

    test('an unparsable source is refused', () {
      final List<String> lines = check({
        'lib/a.dart': "import 'package:mid/mid.dart'\n",
      });
      expect(lines, hasLength(1));
      expect(lines.single, contains('lib/a.dart'));
      expect(lines.single, contains('could not be checked'));
    });

    test('violations are ordered by path', () {
      final List<String> lines = check({
        'lib/z.dart': "import 'package:leaf/leaf.dart';\n",
        'lib/a.dart': "import 'package:leaf/leaf.dart';\n",
      });
      expect(lines[0], contains('lib/a.dart'));
      expect(lines[1], contains('lib/z.dart'));
    });
  });

  group('run', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('import_check'));
    tearDown(() => dir.deleteSync(recursive: true));

    String write(String name, String text) {
      final file = File('${dir.path}/$name')..createSync(recursive: true);
      file.writeAsStringSync(text);
      return file.path;
    }

    test('a directory --src is expanded and the stamp is written', () {
      write('src/lib/ok.dart', "import 'package:mid/mid.dart';\n");
      final out = '${dir.path}/out/stamp';
      final int code = run([
        '--label',
        '//pkg:user',
        '--direct-package',
        'mid',
        '--src',
        '${dir.path}/src',
        '--output',
        out,
      ]);
      expect(code, 0);
      expect(File(out).existsSync(), isTrue);
      expect(File(out).readAsStringSync(), isEmpty);
    });

    test('a violation under a directory --src fails and writes no stamp', () {
      write('src/lib/bad.dart', "import 'package:leaf/leaf.dart';\n");
      final out = '${dir.path}/stamp';
      final int code = run([
        '--label',
        '//pkg:user',
        '--own-package',
        'own',
        '--src',
        '${dir.path}/src',
        '--output',
        out,
      ]);
      expect(code, 1);
      expect(File(out).existsSync(), isFalse);
    });
  });
}
