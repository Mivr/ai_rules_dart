// Guards the persistent-worker cases in `format_runner_test.dart` and
// `kernel_link_test.dart`: they must skip declaratively when the worker binary
// is missing, never return early and report a pass.

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const _caseName =
    'persistent worker answers a failing request and logs to stderr';

final _earlyReturn = RegExp(
  r'^\s*if \(_toolDillPath\.isEmpty\) return;\s*$',
  multiLine: true,
);

final _declarativeSkip = RegExp(
  r"skip:\s*_toolDillPath\.isEmpty\s*\?\s*'[^']+'\s*:\s*null",
  multiLine: true,
);

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final Map<String, String> sources = {
    'format_runner_test.dart': args[0],
    'kernel_link_test.dart': args[1],
  };
  for (final MapEntry<String, String> entry in sources.entries) {
    group(entry.key, () {
      late String text;
      setUpAll(
        () => text = File(runfiles.rlocation(entry.value)).readAsStringSync(),
      );

      test('read is non-vacuous', () {
        expect(_caseName.allMatches(text).length, 1);
      });

      test('has no early-return guard', () {
        expect(_earlyReturn.hasMatch(text), isFalse);
      });

      test('declares exactly one skip', () {
        expect(_declarativeSkip.allMatches(text).length, 1);
      });
    });
  }
}
