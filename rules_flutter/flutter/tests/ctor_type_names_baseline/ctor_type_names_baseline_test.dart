/// Guards the `unnecessary_type_name_in_constructor` burn-down.
///
/// The rule is enforced workspace-wide, so `analysis_baseline.json` must carry
/// no ceiling for it, and no file may be left with an empty diagnostic map.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const _rule = 'unnecessary_type_name_in_constructor';

Map<String, Object?> _loadBaseline() {
  const key = 'ANALYSIS_BASELINE_RLOCATION';
  final String? rlocation = Platform.environment[key];
  if (rlocation == null) {
    throw StateError('$key is not set; the test needs the baseline in `data`');
  }
  final file = File(Runfiles.create().rlocation(rlocation));
  return json.decode(file.readAsStringSync()) as Map<String, Object?>;
}

void main() {
  final Map<String, Object?> baseline = _loadBaseline();

  test('no file entry is an empty map', () {
    final List<String> empty = [
      for (final MapEntry(:key, :value) in baseline.entries)
        if (value is Map<String, Object?> && value.isEmpty) key,
    ];
    expect(empty, isEmpty);
  });

  test('no file entry baselines $_rule', () {
    final List<String> offenders = [
      for (final MapEntry(:key, :value) in baseline.entries)
        if (value is Map<String, Object?> && value.containsKey(_rule)) key,
    ];
    expect(offenders, isEmpty);
  });
}
