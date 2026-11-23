/// Unit tests for the e2e spec parse check.
library;

import 'dart:io';

import 'package:test/test.dart';

import '../specs.dart';

const _valid = '''
schema: mivr-e2e-spec/1
commands:
  - name: t
    run: bazel test //...
''';

Directory _tree(Map<String, String> specs) {
  final Directory root = Directory.systemTemp.createTempSync('e2e_specs_');
  addTearDown(() => root.deleteSync(recursive: true));
  specs.forEach((path, content) {
    File('${root.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  });
  return root;
}

void main() {
  test('accepts valid specs, including nested ones', () {
    final Directory root = _tree({
      'a/e2e.yaml': _valid,
      'b/c/e2e.yaml': _valid,
    });
    expect(findE2eSpecFiles(root), hasLength(2));
    expect(checkSpecs(root), isEmpty);
  });

  test('names a spec with an unknown key', () {
    final Directory root = _tree({
      'ok/e2e.yaml': _valid,
      'bad/e2e.yaml': '${_valid}bogus: 1\n',
    });
    final List<String> errors = checkSpecs(root);
    expect(errors, hasLength(1));
    expect(errors.single, contains('${root.path}/bad/e2e.yaml'));
    expect(errors.single, contains('bogus'));
  });

  test('names a spec with an empty commands list', () {
    final Directory root = _tree({
      'empty/e2e.yaml': 'schema: mivr-e2e-spec/1\ncommands: []\n',
    });
    final List<String> errors = checkSpecs(root);
    expect(errors.single, contains('${root.path}/empty/e2e.yaml'));
  });

  test('skips bazel-* directories and links', () {
    final Directory root = _tree({
      'a/e2e.yaml': _valid,
      'a/bazel-a/e2e.yaml': 'x: [',
    });
    expect(findE2eSpecFiles(root), hasLength(1));
  });
}
