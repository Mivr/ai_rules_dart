import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('reads a fixture by its package-relative path', () {
    expect(
      File('test/fixtures/greeting.txt').readAsStringSync().trim(),
      'hello from a fixture',
    );
  });
}
