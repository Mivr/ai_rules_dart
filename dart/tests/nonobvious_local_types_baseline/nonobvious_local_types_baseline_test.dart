import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const String _rule = 'specify_nonobvious_local_variable_types';

/// Guards `analysis_baseline.json` against the evicted
/// `specify_nonobvious_local_variable_types` rule: every non-obvious local
/// variable type is annotated in source, so no file may keep a ceiling for it,
/// and no file entry may be left as an empty `{}` map.
///
/// The baseline is a runfiles data file named by the `rlocationpath` argument.
void main(List<String> args) {
  late final Map<String, Object?> baseline;

  setUpAll(() {
    final String path = Runfiles.create().rlocation(args.first);
    final Object? decoded = jsonDecode(File(path).readAsStringSync());
    expect(decoded, isA<Map<String, Object?>>());
    baseline = decoded! as Map<String, Object?>;
  });

  test('the baseline parses and lists files', () {
    expect(baseline, isNotEmpty);
  });

  test('no file entry is an empty map', () {
    final List<String> empty = [
      for (final MapEntry<String, Object?> entry in baseline.entries)
        if (entry.value is Map<String, Object?> &&
            (entry.value! as Map<String, Object?>).isEmpty)
          entry.key,
    ];
    expect(empty, isEmpty, reason: 'empty per-file maps must be omitted');
  });

  test('no file entry keeps a $_rule ceiling', () {
    final List<String> offenders = [
      for (final MapEntry<String, Object?> entry in baseline.entries)
        if (entry.value is Map<String, Object?> &&
            (entry.value! as Map<String, Object?>).containsKey(_rule))
          entry.key,
    ];
    expect(offenders, isEmpty, reason: '$_rule is evicted from the baseline');
  });
}
