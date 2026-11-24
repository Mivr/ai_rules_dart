import 'package:smoke/greeting.dart';
import 'package:test/test.dart';

void main() {
  test('greet names the recipient', () {
    expect(greet('bazel'), 'hello, bazel');
  });

  test('smokeLine is the fixed line', () {
    expect(smokeLine, 'smoke: hello from rules_dart');
  });
}
