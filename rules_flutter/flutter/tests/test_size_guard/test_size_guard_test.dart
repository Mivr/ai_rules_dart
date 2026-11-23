/// Guard: every test target names its size, and weak test cases stay strong.
///
/// Gate 06 asks for a test budget somebody chose and for tests that can fail.
/// A test target without an explicit `size` inherits Bazel's implicit `medium`
/// (300 s), so a hung one burns five minutes and the budget is written down
/// nowhere; a test that returns early, asserts only that a call does not
/// throw, or asserts nothing reports as passed whatever the code does. This
/// test reads the source tree and fails unless:
///
/// * no `flutter/tests/**/*_test.bzl` file calls `unittest.suite` directly:
///   every suite goes through `small_unittest_suite` from
///   `flutter/tests/test_suite.bzl`, the one place that binds
///   `size = "small"` to the members, and at least as many suites do so as
///   there were `unittest.suite` calls before the helper existed;
/// * each BUILD file that holds test targets declares at least the number of
///   explicit `size = "small" | "medium" | "large"` attributes it needs. The
///   e2e workspaces are separate modules the root `bazel test //...` never
///   loads, so their BUILD files are read as text;
/// * each of the Dart cases that once asserted nothing, only
///   `returnsNormally`, or hid a platform skip behind an early `return`
///   carries an assertion whose matcher is not `returnsNormally`, and the
///   macOS-only case skips declaratively so JUnit XML records a skip;
/// * every file above was found, so an empty directory cannot pass.
///
/// The test discovers its inputs from the workspace root (the test's own
/// source file in `data`, or `BUILD_WORKSPACE_DIRECTORY` when set). Reading
/// undeclared files means Bazel cannot know when to re-run, so the target is
/// tagged `external`: the guard re-runs on every invocation and is never
/// served a stale pass.
library;

import 'dart:io';

import 'package:test/test.dart';

/// `unittest.suite` calls under `flutter/tests` before `small_unittest_suite`
/// replaced them. Suites added later only raise the count.
const int _baseSuiteCalls = 51;

/// The helper that is the only place a suite member's size is bound.
const String _suiteHelper = 'flutter/tests/test_suite.bzl';

/// The macOS-only case that must skip declaratively.
const String _appliedVersions =
    'tools/dev_tool/test/applied_versions_test.dart';

/// Title of the case in [_appliedVersions] that is specific to APFS.
const String _apfsTitle =
    'sub-second mtime precision is preserved on macOS APFS';

/// The fewest explicit sizes each BUILD file must declare, by path.
const Map<String, int> _minimumSizes = <String, int>{
  'e2e/_overlay_tests/link_hooks/BUILD.bazel': 1,
  'e2e/android_example/BUILD.bazel': 4,
  'e2e/codegen/BUILD.bazel': 7,
  'e2e/ffi_example/BUILD.bazel': 10,
  'e2e/ffi_plugin_example/BUILD.bazel': 2,
  'e2e/hello_world/BUILD.bazel': 27,
  'e2e/hello_world/font_manifest/BUILD.bazel': 1,
  'e2e/integration_android/BUILD.bazel': 1,
  'e2e/integration_android/apps/sub/BUILD.bazel': 1,
  'e2e/integration_ios/BUILD.bazel': 10,
  'e2e/integration_linux/BUILD.bazel': 1,
  'e2e/integration_web/BUILD.bazel': 1,
  'e2e/ios_example/BUILD.bazel': 8,
  'e2e/linux_example/BUILD.bazel': 2,
  'e2e/macos_example/BUILD.bazel': 9,
  'e2e/multi_window_example/BUILD.bazel': 1,
  'e2e/plugin_example/BUILD.bazel': 6,
  'e2e/plugin_example/glass_app/BUILD.bazel': 1,
  'e2e/run_home/BUILD.bazel': 4,
  'e2e/web_example/BUILD.bazel': 3,
  'e2e/web_example/custom_boot/BUILD.bazel': 1,
  'e2e/windows_example/BUILD.bazel': 1,
  'flutter/private/dartdev_patch/BUILD.bazel': 1,
  'flutter/private/tools/BUILD.bazel': 2,
  'tools/dev_tool/BUILD.bazel': 2,
  'tools/ios_screenshot/BUILD.bazel': 1,
  'tools/readme_check/BUILD.bazel': 1,
  'tools/update_flutter_version/BUILD.bazel': 3,
  'tools/vm/BUILD.bazel': 3,
};

