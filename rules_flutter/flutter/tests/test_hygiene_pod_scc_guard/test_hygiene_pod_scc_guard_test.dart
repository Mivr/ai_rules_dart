/// Test-hygiene guard for the pod lint library, pub_scc sizes and suites.
///
/// Reads the live BUILD and `.bzl` files and fails when a hygiene fix is
/// undone: `flaky_guard_test` must be `medium` (it disables the sandbox),
/// `plugin_pod_test_lint` must stay gone in favour of the non-test
/// `plugin_pod_lint` library, the iOS pod tests must be `large`, the pub_scc
/// and dev_tool tests must be `small`, and the two Starlark suites must size
/// their members.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

late final List<String> _args;

/// Finds the workspace root from `BUILD_WORKSPACE_DIRECTORY` or, failing
/// that, from the runfiles location of this test's source file.
String _workspaceRoot() {
  final String? fromEnv = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  final String located = Runfiles.create().rlocation(_args.first);
  final String source = File(located).resolveSymbolicLinksSync();
  return File(source).parent.parent.parent.parent.path;
}

/// Source text of the call whose `name = "[name]"` attribute matches, or null.
String? _callBody(String text, String name) {
  final RegExpMatch? at = RegExp('name\\s*=\\s*"$name"').firstMatch(text);
  if (at == null) return null;
  final int open = text.lastIndexOf('(', at.start);
  var depth = 0;
  for (var i = open; i < text.length; i++) {
    if (text[i] == '(') depth++;
    if (text[i] == ')' && --depth == 0) return text.substring(open, i + 1);
  }
  return null;
}

/// Whether [text] declares exactly `size = "[size]"` on target [name].
bool _hasSize(String text, String name, String size) {
  final String? body = _callBody(text, name);
  return body != null && RegExp('\\bsize\\s*=\\s*"$size"').hasMatch(body);
}

/// Whether the Starlark suite is sized small, via the helper or a partial.
bool _suiteIsSmall(String text) {
  if (text.contains('small_unittest_suite(')) return true;
  return text.contains('unittest.suite(') &&
      text.contains('partial.make') &&
      RegExp(r'size\s*=\s*"small"').hasMatch(text);
}

String _read(String root, String relative) {
  final file = File('$root/$relative');
  expect(file.existsSync(), isTrue, reason: '$relative must exist');
  return file.readAsStringSync();
}

void main(List<String> args) {
  _args = args;

  group('parser', () {
    test('rejects a target without size', () {
      const text = 'dart_test(\n    name = "t",\n    main = "m.dart",\n)\n';
      expect(_hasSize(text, 't', 'small'), isFalse);
    });
    test('rejects the wrong size', () {
      const text =
          'dart_test(\n    name = "flaky_guard_test",\n'
          '    size = "small",\n)\n';
      expect(_hasSize(text, 'flaky_guard_test', 'medium'), isFalse);
      expect(_hasSize(text, 'plugin_pod_test', 'large'), isFalse);
    });
    test('accepts the right size', () {
      const text = 'x(\n    name = "t",\n    size = "large",\n)\n';
      expect(_hasSize(text, 't', 'large'), isTrue);
    });
    test('rejects an unsized unittest.suite', () {
      expect(_suiteIsSmall('unittest.suite(name, a, b)'), isFalse);
      expect(_suiteIsSmall('small_unittest_suite(name, a)'), isTrue);
      expect(
        _suiteIsSmall(
          'unittest.suite(n, *[partial.make(t, size = "small") for t in [a]])',
        ),
        isTrue,
      );
    });
  });

  group('live workspace', () {
    late String root;
    setUpAll(() => root = _workspaceRoot());

    test('flaky_guard_test is medium', () {
      final String text = _read(root, 'flutter/tests/flaky_guard/BUILD.bazel');
      expect(_hasSize(text, 'flaky_guard_test', 'medium'), isTrue);
      expect(_hasSize(text, 'flaky_guard_test', 'small'), isFalse);
    });

    test('integration_ios pod lint is a non-test library', () {
      final String text = _read(root, 'e2e/integration_ios/BUILD.bazel');
      expect(text, isNot(contains('plugin_pod_test_lint')));
      final String? lint = _callBody(text, 'plugin_pod_lint');
      expect(lint, isNotNull);
      expect(lint, contains('integration_test/plugin_pod_test.dart'));
      expect(lint, isNot(contains('manual')));
      expect(text, contains('flutter_library(\n    name = "plugin_pod_lint"'));
      final String? analysis = _callBody(text, 'ios_dart_analysis_test');
      expect(analysis, contains('":plugin_pod_lint"'));
      expect(_hasSize(text, 'plugin_pod_test', 'large'), isTrue);
      expect(_hasSize(text, 'plugin_pod_wrong_test', 'large'), isTrue);
      expect(
        _callBody(text, 'plugin_pod_wrong_test'),
        matches(RegExp(r'tags\s*=\s*\["manual"\]')),
      );
    });

    test('pub_scc and dev_tool tests are small', () {
      final String scc = _read(root, 'e2e/pub_scc/BUILD.bazel');
      final String tool = _read(root, 'tools/dev_tool/BUILD.bazel');
      for (final name in [
        'scc_3cycle_test',
        'asset_bundle_test',
        'verify_android_apk_test',
        'verify_ios_bundle_test',
      ]) {
        expect(_hasSize(scc, name, 'small'), isTrue, reason: name);
      }
      expect(_hasSize(tool, 'warm_ios_e2e_test', 'small'), isTrue);
    });

    test('Starlark suites size their members', () {
      final files = [
        'flutter/tests/flutter_pub_scc_test.bzl',
        'flutter/tests/podspec_read_test.bzl',
      ];
      var read = 0;
      for (final file in files) {
        final String text = _read(root, file);
        read++;
        expect(_suiteIsSmall(text), isTrue, reason: file);
      }
      expect(read, 2);
    });
  });
}
