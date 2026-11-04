import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const List<String> _targets = ['kernel_module_test', 'worker_hardening_test'];

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

bool _isSharded(String block) {
  final RegExpMatch? m = RegExp(r'shard_count\s*=\s*(\d+)').firstMatch(block);
  return m != null && int.parse(m.group(1)!) >= 2;
}

/// Returns problems with the declared size and forbidden attributes of [name].
List<String> _violations(String build, String name) {
  final String? block = _callBlock(build, name);
  if (block == null) {
    return ['$name: dart_test call not found'];
  }
  final List<String> problems = [];
  if (!_isSharded(block) &&
      !RegExp(r'size\s*=\s*"(medium|large)"').hasMatch(block)) {
    problems.add('$name: unsharded target must declare size medium or large');
  }
  if (RegExp(r'flaky\s*=\s*True').hasMatch(block) ||
      block.contains('"flaky"') ||
      block.contains('"manual"')) {
    problems.add('$name: must not be flaky or manual');
  }
  if (RegExp(r'timeout\s*=').hasMatch(block)) {
    problems.add('$name: must not override timeout');
  }
  return problems;
}

String _call(String extra) => 'dart_test(\n    name = "t",\n$extra)\n';

void main(List<String> args) {
  group('parser', () {
    test('accepts unsharded size medium', () {
      expect(_violations(_call('    size = "medium",\n'), 't'), isEmpty);
    });
    test('accepts sharded shard_count 4', () {
      expect(
        _violations(_call('    size = "small",\n    shard_count = 4,\n'), 't'),
        isEmpty,
      );
    });
    test('rejects unsharded size small', () {
      expect(_violations(_call('    size = "small",\n'), 't'), isNotEmpty);
    });
    test('rejects omitted size', () {
      expect(_violations(_call(''), 't'), isNotEmpty);
    });
    test('rejects commented-out size medium', () {
      expect(_violations(_call('    # size = "medium",\n'), 't'), isNotEmpty);
    });
    test('rejects flaky = True', () {
      expect(
        _violations(_call('    size = "medium",\n    flaky = True,\n'), 't'),
        isNotEmpty,
      );
    });
    test('rejects timeout = "long"', () {
      expect(
        _violations(
          _call('    size = "medium",\n    timeout = "long",\n'),
          't',
        ),
        isNotEmpty,
      );
    });
  });

  group('slow test sizes', () {
    final runfiles = Runfiles.create();
    final String joined = args
        .map((String a) => File(runfiles.rlocation(a)).readAsStringSync())
        .join('\n');
    for (final String name in _targets) {
      test('$name is sized for its run time', () {
        expect(_violations(joined, name), isEmpty);
      });
    }
  });
}
