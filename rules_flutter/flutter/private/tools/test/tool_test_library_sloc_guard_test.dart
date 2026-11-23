// Tagged `runfiles`: this test imports `package:runfiles` to read the test
// libraries handed to it through runfiles paths, supplied via the
// `@rules_dart//dart/runfiles` dep its `dart_test` declares. A bare `dart test`
// resolves only this package's pubspec, where that import does not exist.
// Coverage comes from //flutter/private/tools:tool_test_library_sloc_guard_test.
@Tags(['runfiles'])
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// The file-size ceiling every test library must stay under.
const _newFileCeiling = 600;

/// The `test(` cases and SLOC bound for one library, found via an env var.
typedef _Library = ({String env, int maxSloc, int minCases});

String _read(String env) {
  final String? rel = Platform.environment[env];
  if (rel == null || rel.isEmpty) {
    fail('$env is not set; run this through `bazel test`.');
  }
  return File(Runfiles.create().rlocation(rel)).readAsStringSync();
}

/// Non-blank, non-`//` lines: the gate's SLOC measure.
int _sloc(String source) => source
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty && !l.startsWith('//'))
    .length;

int _cases(String source) => RegExp(r'\btest\(').allMatches(source).length;

void main() {
  group('retained libraries', () {
    const libraries = <_Library>[
      (env: 'INCR_FKC_WORKER_TEST', maxSloc: 1055, minCases: 40),
      (env: 'KERNEL_FILTER_TEST', maxSloc: 1361, minCases: 74),
    ];
    for (final lib in libraries) {
      test('${lib.env} stays within its ceiling and case floor', () {
        final String source = _read(lib.env);
        expect(_sloc(source), lessThanOrEqualTo(lib.maxSloc));
        expect(_cases(source), greaterThanOrEqualTo(lib.minCases));
      });
    }
  });

  group('relocated libraries', () {
    const libraries = <({String env, int cases})>[
      (env: 'INCR_FKC_DEFINE_FLAGFILES_TEST', cases: 7),
      (env: 'INCR_FKC_STAGING_TEST', cases: 17),
      (env: 'KERNEL_READ_SET_TEST', cases: 9),
      (env: 'KERNEL_DEFINE_FLAGFILES_TEST', cases: 11),
    ];
    for (final lib in libraries) {
      test('${lib.env} is small and keeps its cases', () {
        final String source = _read(lib.env);
        expect(_sloc(source), lessThanOrEqualTo(_newFileCeiling));
        expect(_cases(source), lib.cases);
      });
    }
  });
}
