/// Guards `kernel_module_test.dart`: a test that returns before its first
/// `expect` is reported as passed, so the cases that need the `kernel_module`
/// AOT snapshot must skip declaratively instead.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const _names = [
  'undecodable bytes fail the request after one retry',
  'a truncated frame fails the request after one retry',
  'a worker that exits before reading fails the request after one retry',
  'pristine snapshot with comma define fails loudly',
  'patched snapshot without marker still fails',
  'patched snapshot plus marker succeeds',
  'ignores planted shared-temp files',
  'leaves scratch TMPDIR empty',
];

void main(List<String> args) {
  late String source;

  setUpAll(() {
    final String path = Runfiles.create().rlocation(args.first);
    source = File(path).readAsStringSync();
  });

  test('the source read is not vacuous', () {
    for (final String name in _names) {
      expect(source, contains(name));
    }
    expect(RegExp(r'\btest\(').allMatches(source).length, greaterThan(139));
  });

  test('no test returns early on a missing snapshot', () {
    final List<String> guards = [
      for (final String line in source.split('\n'))
        if (line.trim() == 'if (_toolSnapshotPath.isEmpty) return;') line,
    ];
    expect(guards, isEmpty);
  });

  test('eight declarative skips name the missing snapshot', () {
    final Iterable<RegExpMatch> skips = RegExp(
      r"skip:\s*_toolSnapshotPath\.isEmpty\s*\?\s*'[^']+'\s*:\s*null",
      multiLine: true,
    ).allMatches(source);
    expect(skips.length, 8);
  });
}
