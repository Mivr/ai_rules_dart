import 'dart:io';

import 'package:coverage_e2e/lcov_check.dart';

/// The expectations `//:lcov_check` carries for the fixture library, over
/// checked-in LCOV: the complete report passes and each broken one fails with
/// a message naming the assertion that caught it.
void main() {
  final LcovExpectation expect = LcovExpectation.parse(<String>[
    '--file=lib/coverage_fixture.dart',
    '--executed=14',
    '--unexecuted=12',
    '--uncalled=neverCalledFixtureFunction',
  ]);
  _passes('complete', expect);
  _fails('empty', expect, <String>['SF record']);
  _fails('no_fnda_zero', expect, <String>['uncalled function']);
  _fails('no_brda', expect, <String>['branch data']);
  _fails('absolute_sf', expect, <String>['workspace-relative SF']);
  _wrongLines(expect);
}

String _read(String name) => File('testdata/$name.info').readAsStringSync();

void _passes(String name, LcovExpectation expect) {
  final List<String> failures = checkLcov(_read(name), expect);
  if (failures.isNotEmpty) {
    throw StateError('$name should pass, failed: $failures');
  }
}

void _fails(String name, LcovExpectation expect, List<String> named) {
  final List<String> failures = checkLcov(_read(name), expect);
  for (final String assertion in named) {
    if (!failures.any((String f) => f.contains(assertion))) {
      throw StateError('$name should fail on `$assertion`, got: $failures');
    }
  }
}

/// An executed line reported as 0 and an unexecuted one reported as hit, or
/// absent, are failures too.
void _wrongLines(LcovExpectation expect) {
  final LcovExpectation swapped = LcovExpectation(
    file: expect.file,
    executed: expect.unexecuted,
    unexecuted: expect.executed,
    uncalled: const <String>[],
  );
  final List<String> failures = checkLcov(_read('complete'), swapped);
  _require(failures.any((String f) => f.startsWith('executed line')));
  _require(failures.any((String f) => f.startsWith('unexecuted line')));
  final LcovExpectation absent = LcovExpectation(
    file: expect.file,
    executed: const <int>[99],
    unexecuted: const <int>[98],
    uncalled: const <String>[],
  );
  _require(checkLcov(_read('complete'), absent).length == 2);
}

void _require(bool ok) {
  if (!ok) throw StateError('expected the swapped or absent lines to fail');
}
