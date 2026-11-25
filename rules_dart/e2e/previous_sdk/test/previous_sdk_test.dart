import 'dart:io';

import 'package:previous_sdk/previous_sdk.dart';
import 'package:test/test.dart';

void main() {
  test('runs on the SDK this workspace selects', () {
    expect(Platform.version, startsWith('3.13.5 '));
  });

  test('a locked package resolves', () {
    expect(joinAll(['a', 'b', 'c']), 'a/b/c');
  });
}
