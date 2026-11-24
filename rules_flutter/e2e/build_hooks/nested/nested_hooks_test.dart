// A hook's code asset, loaded by a `flutter_test` that runs in its own
// package's directory.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_add/native_add.dart';

void main() {
  test('the test runs in its package directory', () {
    expect(Directory.current.path, endsWith('/nested'));
  });

  test('native_add adds in C', () {
    expect(add(2, 3), 5);
  });
}
