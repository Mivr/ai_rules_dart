import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main() {
  test('dart_sqlcodegen runs the preprocessing builder over a .drift file', () {
    final path = Runfiles.create().rlocation(
      '_main/drift/lib/schema_only.drift_prep.json',
    );
    final prep = jsonDecode(File(path).readAsStringSync());
    expect(prep, containsPair('declared_tables_and_views', ['notes']));
  });
}
