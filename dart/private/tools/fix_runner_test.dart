import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../guard/lib/directive_guard.dart';
import 'fix_runner.dart' as fix_runner;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fix_runner_test_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('repointPackageConfig emits only relative rootUris for sibling and nested scratch dirs', () {
    final project = Directory('${tmp.path}/pkg/demo.proj')
      ..createSync(recursive: true);
    final extPkg = Directory('${tmp.path}/pkg/demo.extpkgs/foo')
      ..createSync(recursive: true);
    final repoPkg = Directory('${tmp.path}/external/rules_dart++pub+bar')
      ..createSync(recursive: true);
    Directory('${project.path}/pkgs/sub').createSync(recursive: true);

    const initialConfig = {
      'configVersion': 2,
      'packages': [
        {'name': 'demo', 'rootUri': '..', 'packageUri': 'lib/'},
        {'name': 'sub', 'rootUri': '../pkgs/sub', 'packageUri': 'lib/'},
        {
          'name': 'foo',
          'rootUri': '../../demo.extpkgs/foo',
          'packageUri': 'lib/',
        },
        {
          'name': 'bar',
          'rootUri': '../../../external/rules_dart++pub+bar',
          'packageUri': 'lib/',
        },
      ],
    };

    for (final scratchRel in ['pkg/demo.scratch', 'deep/nested/scratch']) {
      final scratch = Directory('${tmp.path}/$scratchRel');
      final configFile = File('${scratch.path}/.dart_tool/package_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(initialConfig)}\n',
        );

      fix_runner.repointPackageConfig(project.path, scratch.path);

      final raw = configFile.readAsStringSync();
      expect(raw, isNot(contains('file:')));
      expect(raw, isNot(contains(tmp.path)));

      final decoded = jsonDecode(raw) as Map<String, Object?>;
      final packages = {
        for (final p in (decoded['packages'] as List).cast<Map>())
          p['name'] as String: p['rootUri'] as String,
      };

      for (final uri in packages.values) {
        expect(Uri.parse(uri).hasScheme, isFalse);
        expect(uri.startsWith('/'), isFalse);
      }

      expect(packages['demo'], '..');
      expect(packages['sub'], '../pkgs/sub');

      final scratchConfigDir = Uri.directory(
        Directory('${scratch.path}/.dart_tool').absolute.path,
      );
      expect(
        scratchConfigDir.resolveUri(Uri.parse('${packages['foo']}/')),
        Uri.directory(extPkg.absolute.path),
      );
      expect(
        scratchConfigDir.resolveUri(Uri.parse('${packages['bar']}/')),
        Uri.directory(repoPkg.absolute.path),
      );
    }
  });

  test('repointPackageConfig handles Windows backslash relative paths and drive-letter rootUris', () {
    final project = Directory('${tmp.path}/pkg/demo.proj')
      ..createSync(recursive: true);
    final scratch = Directory('${tmp.path}/deep/nested/scratch')
      ..createSync(recursive: true);
    final configFile = File('${scratch.path}/.dart_tool/package_config.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert({
          'configVersion': 2,
          'packages': [
            {'name': 'sub_backslash', 'rootUri': r'..\pkgs\sub', 'packageUri': 'lib/'},
            {'name': 'ext_backslash', 'rootUri': r'..\..\demo.extpkgs\foo', 'packageUri': 'lib/'},
            {'name': 'win_drive_slash', 'rootUri': 'd:/_bazel/external/rules_dart++pub+bar', 'packageUri': 'lib/'},
            {'name': 'win_drive_backslash', 'rootUri': r'C:\Users\runneradmin\_bazel\external\baz', 'packageUri': 'lib/'},
          ],
        })}\n',
      );

    fix_runner.repointPackageConfig(project.path, scratch.path);

    final decoded =
        jsonDecode(configFile.readAsStringSync()) as Map<String, Object?>;
    final packages = {
      for (final p in (decoded['packages'] as List).cast<Map>())
        p['name'] as String: p['rootUri'] as String,
    };

    expect(packages['sub_backslash'], '../pkgs/sub');
    expect(packages['ext_backslash'], '../../../../pkg/demo.extpkgs/foo');
    expect(
      packages['win_drive_slash'],
      isNot(equals('d:/_bazel/external/rules_dart++pub+bar')),
    );
    expect(packages['win_drive_slash'], isNot(contains(r'\')));
    expect(packages['win_drive_backslash'], isNot(contains(r'\')));
  });

  test('staged sources with a file: directive are refused before fixing', () {
    final project = Directory('${tmp.path}/demo.proj')
      ..createSync(recursive: true);
    Directory('${project.path}/src/pkg').createSync(recursive: true);
    final main = File('${project.path}/src/pkg/main.dart')
      ..writeAsStringSync(
        "import 'file://localhost/secret.dart';\n"
        'void main() => print(secretValue);\n',
      );
    File('${project.path}/src/pkg/ok.dart')
        .writeAsStringSync('const ok = 1;\n');
    final violations = findDisallowedStagedDirectives([
      project.path,
    ], tool: 'fix_runner');
    // Staged-source keys use `/` separators on every platform; the listing
    // spells them with `\` on Windows.
    final mainDisplay = main.path.replaceAll(r'\', '/');
    expect(violations, [
      "fix_runner: $mainDisplay import 'file://localhost/secret.dart' "
          'is not a declared input.',
    ]);
  });

  test(
    'staged sources behind symlinks are scanned',
    skip: Platform.isWindows
        ? 'creating symlinks needs Developer Mode or elevation'
        : false,
    () {
      final project = Directory('${tmp.path}/demo.proj')
        ..createSync(recursive: true);
      Directory('${project.path}/src/pkg').createSync(recursive: true);
      Directory('${tmp.path}/real').createSync(recursive: true);
      File('${tmp.path}/real/evil.dart').writeAsStringSync(
        "import 'file:///proc/self/cwd/pkg/lib/secret.dart';\n"
        'const evil = 1;\n',
      );
      File('${tmp.path}/real/ok.dart').writeAsStringSync('const ok = 1;\n');
      Link('${project.path}/src/pkg/evil.dart')
          .createSync('${tmp.path}/real/evil.dart');
      Link('${project.path}/src/pkg/ok.dart')
          .createSync('${tmp.path}/real/ok.dart');
      final violations = findDisallowedStagedDirectives([
        project.path,
      ], tool: 'fix_runner');
      expect(violations, [
        "fix_runner: ${project.path.replaceAll(r'\', '/')}/src/pkg/evil.dart "
            "import 'file:///proc/self/cwd/pkg/lib/secret.dart' "
            'is not a declared input.',
      ]);
    },
  );

  test('staged sources with a triple-quoted directive are refused', () {
    // A multi-line first line the guard keeps but the front end drops reads
    // an undeclared host file through the fix action's working directory.
    final project = Directory('${tmp.path}/demo.proj')
      ..createSync(recursive: true);
    Directory('${project.path}/src/pkg').createSync(recursive: true);
    final main = File('${project.path}/src/pkg/main.dart')
      ..writeAsStringSync(
        "import '''   \n/secret/s.dart''';\n"
        'void main() => print(secretValue);\n',
      );
    File('${project.path}/src/pkg/ok.dart')
        .writeAsStringSync('const ok = 1;\n');
    final violations = findDisallowedStagedDirectives([
      project.path,
    ], tool: 'fix_runner');
    final mainDisplay = main.path.replaceAll(r'\', '/');
    expect(violations, [
      "fix_runner: $mainDisplay import '   \n/secret/s.dart' "
          'is not a declared input.',
    ]);
  });

  group('pruneOrphanedStagedFiles', () {
    Directory stageSrc(String name) {
      final project = Directory('${tmp.path}/$name.proj')
        ..createSync(recursive: true);
      Directory('${project.path}/src/pkg').createSync(recursive: true);
      return project;
    }

    void writeSrcManifest(Directory project, List<String> lines) {
      Directory('${project.path}/.dart_tool').createSync(recursive: true);
      File('${project.path}/.dart_tool/src_manifest.txt')
          .writeAsStringSync("${lines.join('\n')}\n");
    }

    test('keys the allow-list project-relative and deletes unlisted files', () {
      final project = stageSrc('demo');
      File('${project.path}/src/pkg/keep.dart')
          .writeAsStringSync('const keep = 1;\n');
      File('${project.path}/src/pkg/drop.dart')
          .writeAsStringSync('const drop = 1;\n');
      writeSrcManifest(project, ['pkg/keep.dart']);

      final allowed = fix_runner.pruneOrphanedStagedFiles(project.path);

      expect(allowed, {'src/pkg/keep.dart'});
      expect(File('${project.path}/src/pkg/keep.dart').existsSync(), isTrue);
      expect(File('${project.path}/src/pkg/drop.dart').existsSync(), isFalse);
    });

    test('a dot-slashed manifest line matches nothing project-relative', () {
      final project = stageSrc('dotslash');
      File('${project.path}/src/pkg/keep.dart')
          .writeAsStringSync('const keep = 1;\n');
      writeSrcManifest(project, ['./pkg/keep.dart']);

      final allowed = fix_runner.pruneOrphanedStagedFiles(project.path);

      expect(allowed, {'src/./pkg/keep.dart'});
      expect(File('${project.path}/src/pkg/keep.dart').existsSync(), isFalse);
    });

    test('a star manifest keeps everything and reports no allow-list', () {
      final project = stageSrc('star');
      File('${project.path}/src/pkg/any.dart')
          .writeAsStringSync('const any = 1;\n');
      writeSrcManifest(project, ['*']);

      expect(fix_runner.pruneOrphanedStagedFiles(project.path), isNull);
      expect(File('${project.path}/src/pkg/any.dart').existsSync(), isTrue);
    });

    test('without a manifest nothing is pruned', () {
      final project = stageSrc('bare');
      File('${project.path}/src/pkg/any.dart')
          .writeAsStringSync('const any = 1;\n');

      expect(fix_runner.pruneOrphanedStagedFiles(project.path), isNull);
      expect(File('${project.path}/src/pkg/any.dart').existsSync(), isTrue);
    });

    test('prunes sibling extpkgs entries the manifest does not list', () {
      final project = stageSrc('ext');
      writeSrcManifest(project, ['*']);
      final ext = Directory('${tmp.path}/ext.extpkgs/foo')
        ..createSync(recursive: true);
      File('${ext.path}/keep.dart').writeAsStringSync('const keep = 1;\n');
      File('${ext.path}/drop.dart').writeAsStringSync('const drop = 1;\n');
      File('${project.path}/.dart_tool/extpkgs_manifest.txt')
          .writeAsStringSync('foo/keep.dart\n');

      fix_runner.pruneOrphanedStagedFiles(project.path);

      expect(File('${ext.path}/keep.dart').existsSync(), isTrue);
      expect(File('${ext.path}/drop.dart').existsSync(), isFalse);
    });

    test('an extpkgs directory prefix keeps the whole listed tree', () {
      final project = stageSrc('extdir');
      writeSrcManifest(project, ['*']);
      final ext = Directory('${tmp.path}/extdir.extpkgs/tree')
        ..createSync(recursive: true);
      File('${ext.path}/nested.dart').writeAsStringSync('const n = 1;\n');
      File('${project.path}/.dart_tool/extpkgs_manifest.txt')
          .writeAsStringSync('tree/\n');

      fix_runner.pruneOrphanedStagedFiles(project.path);

      expect(File('${ext.path}/nested.dart').existsSync(), isTrue);
    });
  });
}
