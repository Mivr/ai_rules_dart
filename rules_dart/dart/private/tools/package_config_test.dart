// Tests the package-config generator beside `package_config.dart`: the JSON
// bytes a module compiles against must stay identical when generation moves
// from the Starlark string to the tool.

import 'dart:io';

import 'package:test/test.dart';

import 'package_config.dart'
    show
        buildPackageConfig,
        materializePackageConfig,
        parsePackageRecord,
        splitRecord,
        stablePath;

void main() {
  test('empty closure writes the empty config', () {
    expect(
      buildPackageConfig([], 'org-dartlang-root'),
      '{"configVersion": 2, "packages": []}\n',
    );
  });

  test('single package without language version', () {
    expect(
      buildPackageConfig([parsePackageRecord('a|pkg/a|')], 'org-dartlang-root'),
      '{\n'
      '  "configVersion": 2,\n'
      '  "packages": [\n'
      '    {"name": "a", "rootUri": "org-dartlang-root:///pkg/a", "packageUri": "lib/"}\n'
      '  ]\n'
      '}\n',
    );
  });

  test('language version is kept when the record states one', () {
    expect(
      buildPackageConfig([
        parsePackageRecord('a|pkg/a|3.9'),
      ], 'org-dartlang-root'),
      contains('"packageUri": "lib/", "languageVersion": "3.9"'),
    );
  });

  test('first record wins for a repeated package name', () {
    final String config = buildPackageConfig([
      parsePackageRecord('a|pkg/a|3.9'),
      parsePackageRecord('b|pkg/b|'),
      parsePackageRecord('a|other/a|'),
    ], 'org-dartlang-root');
    expect(config, contains('"rootUri": "org-dartlang-root:///pkg/a"'));
    expect(config, isNot(contains('other/a')));
  });

  test('custom scheme names every root', () {
    final String config = buildPackageConfig([
      parsePackageRecord('a|pkg/a|'),
    ], 'org-dartlang-app');
    expect(config, contains('"rootUri": "org-dartlang-app:///pkg/a"'));
  });

  test('external roots resolve under external', () {
    expect(stablePath('../repo/pkg'), 'external/repo/pkg');
    expect(stablePath('pkg/a'), 'pkg/a');
    expect(stablePath(''), '');
  });

  test('record fields split on pipes with empty defaults', () {
    expect(splitRecord('a|pkg/a|3.9'), ['a', 'pkg/a', '3.9']);
    expect(splitRecord('a|pkg/a'), ['a', 'pkg/a', '']);
    expect(splitRecord('a'), ['a', '', '']);
  });

  group('materializePackageConfig', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('pkg_cfg_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('writes the base bytes for a fixture closure and strips records', () {
      final out = '${dir.path}/m.package_config.json';
      final log = StringBuffer();
      final List<String>? rest = materializePackageConfig([
        '--target',
        'vm',
        '--packages-file',
        out,
        '--record',
        'top|dart/tests/top|3.9',
        '--record',
        'leaf|../ext+leaf/leaf|',
        '--record',
        'top|other/top|',
        '--multi-root-scheme',
        'org-dartlang-root',
      ], log);
      expect(rest, [
        '--target',
        'vm',
        '--packages-file',
        out,
        '--multi-root-scheme',
        'org-dartlang-root',
      ]);
      expect(
        File(out).readAsStringSync(),
        '{\n'
        '  "configVersion": 2,\n'
        '  "packages": [\n'
        '    {"name": "top", "rootUri": "org-dartlang-root:///dart/tests/top", '
        '"packageUri": "lib/", "languageVersion": "3.9"},\n'
        '    {"name": "leaf", '
        '"rootUri": "org-dartlang-root:///external/ext+leaf/leaf", '
        '"packageUri": "lib/"}\n'
        '  ]\n'
        '}\n',
      );
      expect(log.toString(), isEmpty);
    });

    test('leaves a request without records untouched', () {
      final args = ['--packages-file', '${dir.path}/never.json'];
      expect(materializePackageConfig(args, StringBuffer()), same(args));
      expect(File('${dir.path}/never.json').existsSync(), isFalse);
    });

    test('rejects records without the flags that place them', () {
      final log = StringBuffer();
      expect(materializePackageConfig(['--record', 'a|pkg/a|'], log), isNull);
      expect(log.toString(), contains('--record needs'));
    });
  });
}
