// A test of a stock layout: it imports the program's `main` library through
// the library that lists all of `lib/`, as `flutter create`'s test imports
// `package:<app>/main.dart`.
import 'package:entry_in_library_fixture/main.dart' as app;
import 'package:entry_in_library_fixture/src/greeting.dart';
import 'package:test/test.dart';

void main() {
  test('the library holds main and what it uses', () {
    expect(greeting('x'), 'hello from x');
    expect(app.main, isA<void Function()>());
  });
}
