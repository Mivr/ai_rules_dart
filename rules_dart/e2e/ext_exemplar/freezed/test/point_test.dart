import 'package:freezed_fixture/point.dart';
import 'package:test/test.dart';

void main() {
  test('library_builder_library generates equality and copyWith', () {
    const origin = Point(x: 1, y: 2);
    expect(origin, const Point(x: 1, y: 2));
    expect(origin.copyWith(y: 7), const Point(x: 1, y: 7));
    expect(origin.toString(), contains('x: 1'));
  });
}
