// Tagged `runfiles`: this test imports `package:runfiles` to read
// `analysis_baseline.json` through the `ANALYSIS_BASELINE` runfiles path, so a
// bare `dart test` fails to load it rather than failing a test.
@Tags(['runfiles'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const String _rule = 'specify_nonobvious_local_variable_types';

Map<String, Map<String, Object?>> _readBaseline() {
  final String? rlocation = Platform.environment['ANALYSIS_BASELINE'];
  if (rlocation == null || rlocation.isEmpty) {
    fail('ANALYSIS_BASELINE is not set; run this through `bazel test`.');
  }
  final String text = File(
    Runfiles.create().rlocation(rlocation),
  ).readAsStringSync();
  return (jsonDecode(text) as Map<String, dynamic>)
      .cast<String, Map<String, Object?>>();
}

void main() {
  final Map<String, Map<String, Object?>> baseline = _readBaseline();

  test('no file entry maps to an empty object', () {
    final empty = <String>[
      for (final MapEntry<String, Map<String, Object?>> entry
          in baseline.entries)
        if (entry.value.isEmpty) entry.key,
    ];
    expect(empty, isEmpty);
  });

  test('$_rule is evicted from the baseline', () {
    final files = <String>[
      for (final MapEntry<String, Map<String, Object?>> entry
          in baseline.entries)
        if (entry.value.containsKey(_rule)) entry.key,
    ];
    expect(files, isEmpty);
  });
}