/// A Dart test case, by the file that holds it and the title it carries.
typedef _Case = ({String path, String title});

/// The cases that were weak: every one must now assert something concrete.
const List<_Case> _strengthenedCases = <_Case>[
  (
    path: 'flutter/private/tools/test/android_bundle_test.dart',
    title:
        'accepts valid arm64-v8a (EM_AARCH64 = 183) and x86_64 '
        '(EM_X86_64 = 62) ELF headers',
  ),
  (
    path: 'flutter/private/tools/test/macho_edit_test.dart',
    title: 'accepts adjacent ranges sharing only an edge',
  ),
  (
    path: 'flutter/private/tools/test/macho_edit_test.dart',
    title: 'accepts disjoint ranges inside the rewritten image',
  ),
  (
    path: 'flutter/private/tools/test/merge_plists_test.dart',
    title: 'is insensitive to whitespace when comparing values',
  ),
  (
    path: 'tools/dev_tool/test/build_info_test.dart',
    title: 'compares labels in one form, so the apparent one is not a mismatch',
  ),
  (
    path: 'tools/dev_tool/test/build_info_test.dart',
    title: 'tolerates a query that could not answer',
  ),
  (
    path: 'tools/dev_tool/test/cli_args_test.dart',
    title: 'an argv with no positionals passes',
  ),
  (
    path:
        'flutter/private/tools/test/flutter_integration_test_runner_test.dart',
    title: 'swallows a peer-gone I/O race and an already-closed race',
  ),
  (
    path: 'flutter/private/tools/test/flutter_test_runner_test.dart',
    title: 'swallows a peer-gone I/O race and an already-closed race',
  ),
  (
    path: 'tools/dev_tool/test/app_log_test.dart',
    title: 'close is idempotent',
  ),
  (
    path: 'tools/dev_tool/test/command_runner_test.dart',
    title: 'a slow-but-bounded handler does not block the queue indefinitely',
  ),
  (
    path: 'tools/dev_tool/test/device_test.dart',
    title: 'preflight passes when every tool is present',
  ),
  (
    path: 'tools/dev_tool/test/device_test.dart',
    title: 'returns once a listener accepts',
  ),
  (
    path: 'tools/dev_tool/test/http_control_channel_test.dart',
    title: 'stop is idempotent',
  ),
  (
    path: 'tools/dev_tool/test/native_hot_patch_tool_test.dart',
    title: 'a snapshot answers ok',
  ),
  (
    path: 'tools/dev_tool/test/session_host_test.dart',
    title: 'stops the HTTP channel it started',
  ),
  (
    path: 'tools/dev_tool/test/session_test.dart',
    title: 'ends the run when there is nothing left to control',
  ),
  (
    path: 'tools/dev_tool/test/teardown_test.dart',
    title: 'an empty teardown runs cleanly',
  ),
  (
    path: 'tools/dev_tool/test/vm_service_client_test.dart',
    title: 'returns once the app has the extension',
  ),
  (
    path: 'tools/dev_tool/test/vm_service_client_test.dart',
    title: 'waits for a registration that arrives late',
  ),
  (path: _appliedVersions, title: _apfsTitle),
];

/// The source language a scan reads, which decides what a comment and a
/// string look like.
enum _Lang { dart, starlark }

