/// Guards `analysis_baseline.json` against `always_use_package_imports`.
///
/// The rule was burned down to zero, so no file may carry a ceiling for it,
/// and no file may keep an empty diagnostic map.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// The per-file diagnostic maps of the baseline, keyed by file path.
Map<String, Map<String, Object?>> _loadBaseline() {
  final String? rlocation = Platform.environment['ANALYSIS_BASELINE_RLOCATION'];
  if (rlocation == null || rlocation.isEmpty) {
    throw StateError('ANALYSIS_BASELINE_RLOCATION is not set');
  }
  final String text = File(Runfiles.create().rlocation(rlocation))
      .readAsStringSync();
  final root = jsonDecode(text) as Map<String, Object?>;
  return {
    for (final MapEntry<String, Object?> entry in root.entries)
      entry.key: entry.value! as Map<String, Object?>,
  };
}

void main() {
  final Map<String, Map<String, Object?>> baseline = _loadBaseline();

  test('no file entry is an empty map', () {
    final List<String> empty = [
      for (final MapEntry<String, Map<String, Object?>> entry
          in baseline.entries)
        if (entry.value.isEmpty) entry.key,
    ];
    expect(empty, isEmpty);
  });

  test('no file entry holds always_use_package_imports', () {
    final List<String> offenders = [
      for (final MapEntry<String, Map<String, Object?>> entry
          in baseline.entries)
        if (entry.value.containsKey('always_use_package_imports')) entry.key,
    ];
    expect(offenders, isEmpty);
  });
}
