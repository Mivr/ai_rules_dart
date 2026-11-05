import 'package:coverage_fixture/coverage_fixture.dart';

/// Exercises only the positive path of `sign`, so its `n < 0` arm and
/// `neverCalledFixtureFunction` stay uncovered in the report.
void main() {
  _expect(sign(5), 1, 'sign(5)');
  _expect(sign(0), 0, 'sign(0)');
}

void _expect(int actual, int expected, String what) {
  if (actual != expected) {
    throw StateError('$what: expected $expected, got $actual');
  }
}