/// Whether [dir] is the rules_flutter workspace root.
bool _isRoot(String dir) =>
    Directory('$dir/flutter/tests').existsSync() &&
    File('$dir/MODULE.bazel').existsSync();

/// The workspace root: `BUILD_WORKSPACE_DIRECTORY` when set, otherwise the
/// nearest ancestor of this test's own source file, reached through the
/// runfiles anchor. Null when neither resolves, so the test fails loudly
/// instead of reading another tree or passing on nothing.
String? _findRoot() {
  final Map<String, String> env = Platform.environment;
  final String? direct = env['BUILD_WORKSPACE_DIRECTORY'];
  if (direct != null && _isRoot(direct)) return direct;
  final String? anchor = env['GUARD_ROOT_ANCHOR'];
  final String? runfiles = env['TEST_SRCDIR'];
  if (anchor == null || runfiles == null) return null;
  final link = File('$runfiles/$anchor');
  if (!link.existsSync()) return null;
  Directory dir = File(link.resolveSymbolicLinksSync()).parent;
  while (dir.path != dir.parent.path) {
    if (_isRoot(dir.path)) return dir.path;
    dir = dir.parent;
  }
  return null;
}

/// Path of [entity] relative to [root].
String _relative(String root, FileSystemEntity entity) =>
    entity.path.substring(root.length + 1);

/// Relative paths of every `*_test.bzl` under `flutter/tests`, sorted.
List<String> _suiteTestFiles(String root) {
  final tests = Directory('$root/flutter/tests');
  final found = <String>[
    for (final FileSystemEntity entity in tests.listSync(recursive: true))
      if (entity is File && entity.path.endsWith('_test.bzl'))
        _relative(root, entity),
  ];
  return found..sort();
}

/// Every file the guard reads, by path relative to the workspace root.
Map<String, String> _readWorkspace(String root) {
  final paths = <String>[
    ..._suiteTestFiles(root),
    _suiteHelper,
    ..._minimumSizes.keys,
    for (final _Case weak in _strengthenedCases) weak.path,
  ];
  final files = <String, String>{};
  for (final path in paths) {
    final file = File('$root/$path');
    if (file.existsSync()) files[path] = file.readAsStringSync();
  }
  return files;
}

/// Index just past the string literal that opens at [start] in [text].
///
/// Handles raw and triple-quoted strings, escapes, and in Dart the
/// `${...}` interpolations whose own strings may reuse the quote.
int _stringEnd(String text, int start, _Lang lang) {
  final String quote = text[start];
  final bool raw =
      start > 0 &&
      text[start - 1] == 'r' &&
      (start < 2 || !RegExp(r'\w').hasMatch(text[start - 2]));
  final String delimiter = text.startsWith(quote * 3, start)
      ? quote * 3
      : quote;
  int i = start + delimiter.length;
  while (i < text.length) {
    if (!raw && text[i] == r'\') {
      i += 2;
    } else if (!raw && lang == _Lang.dart && text.startsWith(r'${', i)) {
      i = _interpolationEnd(text, i + 2);
    } else if (text.startsWith(delimiter, i)) {
      return i + delimiter.length;
    } else {
      i++;
    }
  }
  return text.length;
}

/// Index just past the `}` closing the Dart interpolation whose body starts
/// at [bodyStart].
int _interpolationEnd(String text, int bodyStart) {
  var depth = 1;
  var i = bodyStart;
  while (i < text.length && depth > 0) {
    final String char = text[i];
    if (char == "'" || char == '"') {
      i = _stringEnd(text, i, _Lang.dart);
      continue;
    }
    if (char == '{') depth++;
    if (char == '}') depth--;
    i++;
  }
  return i;
}

