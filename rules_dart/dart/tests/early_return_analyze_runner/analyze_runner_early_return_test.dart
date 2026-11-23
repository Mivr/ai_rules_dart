import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const _caseName = 'refuses a triple-quoted import before analyzing';

/// Pins that the analyze_runner test skips declaratively instead of returning
/// before its first assertion, which `package:test` would report as passed.
void main(List<String> args) {
  late String source;

  setUpAll(() {
    final String path = Runfiles.create().rlocation(args[0]);
    source = File(path).readAsStringSync();
  });

  test('the source read is not vacuous', () {
    expect(source, contains(_caseName));
    expect(
      RegExp(r'\btest\(').allMatches(source).length,
      greaterThanOrEqualTo(4),
    );
  });

  test('no line is the silent early-return guard', () {
    final Iterable<String> guards = source
        .split('\n')
        .where((line) => line.trim() == 'if (args.isEmpty) return;');
    expect(guards, isEmpty);
  });

  test('the case holds exactly one declarative skip with a reason', () {
    final skip = RegExp(
      r"skip:\s*args\.isEmpty\s*\?\s*'[^']+'\s*:\s*null",
      multiLine: true,
    );
    expect(skip.allMatches(source), hasLength(1));
  });
}
