import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main(List<String> args) {
  final r = Runfiles.create();
  final codegenOut = File(r.rlocation(args[0])).readAsStringSync();
  final aggOut = File(r.rlocation(args[1])).readAsStringSync();
  final sqlOut = File(r.rlocation(args[2])).readAsStringSync();

  const expected =
      '// pubspec=name: codegen_fixture|version: 4.5.6|'
      'environment:|  sdk: ^3.0.0\n'
      '// options=# custom analysis_options from bazel-out\n';

  test('dart_codegen, dart_aggregate_codegen, and dart_sqlcodegen preserve '
      'read-only staged pubspec.yaml and analysis_options.yaml', () {
    expect(codegenOut, expected);
    expect(aggOut, expected);
    expect(sqlOut, expected);
  });
}
