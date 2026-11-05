/// Sandboxed hygiene checks for the `tools/perf` build file and production code.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

String _read(Runfiles runfiles, String rlocationPath) {
  final path = runfiles.rlocation(rlocationPath);
  _check(File(path).existsSync(), 'runfile exists: $rlocationPath');
  return File(path).readAsStringSync();
}

/// Returns the text of the `dart_test(name = "<name>", ...)` call.
String _testRule(String build, String name) {
  final start = build.indexOf('name = "$name"');
  _check(start != -1, 'BUILD declares $name');
  final end = build.indexOf('\n)\n', start);
  return build.substring(start, end == -1 ? build.length : end);
}

void main(List<String> args) {
  _check(args.length >= 2, 'usage: hygiene_test <BUILD.bazel> <sources...>');
  final runfiles = Runfiles.create();

  final build = _read(runfiles, args.first);
  _check(
    _testRule(build, 'workflow_test').contains('size = "medium"'),
    'workflow_test declares size = "medium"',
  );

  final forbidden = RegExp(
    r'\b(TEST_SRCDIR|TEST_TMPDIR|XML_OUTPUT_FILE|TESTBRIDGE_\w*|BAZEL_TEST)\b',
  );
  final sources = args
      .skip(1)
      .expand((a) => a.split(' '))
      .where((a) => a.isNotEmpty);
  var checked = 0;
  for (final source in sources) {
    final match = forbidden.firstMatch(_read(runfiles, source));
    _check(match == null, '$source names ${match?.group(0)}');
    checked++;
  }
  _check(checked >= 10, 'checked the production sources, saw $checked');
  stdout.writeln('Hygiene tests passed.');
}
