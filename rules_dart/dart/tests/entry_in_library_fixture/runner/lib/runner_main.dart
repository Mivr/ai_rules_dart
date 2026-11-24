// A test `main` that sits in a library: the `package:test` bootstrap imports
// it by the library's `package:` URI.
import 'package:test/test.dart';

void main() {
  test('runs from the library', () {
    expect(
      StackTrace.current.toString(),
      contains('package:entry_in_library_runner/runner_main.dart'),
    );
  });
}
