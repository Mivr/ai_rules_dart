/// Guard: newly added tests keep Gate 06 size and tag hygiene.
///
/// `bazel test //...` silently skips a `manual` test target, a non-sandboxed
/// test must not claim to be `small` (small tests are hermetic), and every
/// test target, Starlark `unittest.suite` member included, names its `size`.
/// This test reads the BUILD and `.bzl` files that once broke those rules and
/// fails unless:
///
/// * `e2e/integration_ios` lints `plugin_spm_objc_test.dart` through the
///   non-test `flutter_library` `plugin_spm_objc_lint` (no `manual` test twin)
///   that `ios_dart_analysis_test` analyzes, and both
///   `plugin_spm_graph_test_lint` and `ios_dart_analysis_test` are `small`;
/// * the non-sandboxed `min_versions_android_guard_test` is `medium`;
/// * each listed `flutter/tests/*_test.bzl` suite sizes its members `small`,
///   through `small_unittest_suite` or `partial.make(..., size = "small")`.
///
/// Like the other static guards it reads undeclared files from the workspace
/// root, so it is tagged `external` and never replays a cached pass.
library;

import 'dart:io';

import 'package:test/test.dart';

const _iosBuild = 'e2e/integration_ios/BUILD.bazel';
const _testsBuild = 'flutter/tests/BUILD.bazel';

/// The `.bzl` files whose `unittest.suite` members must be sized `small`.
const _suiteFiles = <String>[
  'flutter/tests/flutter_pub_apple_deps_test.bzl',
  'flutter/tests/flutter_pub_apple_pods_test.bzl',
  'flutter/tests/flutter_pub_cycle_breaks_test.bzl',
  'flutter/tests/flutter_pub_plugin_defines_test.bzl',
  'flutter/tests/ios_plugin_deps_test.bzl',
  'flutter/tests/podfile_lock_test.bzl',
  'flutter/tests/swiftpm_plugin_local_test.bzl',
];

/// Non-sandboxed guards in [_testsBuild] that must declare `size = "medium"`.
const _mediumGuards = <String>[
  'min_versions_android_guard_test',
  'test_hygiene_regressions_guard_test',
];

/// Every file this guard reads.
const _guardedFiles = <String>[_iosBuild, _testsBuild, ..._suiteFiles];

/// Whether [dir] holds every file this guard reads.
bool _holdsGuardedFiles(String dir) =>
    _guardedFiles.every((String path) => File('$dir/$path').existsSync());

/// The workspace root: `BUILD_WORKSPACE_DIRECTORY` when it holds the guarded
/// files, otherwise the nearest ancestor of this test's source (reached
/// through the `GUARD_ROOT_ANCHOR` runfile) that does. Null when neither
/// resolves, so the test fails loudly instead of reading another tree.
String? _findRoot() {
  final Map<String, String> env = Platform.environment;
  final String? direct = env['BUILD_WORKSPACE_DIRECTORY'];
  if (direct != null && _holdsGuardedFiles(direct)) return direct;
  final String? anchor = env['GUARD_ROOT_ANCHOR'];
  final String? runfiles = env['TEST_SRCDIR'];
  if (anchor == null || runfiles == null) return null;
  final link = File('$runfiles/$anchor');
  if (!link.existsSync()) return null;
  Directory current = File(link.resolveSymbolicLinksSync()).parent;
  while (current.parent.path != current.path) {
    if (_holdsGuardedFiles(current.path)) return current.path;
    current = current.parent;
  }
  return null;
}

/// Starlark source as two views of equal length: `code` with every `#`
/// comment blanked, and `shape` with string bodies blanked as well, so bracket
/// matching and call lookup on `shape` never trip over text inside a comment
/// or a string while `code` still yields the attribute values.
typedef _Source = ({String code, String shape});

/// One call expression: its brackets span `open` to `close` in `source`.
typedef _Call = ({_Source source, int open, int close});