/// Index just past the comment that opens at [start], or [start] when none
/// does.
int _commentEnd(String text, int start, _Lang lang) {
  if (lang == _Lang.starlark) {
    if (text[start] != '#') return start;
  } else if (text.startsWith('/*', start)) {
    final int close = text.indexOf('*/', start + 2);
    return close < 0 ? text.length : close + 2;
  } else if (!text.startsWith('//', start)) {
    return start;
  }
  final int newline = text.indexOf('\n', start);
  return newline < 0 ? text.length : newline;
}

/// [chunk] with every character but a newline replaced by a space, so offsets
/// and line numbers match the original.
String _spaces(String chunk) => chunk.replaceAll(RegExp(r'[^\n]'), ' ');

/// [text] with every comment blanked and, when [blankStrings], every string
/// literal blanked too. Offsets and line numbers match the original.
String _blank(String text, _Lang lang, {required bool blankStrings}) {
  final out = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final int commentEnd = _commentEnd(text, i, lang);
    if (commentEnd > i) {
      out.write(_spaces(text.substring(i, commentEnd)));
      i = commentEnd;
    } else if (text[i] == '"' || text[i] == "'") {
      final int end = _stringEnd(text, i, lang);
      final String literal = text.substring(i, end);
      out.write(blankStrings ? _spaces(literal) : literal);
      i = end;
    } else {
      out.write(text[i]);
      i++;
    }
  }
  return out.toString();
}

/// Index of the `)` closing the `(` at [open] in comment-blanked Dart
/// [text], skipping strings, or null when the call never closes.
int? _closingParen(String text, int open) {
  var depth = 0;
  var i = open;
  while (i < text.length) {
    final String char = text[i];
    if (char == "'" || char == '"') {
      i = _stringEnd(text, i, _Lang.dart);
      continue;
    }
    if (char == '(') depth++;
    if (char == ')') depth--;
    if (depth == 0) return i;
    i++;
  }
  return null;
}

/// The text of every `test(...)` call in comment-blanked Dart [text] whose
/// title is exactly [title].
List<String> _testBodies(String text, String title) {
  final String quoted = RegExp.escape(title.replaceAll("'", r"\'"));
  final opening = RegExp(r'\btest\(\s*\x27' + quoted + r'\x27');
  final bodies = <String>[];
  for (final RegExpMatch match in opening.allMatches(text)) {
    final int open = text.indexOf('(', match.start);
    final int? close = _closingParen(text, open);
    if (close != null) bodies.add(text.substring(open, close + 1));
  }
  return bodies;
}

/// The `expect` / `expectLater` calls in [body] whose matcher is anything but
/// `returnsNormally`: the ones that can fail on a wrong answer rather than
/// only on an exception.
List<String> _concreteAssertions(String body) {
  final onlyReturnsNormally = RegExp(r'returnsNormally\s*,?\s*\)$');
  final concrete = <String>[];
  for (final RegExpMatch match in RegExp(
    r'\bexpect(?:Later)?\(',
  ).allMatches(body)) {
    final int open = match.end - 1;
    final int? close = _closingParen(body, open);
    if (close == null) continue;
    final String call = body.substring(open, close + 1);
    if (!onlyReturnsNormally.hasMatch(call)) concrete.add(call);
  }
  return concrete;
}

/// Registers the checks on `flutter/tests/**/*_test.bzl` and its helper.
void _suiteChecks(Map<String, String> files) {
  final suiteFiles = <String>[
    for (final String path in files.keys)
      if (path.startsWith('flutter/tests/') && path.endsWith('_test.bzl')) path,
  ];
  String code(String path, {bool blankStrings = true}) => _blank(
    files[path] ?? '',
    _Lang.starlark,
    blankStrings: blankStrings,
  );
  final bare = RegExp(r'(?<![\w.])unittest\.suite\(');
  final helper = RegExp(r'(?<!\w)small_unittest_suite\(');
  final binding = RegExp(r'partial\.make\([^()]*\bsize\s*=\s*"small"');

  test('no suite file calls unittest.suite directly', () {
    final offenders = <String>[
      for (final String path in suiteFiles)
        if (bare.hasMatch(code(path))) path,
    ];
    expect(offenders, isEmpty);
  });
  test('small_unittest_suite replaces every unittest.suite call', () {
    final int calls = suiteFiles.fold<int>(
      0,
      (int sum, String path) => sum + helper.allMatches(code(path)).length,
    );
    expect(calls, greaterThanOrEqualTo(_baseSuiteCalls));
  });
  test('only the helper binds size = "small" to suite members', () {
    final binders = <String>[
      for (final String path in suiteFiles)
        if (binding.hasMatch(code(path, blankStrings: false))) path,
    ];
    expect(binders, isEmpty);
    expect(binding.hasMatch(code(_suiteHelper, blankStrings: false)), isTrue);
    expect(bare.hasMatch(code(_suiteHelper)), isTrue);
  });
}

