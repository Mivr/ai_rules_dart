import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const List<String> _targets = [
  'repro_canary_guard_test',
  'architecture_invariants_scan_test',
  'bzl_library_guard_test',
  'flaky_guard_test',
  'format_sandbox_cells_guard_test',
];

/// Returns the `dart_test` call block for [name], with `#` comments removed.
String? _callBlock(String build, String name) {
  final String stripped = build
      .split('\n')
      .map((String l) => l.replaceFirst(RegExp(r'#.*$'), ''))
      .join('\n');
  final start = RegExp('dart_test\\(\\s*name\\s*=\\s*"${RegExp.escape(name)}"');
  final RegExpMatch? m = start.firstMatch(stripped);
  if (m == null) {
    return null;
  }
  final int end = stripped.indexOf(RegExp(r'^\)', multiLine: true), m.start);
  return end < 0
      ? stripped.substring(m.start)
      : stripped.substring(m.start, end);
}

/// Returns problems with the declared size, locality and tags of [name].
List<String> _violations(String build, String name) {
  final String? block = _callBlock(build, name);
  if (block == null) {
    return ['$name: dart_test call not found'];
  }
  final List<String> problems = [];
  if (!RegExp(r'size\s*=\s*"medium"').hasMatch(block) ||
      RegExp(r'size\s*=\s*"small"').hasMatch(block)) {
    problems.add('$name: must declare size = "medium"');
  }
  if (!RegExp(r'local\s*=\s*True').hasMatch(block)) {
    problems.add('$name: must declare local = True');
  }
  if (!block.contains('"no-sandbox"')) {
    problems.add('$name: tags must include "no-sandbox"');
  }
  return problems;
}

String _call(String size) =>
    'dart_test(\n    name = "t",\n$size    local = True,\n'
    '    tags = ["external", "no-sandbox"],\n)\n';

void main(List<String> args) {
  group('parser', () {
    test('accepts size medium', () {
      expect(_violations(_call('    size = "medium",\n'), 't'), isEmpty);
    });
    test('rejects size small', () {
      expect(_violations(_call('    size = "small",\n'), 't'), isNotEmpty);
    });
    test('rejects omitted size', () {
      expect(_violations(_call(''), 't'), isNotEmpty);
    });
    test('rejects commented-out size medium', () {
      expect(_violations(_call('    # size = "medium",\n'), 't'), isNotEmpty);
    });
  });

  group('guard test sizes', () {
    final runfiles = Runfiles.create();
    final String joined = args
        .map((String a) => File(runfiles.rlocation(a)).readAsStringSync())
        .join('\n');
    for (final String name in _targets) {
      test('$name is medium, local and no-sandbox', () {
        expect(_violations(joined, name), isEmpty);
      });
    }
  });
}
