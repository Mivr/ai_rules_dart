import 'package:copy_with/point.dart';
import 'package:test/test.dart';

void main() {
  test('shared_part_library generates a copyWith that keeps other fields', () {
    const origin = Point(x: 1, y: 2);
    final moved = origin.copyWith(x: 5);
    expect(moved.x, 5);
    expect(moved.y, 2);
    expect(origin.copyWith.y(9).x, 1);
  });
}