/// [text] split into its `code` and `shape` views.
_Source _parse(String text) {
  final code = StringBuffer();
  final shape = StringBuffer();
  String? delimiter;
  var i = 0;
  while (i < text.length) {
    if (delimiter == null && text.startsWith('#', i)) {
      final int end = text.indexOf('\n', i);
      final int stop = end < 0 ? text.length : end;
      code.write(' ' * (stop - i));
      shape.write(' ' * (stop - i));
      i = stop;
      continue;
    }
    final String? token = _stringToken(text, i, delimiter);
    if (token != null) {
      delimiter = delimiter == null ? token : null;
      code.write(token);
      shape.write(token);
      i += token.length;
      continue;
    }
    final bool escaped = delimiter != null && text.startsWith(r'\', i);
    final width = escaped && i + 1 < text.length ? 2 : 1;
    final String chunk = text.substring(i, i + width);
    code.write(chunk);
    shape.write(delimiter == null ? chunk : ' ' * width);
    i += width;
  }
  return (code: code.toString(), shape: shape.toString());
}

/// The string delimiter at [index] of [text] that opens a string (when
/// [delimiter] is null) or closes the open [delimiter]; null otherwise.
String? _stringToken(String text, int index, String? delimiter) {
  if (delimiter != null) {
    return text.startsWith(delimiter, index) ? delimiter : null;
  }
  for (final quote in const ['"""', "'''", '"', "'"]) {
    if (text.startsWith(quote, index)) return quote;
  }
  return null;
}

/// Every call to [callee] (a plain or dotted name) in [source], in order.
List<_Call> _calls(_Source source, String callee) {
  final pattern = RegExp('(?<![\\w.])${RegExp.escape(callee)}\\s*\\(');
  return [
    for (final RegExpMatch match in pattern.allMatches(source.shape))
      if (_closing(source.shape, match.end - 1) case final int close)
        (source: source, open: match.end - 1, close: close),
  ];
}

/// Index of the bracket in [shape] closing the one at [open], or null when
/// the text ends first.
int? _closing(String shape, int open) {
  var depth = 0;
  for (var i = open; i < shape.length; i++) {
    final String ch = shape[i];
    if ('([{'.contains(ch)) depth++;
    if (')]}'.contains(ch) && --depth == 0) return i;
  }
  return null;
}

/// The top-level arguments of [call] as `code` text, trimmed, in order.
List<String> _arguments(_Call call) {
  final String shape = call.source.shape;
  final String code = call.source.code;
  final parts = <String>[];
  var depth = 0;
  int start = call.open + 1;
  for (int i = call.open + 1; i < call.close; i++) {
    final String ch = shape[i];
    if ('([{'.contains(ch)) depth++;
    if (')]}'.contains(ch)) depth--;
    if (ch == ',' && depth == 0) {
      parts.add(code.substring(start, i).trim());
      start = i + 1;
    }
  }
  parts.add(code.substring(start, call.close).trim());
  return parts.where((String part) => part.isNotEmpty).toList();
}

/// Whether [argument] is a keyword argument (`key = value`).
bool _isKeyword(String argument) => RegExp(r'^\w+\s*=(?!=)').hasMatch(argument);

/// The string literals in the value of [call]'s keyword argument [key].
List<String> _strings(_Call call, String key) {
  final prefix = RegExp('^${RegExp.escape(key)}\\s*=\\s*');
  for (final String argument in _arguments(call)) {
    final RegExpMatch? match = prefix.firstMatch(argument);
    if (match == null) continue;
    return [
      for (final RegExpMatch literal in RegExp(
        r'''(["'])(.*?)\1''',
      ).allMatches(argument.substring(match.end)))
        literal.group(2)!,
    ];
  }
  return const <String>[];
}

/// The single string literal of [call]'s keyword argument [key], or null.
String? _string(_Call call, String key) {
  final List<String> found = _strings(call, key);
  return found.length == 1 ? found.single : null;
}

/// Every file this guard has read, so the last test can prove none was
/// skipped.
final _read = <String>{};

/// [path] under [root], parsed; records the read.
_Source _load(String root, String path) {
  final _Source source = _parse(File('$root/$path').readAsStringSync());
  _read.add(path);
  return source;
}

/// The single call to [callee] in [source] whose `name` is [name]; fails
/// otherwise, naming [path].
_Call _target(_Source source, String path, String callee, String name) {
  final List<_Call> found = [
    for (final _Call call in _calls(source, callee))
      if (_string(call, 'name') == name) call,
  ];
  if (found.length != 1) {
    fail(
      '$path: expected exactly one $callee named "$name", '
      'found ${found.length}',
    );
  }
  return found.single;
}

/// Fails unless [call] declares exactly `size = "[size]"`, naming [path].
void _expectSize(_Call call, String path, String size) {
  final String? declared = _string(call, 'size');
  if (declared != size) {
    fail(
      '$path: ${_string(call, 'name')} declares size '
      '${declared ?? 'nothing'}, expected size = "$size"',
    );
  }
}

/// Whether [argument] passes members as `partial.make(..., size = "small")`,
/// alone or starred over a list comprehension.
bool _isSmallPartial(String argument) {
  final String body = argument.startsWith('*')
      ? argument.substring(1).trim()
      : argument;
  final sized = RegExp(r'''partial\.make\([^()]*\bsize\s*=\s*["']small["']''');
  final bool shaped =
      body.startsWith('partial.make(') ||
      (body.startsWith('[') && body.contains(' for '));
  return shaped && sized.hasMatch(body);
}

/// Problems with the unit-test suite sizing in [source], empty when every
/// suite member is `small`.
List<String> _suiteProblems(_Source source) {
  final List<_Call> plain = _calls(source, 'unittest.suite');
  if (plain.isEmpty && _calls(source, 'small_unittest_suite').isEmpty) {
    return ['declares no small_unittest_suite or unittest.suite'];
  }
  return [
    for (final _Call suite in plain)
      // The first positional argument is the suite name; the rest are members.
      for (final String member in _arguments(
        suite,
      ).where((String argument) => !_isKeyword(argument)).skip(1))
        if (!_isSmallPartial(member))
          'unittest.suite member `$member` has no partial.make size = "small"',
  ];
}

void _iosLintChecks(String root) {
  test('$_iosBuild drops the manual plugin_spm_objc_test_lint', () {
    final String raw = File('$root/$_iosBuild').readAsStringSync();
    expect(raw, isNot(contains('plugin_spm_objc_test_lint')));
  });
  test('$_iosBuild lints plugin_spm_objc_test.dart through a library', () {
    final _Source source = _load(root, _iosBuild);
    final _Call library = _target(
      source,
      _iosBuild,
      'flutter_library',
      'plugin_spm_objc_lint',
    );
    expect(
      _strings(library, 'srcs'),
      contains('integration_test/plugin_spm_objc_test.dart'),
    );
    expect(_strings(library, 'tags'), isNot(contains('manual')));
    final _Call analysis = _target(
      source,
      _iosBuild,
      'dart_analysis_test',
      'ios_dart_analysis_test',
    );
    expect(_strings(analysis, 'targets'), contains(':plugin_spm_objc_lint'));
  });
  test('$_iosBuild lint and analysis tests are small', () {
    final _Source source = _load(root, _iosBuild);
    final _Call graph = _target(
      source,
      _iosBuild,
      'flutter_test',
      'plugin_spm_graph_test_lint',
    );
    _expectSize(graph, _iosBuild, 'small');
    final _Call analysis = _target(
      source,
      _iosBuild,
      'dart_analysis_test',
      'ios_dart_analysis_test',
    );
    _expectSize(analysis, _iosBuild, 'small');
  });
}

void _guardSizeChecks(String root) {
  test('$_testsBuild non-sandboxed guards are medium', () {
    final _Source source = _load(root, _testsBuild);
    for (final String name in _mediumGuards) {
      final _Call guard = _target(source, _testsBuild, 'dart_test', name);
      expect(_strings(guard, 'tags'), contains('no-sandbox'));
      _expectSize(guard, _testsBuild, 'medium');
    }
  });
}

void _suiteChecks(String root) {
  for (final String path in _suiteFiles) {
    test('$path sizes its unit-test suite small', () {
      final List<String> problems = _suiteProblems(_load(root, path));
      if (problems.isNotEmpty) fail('$path: ${problems.join('; ')}');
    });
  }
}

void main() {
  final String? root = _findRoot();
  if (root == null) {
    test('the workspace root is discoverable', () {
      fail(
        'cannot find the rules_flutter workspace root; run this test '
        'unsandboxed through bazel test //flutter/tests/...',
      );
    });
    return;
  }
  _iosLintChecks(root);
  _guardSizeChecks(root);
  _suiteChecks(root);
  test('every guarded file was read', () {
    expect(_read, unorderedEquals(_guardedFiles));
    expect(_read, hasLength(9));
  });
}
