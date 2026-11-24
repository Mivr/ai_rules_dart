import 'package:test/test.dart';

void main() {
  test('smoke case', () {
    expect(1 + 1, equals(2));
  }, tags: ['smoke']);

  test('broken case', () {
    fail('broken case should have been excluded');
  }, tags: ['broken']);

  test('flaky ios case', () {
    fail('flaky ios case should have been excluded');
  }, tags: ['ios', 'flaky']);
}
