import 'dart:io';

import 'package:test/test.dart';

// Run with `dart test` in this directory, or as `//sub:project_files_test`:
// both run the test in the package's directory, with the files under `test/`
// readable and the pubspec's language version.
void main() {
  test('runs in the package directory', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('dart_test_sub'));
  });

  test('reads a fixture by a package-relative path', () {
    final text = File('test/fixtures/greeting.txt').readAsStringSync();
    expect(text.trim(), 'hello from a fixture');
  });

  test('reads a fixture whose name has a space', () {
    final text = File('test/fixtures/two words.txt').readAsStringSync();
    expect(text.trim(), 'a name with a space');
  });

  test('compiles at the language version of its pubspec', () {
    const _ = 'a variable';
    // Before 3.7 `_` is a variable; from 3.7 on it cannot be read, so this
    // compiles only at the pubspec's language version.
    // ignore: no_wildcard_variable_uses
    expect(_, 'a variable');
  });
}
