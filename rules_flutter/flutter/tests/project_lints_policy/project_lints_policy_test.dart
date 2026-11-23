/// Guards the wave-1 project lints.
///
/// Root `analysis_options.yaml` enables the four rules the summary worker
/// registers, and `analysis_baseline.json` stays a clean ceiling file: sorted
/// keys, positive counts, no empty file maps, and no ceiling for a rule with
/// no violations.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _wave1Rules = [
  'no_home_env_reads',
  'no_stdout_in_worker',
  'no_wall_clock_in_actions',
  'process_requires_environment',
];

/// A rule with no violations in production code, so it has no ceiling.
const _cleanRule = 'no_stdout_in_worker';

String _read(String key) {
  final String? rlocation = Platform.environment[key];
  if (rlocation == null) {
    throw StateError('$key is not set; the test needs the file in `data`');
  }
  return File(Runfiles.create().rlocation(rlocation)).readAsStringSync();
}

Map<String, Object?> _asMap(Object? value, String what) {
  if (value is Map<String, Object?>) {
    return value;
  }
  throw StateError('$what is not a JSON object');
}

bool _isSorted(Iterable<String> keys) {
  final List<String> list = keys.toList();
  for (var i = 1; i < list.length; i++) {
    if (list[i - 1].compareTo(list[i]) >= 0) {
      return false;
    }
  }
  return true;
}

void main() {
  final baseline =
      json.decode(_read('ANALYSIS_BASELINE_RLOCATION')) as Map<String, Object?>;
  final yaml = loadYaml(_read('ANALYSIS_OPTIONS_RLOCATION')) as YamlMap;
  final rules = (yaml['linter'] as YamlMap)['rules'] as YamlMap;

  group('analysis_options.yaml', () {
    for (final String rule in _wave1Rules) {
      test('enables $rule', () {
        expect(rules[rule], isTrue);
      });
    }
  });

  group('analysis_baseline.json', () {
    test('file keys are strictly sorted', () {
      expect(_isSorted(baseline.keys), isTrue);
    });

    test('rule keys are strictly sorted and counts are positive integers', () {
      for (final MapEntry(:key, :value) in baseline.entries) {
        final Map<String, Object?> counts = _asMap(value, key);
        expect(counts, isNotEmpty, reason: '$key has an empty map');
        expect(_isSorted(counts.keys), isTrue, reason: '$key rule keys');
        for (final MapEntry(key: rule, value: count) in counts.entries) {
          expect(
            count,
            isA<int>().having((int c) => c, 'count', greaterThan(0)),
            reason: '$key#$rule',
          );
        }
      }
    });

    test('has no $_cleanRule ceiling', () {
      final List<String> offenders = [
        for (final MapEntry(:key, :value) in baseline.entries)
          if (_asMap(value, key).containsKey(_cleanRule)) key,
      ];
      expect(offenders, isEmpty);
    });
  });
}
