// Each package's own build hook ran in its Bazel action, and the test's kernel
// finds every library by its asset id.
import 'package:native_add/native_add.dart';
import 'package:native_link/native_link.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('sqlite3 is the library its hook compiled from source', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final row = db.select('SELECT sqlite_version() AS v, 6 * 7 AS answer').single;
    expect(row['answer'], 42);
    expect(row['v'], sqlite3.version.libVersion);
    // The BCR amalgamation, not a system or downloaded library.
    expect(sqlite3.version.libVersion, '3.53.4');
  });

  test('a hand-written package compiles C in its hook', () {
    expect(add(2, 3), 5);
  });

  test('a package with a link hook works unlinked, as `dart test` runs it', () {
    expect(const Factor(6).times(7), 42);
  });
}
