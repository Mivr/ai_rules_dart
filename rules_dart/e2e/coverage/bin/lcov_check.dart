import 'dart:io';

import 'package:coverage_e2e/lcov_check.dart';

/// `lcov_check <expectation args> <report>`: exits 1 and prints every failed
/// assertion unless the combined LCOV report at the last argument satisfies
/// the expectations (see [LcovExpectation.parse]).
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: lcov_check --file=<path> ... <report>');
    exit(2);
  }
  final LcovExpectation expect;
  try {
    expect = LcovExpectation.parse(args.sublist(0, args.length - 1));
  } on FormatException catch (e) {
    stderr.writeln('lcov_check: ${e.message}');
    exit(2);
  }
  final File report = File(args.last);
  if (!report.existsSync()) {
    stderr.writeln('lcov_check: no report at ${args.last}');
    exit(1);
  }
  final List<String> failures = checkLcov(report.readAsStringSync(), expect);
  for (final String failure in failures) {
    stderr.writeln('FAIL $failure');
  }
  if (failures.isNotEmpty) exit(1);
  stdout.writeln('lcov_check: ${expect.file} passed');
}
