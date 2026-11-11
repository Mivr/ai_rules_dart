// Tests the strict-layering check beside `import_check.dart`: what a target
// may import, how a violation reads, and what the command line does.

import 'dart:io';

import 'package:test/test.dart';

import 'import_check.dart';

List<String> check(
  Map<String, String> sources, {
  Set<String> allowed = const {'own', 'mid'},
}) {
  final ImportCheckRequest request = (
    label: '//pkg:user',
    allowedPackages: allowed,
    sources: sources,
  );
  return checkDirectives(request, const {});
}

const _leafViolation =
    "//pkg:user: lib/a.dart imports 'package:leaf/leaf.dart', but package "
    "'leaf' is not a direct dependency of //pkg:user, only of something it "
    "depends on. Add the target that provides package 'leaf' to "
    "//pkg:user's deps.";

String _refusedLine(String verb, String noun) =>
    "//pkg:user: lib/a.dart $verb 'dart:mirrors', which "
    '//dart:refused_dart_libraries refuses. Remove the $noun, or '
    'take the library out of that setting.';

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

    test('PACKAGE: and escaped package names are judged like package:', () {
      for (final uri in [
        'PACKAGE:leaf/leaf.dart',
        'Package:le%61f/leaf.dart',
      ]) {
        expect(check({'lib/a.dart': "import '$uri';\n"}), [
          _leafViolation.replaceFirst('package:leaf/leaf.dart', uri),
        ]);
      }
      expect(check({'lib/a.dart': "import 'PACKAGE:mid/x.dart';\n"}), isEmpty);
      for (final uri in ['package:m%69d/x.dart', 'Package:%6did/x.dart']) {
        expect(check({'lib/a.dart': "export '$uri';\n"}), isEmpty, reason: uri);
      }
    });

    test('an undecodable URI fails the layering check too', () {
      expect(
        check({'lib/a.dart': "import 'package:le%/x.dart';\n"}),
        contains(
          undecodableLine('//pkg:user', 'lib/a.dart', 'package:le%/x.dart'),
        ),
      );
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

  group('checkDirectives', () {
    List<String> refuse(Map<String, String> sources, Set<String> refused) =>
        checkDirectives((
          label: '//pkg:user',
          allowedPackages: const {'mirrors'},
          sources: sources,
        ), refused);

    const mirrors = {'dart:mirrors'};

    test('a refused import names the label, file, URI and setting', () {
      expect(refuse({'lib/a.dart': "import 'dart:mirrors';\n"}, mirrors), [
        _refusedLine('imports', 'import'),
      ]);
    });

    test('a refused export says exports', () {
      expect(refuse({'lib/a.dart': "export 'dart:mirrors';\n"}, mirrors), [
        _refusedLine('exports', 'export'),
      ]);
    });

    test('a refused library that is repeated is printed once', () {
      expect(
        refuse({
          'lib/a.dart': "import 'dart:mirrors';\nimport 'dart:mirrors';\n",
        }, mirrors),
        hasLength(1),
      );
    });

    test('other dart: libraries and packages pass', () {
      expect(
        refuse({
          'lib/a.dart':
              "import 'dart:io';\nimport 'dart:math';\n"
              "import 'package:mirrors/mirrors.dart';\n",
        }, mirrors),
        isEmpty,
      );
    });

    for (final spelling in [
      'Dart:mirrors',
      'DART:mirrors',
      'dart:%6Dirrors',
      'dart:mirror%73',
      'Dart:%6d%69rrors',
    ]) {
      for (final verb in ['import', 'export']) {
        test('$verb of $spelling is refused, printed as written', () {
          expect(refuse({'lib/a.dart': "$verb '$spelling';\n"}, mirrors), [
            _refusedLine(
              '${verb}s',
              verb,
            ).replaceFirst('dart:mirrors', spelling),
          ]);
        });
      }
    }

    test('quoting forms and other libraries behave as before', () {
      expect(
        refuse({
          'lib/a.dart':
              "import r'dart:mirrors';\nimport 'dart:io' show File;\n"
              "import 'dart:math' if (dart.library.io) 'dart:convert';\n"
              "import 'dart:\\x6dirrors' as m;\n",
        }, mirrors),
        hasLength(1),
      );
    });

    test('an undecodable URI is refused with its target, file and URI', () {
      for (final bad in ['dart:mirror%', 'a%ff.dart', 'dart:%zz']) {
        expect(refuse({'lib/a.dart': "import '$bad';\n"}, mirrors), [
          undecodableLine('//pkg:user', 'lib/a.dart', bad),
        ]);
      }
    });

    test('an empty refused set reports nothing', () {
      expect(
        refuse({'lib/a.dart': "import 'dart:mirrors';\n"}, const {}),
        isEmpty,
      );
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

    test('a refused import fails the check and writes no stamp', () {
      write('src/lib/bad.dart', "import 'dart:mirrors';\n");
      final out = '${dir.path}/stamp';
      final int code = run([
        '--label',
        '//pkg:user',
        '--refused-library',
        'dart:mirrors',
        '--src',
        '${dir.path}/src',
        '--output',
        out,
      ]);
      expect(code, 1);
      expect(File(out).existsSync(), isFalse);
    });

    test('the same import passes when nothing is refused', () {
      write('src/lib/ok.dart', "import 'dart:mirrors';\n");
      final int code = run([
        '--label',
        '//pkg:user',
        '--src',
        '${dir.path}/src',
        '--output',
        '${dir.path}/stamp',
      ]);
      expect(code, 0);
    });

    for (final bad in ['mirrors', 'dart:', 'dart:Mirrors', 'package:a']) {
      test('--refused-library "$bad" is a usage error', () {
        final int code = run([
          '--label',
          '//pkg:user',
          '--refused-library',
          bad,
          '--output',
          '${dir.path}/stamp',
        ]);
        expect(code, 64);
      });
    }

    test('--refused-library with no value is a usage error', () {
      expect(run(['--label', '//pkg:user', '--refused-library']), 64);
    });
  });
}
