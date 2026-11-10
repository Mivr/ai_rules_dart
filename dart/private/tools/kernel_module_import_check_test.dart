// Tests the strict-layering check inlined into kernel_module.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'kernel_module.dart';
import 'kernel_module_import_check.dart';
import 'kernel_module_test_support.dart';

class _FakeCompiler implements ModuleCompiler {
  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    final int outIdx = args.indexOf('--output');
    if (outIdx >= 0 && outIdx + 1 < args.length) {
      final outDir = Directory(args[outIdx + 1])..createSync(recursive: true);
      File('${outDir.path}/0.dill').writeAsBytesSync(buildMinimalFieldDill());
      File('${outDir.path}/index.json').writeAsStringSync('{"components":[]}');
    }
    return const ModuleOutcome(0, '');
  }

  @override
  Future<void> close() async {}
}

void main() {
  group('checkImports unit', () {
    test('a transitive-only package produces the violationLine', () {
      final List<String> lines = checkImports((
        label: '//pkg/user:user',
        allowedPackages: {'user', 'mid'},
        sources: {
          'pkg/user/lib/user.dart': "import 'package:leaf/leaf.dart';\n",
        },
      ));
      expect(lines, [
        violationLine(
          '//pkg/user:user',
          'pkg/user/lib/user.dart',
          'package:leaf/leaf.dart',
          'leaf',
        ),
      ]);
    });

    test('direct dependencies, own package and dart: imports pass', () {
      final List<String> lines = checkImports((
        label: '//pkg/user:user',
        allowedPackages: {'user', 'mid'},
        sources: {
          'pkg/user/lib/user.dart':
              "import 'dart:io';\n"
              "import 'package:user/src/part.dart';\n"
              "import 'package:mid/mid.dart';\n",
        },
      ));
      expect(lines, isEmpty);
    });
  });

  group('compileModule inlining', () {
    late Directory tempDir;
    late String packagesFile;
    late String libJson;
    late String outDir;
    late String excluded;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('km_import_check_test');
      packagesFile = '${tempDir.path}/.dart_tool/package_config.json';
      File(packagesFile)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {
                'name': 'user',
                'rootUri': 'org-dartlang-root:///pkg/user',
                'packageUri': 'lib/',
              },
              {
                'name': 'mid',
                'rootUri': 'org-dartlang-root:///pkg/mid',
                'packageUri': 'lib/',
              },
              {
                'name': 'leaf',
                'rootUri': 'org-dartlang-root:///pkg/leaf',
                'packageUri': 'lib/',
              },
            ],
          }),
        );
      libJson = '${tempDir.path}/libraries.json';
      File(libJson)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'vm': {'libraries': <String, dynamic>{}},
          }),
        );
      outDir = '${tempDir.path}/out';
      excluded = '${tempDir.path}/excluded.txt';
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    void writeSource(String relativePath, String content) {
      final file = File('${tempDir.path}/$relativePath')
        ..createSync(recursive: true);
      file.writeAsStringSync(content);
    }

    test('disallowed import fails with identical violation message under --check-imports', () async {
      writeSource(
        'pkg/user/lib/user.dart',
        "import 'package:leaf/leaf.dart';\nclass User {}\n",
      );
      final log = StringBuffer();
      final int code = await compileModule(
        [
          '--check-imports',
          '--target-label',
          '//pkg/user:user',
          '--own-package',
          'user',
          '--direct-package',
          'mid',
          '--packages-file',
          packagesFile,
          '--multi-root',
          tempDir.path,
          '--multi-root-scheme',
          'org-dartlang-root',
          '--libraries-json',
          libJson,
          '--output',
          outDir,
          '--excluded-output',
          excluded,
          '--source',
          'package:user/user.dart',
        ],
        _FakeCompiler(),
        log,
        const [],
      );
      expect(code, 1);
      final String expected = violationLine(
        '//pkg/user:user',
        'pkg/user/lib/user.dart',
        'package:leaf/leaf.dart',
        'leaf',
      );
      expect(log.toString(), contains(expected));
    });

    test('-dart_layering_check (no --check-imports) disables the check and succeeds', () async {
      writeSource(
        'pkg/user/lib/user.dart',
        "import 'package:leaf/leaf.dart';\nclass User {}\n",
      );
      final log = StringBuffer();
      final int code = await compileModule(
        [
          // Note: --check-imports omitted, as when -dart_layering_check is set
          '--target-label',
          '//pkg/user:user',
          '--own-package',
          'user',
          '--direct-package',
          'mid',
          '--packages-file',
          packagesFile,
          '--multi-root',
          tempDir.path,
          '--multi-root-scheme',
          'org-dartlang-root',
          '--libraries-json',
          libJson,
          '--output',
          outDir,
          '--excluded-output',
          excluded,
          '--source',
          'package:user/user.dart',
        ],
        _FakeCompiler(),
        log,
        const [],
      );
      expect(code, 0);
      expect(log.toString(), isNot(contains('is not a direct dependency')));
    });

    test('clean imports succeed under --check-imports', () async {
      writeSource(
        'pkg/user/lib/user.dart',
        "import 'package:mid/mid.dart';\nclass User {}\n",
      );
      final log = StringBuffer();
      final int code = await compileModule(
        [
          '--check-imports',
          '--target-label',
          '//pkg/user:user',
          '--own-package',
          'user',
          '--direct-package',
          'mid',
          '--packages-file',
          packagesFile,
          '--multi-root',
          tempDir.path,
          '--multi-root-scheme',
          'org-dartlang-root',
          '--libraries-json',
          libJson,
          '--output',
          outDir,
          '--excluded-output',
          excluded,
          '--source',
          'package:user/user.dart',
        ],
        _FakeCompiler(),
        log,
        const [],
      );
      expect(code, 0);
      expect(log.toString(), isEmpty);
    });
  });
}
