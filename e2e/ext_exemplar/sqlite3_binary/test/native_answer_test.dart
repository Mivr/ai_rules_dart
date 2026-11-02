import 'package:native_answer/native_answer.dart';
import 'package:test/test.dart';

void main() {
  test('dart_code_asset binds the Bazel-built native_answer library', () {
    expect(nativeAnswer(), 42);
  });
}
