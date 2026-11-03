// Tests the package-config generator beside `package_config.dart`: the JSON
// bytes a module compiles against must stay identical when generation moves
// from the Starlark string to the tool.

import 'package:test/test.dart';

import 'package_config.dart'
    show buildPackageConfig, parsePackageRecord, splitRecord, stablePath;

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
}
