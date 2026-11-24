// The three packages' code assets, loaded by a `flutter_test`.
import 'package:flutter_test/flutter_test.dart';
import 'package:native_add/native_add.dart';
import 'package:native_link/native_link.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('sqlite3 is the amalgamation Bazel provides', () {
    expect(sqlite3.version.libVersion, '3.53.4');
  });

  test('native_add adds in C', () {
    expect(add(2, 3), 5);
  });

  test('native_link multiplies in C', () {
    expect(const Factor(6).times(7), 42);
  });
}