/// Registers one size-count check per BUILD file in [_minimumSizes].
void _sizeChecks(Map<String, String> files) {
  final declared = RegExp(r'\bsize\s*=\s*"(?:small|medium|large)"');
  for (final MapEntry<String, int> entry in _minimumSizes.entries) {
    test('${entry.key} declares at least ${entry.value} explicit sizes', () {
      final String code = _blank(
        files[entry.key] ?? '',
        _Lang.starlark,
        blankStrings: false,
      );
      expect(
        declared.allMatches(code),
        hasLength(greaterThanOrEqualTo(entry.value)),
      );
    });
  }
}

/// Registers one assertion-strength check per case in [_strengthenedCases],
/// and the declarative-skip check for the macOS-only case.
void _caseChecks(Map<String, String> files) {
  for (final _Case weak in _strengthenedCases) {
    test('${weak.path}: "${weak.title}" asserts a concrete post-condition', () {
      final String code = _blank(
        files[weak.path] ?? '',
        _Lang.dart,
        blankStrings: false,
      );
      final List<String> bodies = _testBodies(code, weak.title);
      expect(bodies, isNotEmpty, reason: 'the case must still exist');
      for (final body in bodies) {
        expect(_concreteAssertions(body), isNotEmpty);
      }
    });
  }
  test('$_appliedVersions skips declaratively on other platforms', () {
    final String code = _blank(
      files[_appliedVersions] ?? '',
      _Lang.dart,
      blankStrings: false,
    );
    expect(RegExp(r'if\s*\(\s*!\s*Platform\.').hasMatch(code), isFalse);
    expect(
      RegExp(r'skip:\s*Platform\.isMacOS\s*\?\s*null\s*:').hasMatch(code) ||
          RegExp(r'testOn:\s*\x27mac-os\x27').hasMatch(code),
      isTrue,
    );
  });
}

/// Registers the check that every file the other checks read was found.
void _sanityCheck(Map<String, String> files) {
  test('every guarded file was read', () {
    final Set<String> builds = _minimumSizes.keys.toSet();
    final dartFiles = <String>{
      for (final _Case weak in _strengthenedCases) weak.path,
    };
    expect(files.keys.toSet().containsAll(builds), isTrue);
    expect(files.keys.toSet().containsAll(dartFiles), isTrue);
    expect(builds, hasLength(29));
    expect(dartFiles, hasLength(17));
    final int suites = files.keys
        .where((String p) => p.startsWith('flutter/tests/'))
        .length;
    expect(suites, greaterThanOrEqualTo(51));
    expect(files.length, greaterThanOrEqualTo(79 + 17));
  });
}

void main() {
  final String? root = _findRoot();
  if (root == null) {
    test('the workspace root is discoverable', () {
      fail(
        'cannot find the rules_flutter workspace root; run this test '
        'unsandboxed through bazel test //flutter/tests/test_size_guard/...',
      );
    });
    return;
  }
  final Map<String, String> files = _readWorkspace(root);
  _suiteChecks(files);
  _sizeChecks(files);
  _caseChecks(files);
  _sanityCheck(files);
}
