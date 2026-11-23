import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Guard for gates 06 and 11 (test strength): a test target declares the
/// budget it needs instead of relying on Bazel's implicit `medium`, and a
/// platform skip is declarative so JUnit XML reports it skipped rather than
/// passed.
///
/// It checks, from the live source tree:
///  * each named target declares an explicit `size` of small, medium or
///    large, and the network-bound dual-build target is not `small` and
///    still carries `requires-network`;
///  * `app_jit_snapshot_test.dart` has no `if (Platform.…) return;` early
///    return, and its three formerly early-returning cases declare `skip:`
///    or `testOn:`.
///
/// The workspace root comes from a runfiles-resolved anchor (this test's own
/// source, passed as an `rlocationpath` argument and declared in `data`).
void main(List<String> args) {
  final String root = _workspaceRoot(args);

  test('the BUILD files and the test source are found', () {
    for (final _Target target in _targets) {
      expect(
        File('$root/${target.buildFile}').existsSync(),
        isTrue,
        reason: '${target.buildFile} must exist',
      );
      expect(
        _block(
          File('$root/${target.buildFile}').readAsStringSync(),
          target.name,
        ),
        isNotNull,
        reason: '${target.buildFile} must declare ${target.name}',
      );
    }
    expect(File('$root/$_appJitTest').existsSync(), isTrue);
  });

  for (final _Target target in _targets) {
    test('${target.buildFile}:${target.name} declares an explicit size', () {
      final String? block = _block(
        File('$root/${target.buildFile}').readAsStringSync(),
        target.name,
      );
      expect(_size(block!), isIn(['small', 'medium', 'large']));
    });
  }

  test('run_build_runner_test is not small and keeps requires-network', () {
    final String block = _block(
      File('$root/e2e/dual_build/BUILD.bazel').readAsStringSync(),
      'run_build_runner_test',
    )!;
    expect(_size(block), isIn(['medium', 'large']));
    expect(block, contains('"requires-network"'));
  });

  test('app_jit_snapshot_test.dart has no early-return platform skip', () {
    final String text = File('$root/$_appJitTest').readAsStringSync();
    expect(_earlyReturn.allMatches(text).map((m) => m.group(0)), isEmpty);
  });

  for (final String name in _skippedCases) {
    test('"$name" declares skip: or testOn:', () {
      final String text = File('$root/$_appJitTest').readAsStringSync();
      final String? body = _testDeclaration(text, name);
      expect(body, isNotNull, reason: 'the case must still exist');
      expect(body, matches(RegExp(r'\b(skip|testOn):')));
    });
  }

  group('checker unit tests', () {
    test('a block without a size has none', () {
      const build = 'dart_test(\n    name = "t",\n    main = "t.dart",\n)\n';
      expect(_size(_block(build, 't')!), isNull);
    });

    test('a block with a size reports it, and neighbours do not leak', () {
      const build =
          'dart_test(\n    name = "a",\n    size = "large",\n)\n\n'
          'dart_test(\n    name = "b",\n)\n';
      expect(_size(_block(build, 'a')!), 'large');
      expect(_size(_block(build, 'b')!), isNull);
      expect(_block(build, 'c'), isNull);
    });

    test('an early return inside a test body is found', () {
      expect(
        _earlyReturn.hasMatch('  if (Platform.isWindows) return;\n'),
        isTrue,
      );
      expect(_earlyReturn.hasMatch('  if (!Platform.isWindows) {\n'), isFalse);
    });

    test('a declaration is cut at the next top-level test', () {
      const src =
          "  test('a', () {\n  });\n\n  test('b', () {\n  }, skip: 'x');\n";
      expect(_testDeclaration(src, 'a'), isNot(contains('skip:')));
      expect(_testDeclaration(src, 'b'), contains('skip:'));
    });
  });
}

const _appJitTest = 'dart/private/tools/app_jit_snapshot_test.dart';

/// A target whose size the guard pins, and the BUILD file declaring it.
typedef _Target = ({String buildFile, String name});

const List<_Target> _targets = [
  (buildFile: 'dart/private/tools/BUILD.bazel', name: 'kernel_launcher_test'),
  (buildFile: 'e2e/dual_build/BUILD.bazel', name: 'run_build_runner_test'),
  (buildFile: 'e2e/run_home/BUILD.bazel', name: 'plain_test'),
  (buildFile: 'e2e/run_home/BUILD.bazel', name: 'analysis_test'),
];

/// The cases that once hid a Windows skip behind an early `return;`.
const _longCase =
    '--aot preserves --enable-asserts in exe and aot-snapshot modes with and '
    'without --recorded-uses';

const List<String> _skippedCases = [
  _longCase,
  '--aot leaves scratch TMPDIR empty',
  '--gen-kernel deletes an output whose read set names an undeclared file',
];

/// `if (Platform.isWindows) return;` and its negated or spaced spellings.
final _earlyReturn = RegExp(r'if\s*\(\s*!?\s*Platform\.\w+\s*\)\s*return\s*;');

/// The rule call in [build] whose `name` is [name], from the line opening
/// the call to the closing `)` in column 0, or null when absent.
String? _block(String build, String name) {
  final int start = build.indexOf('name = "$name",');
  if (start == -1) return null;
  final int open = build.lastIndexOf(RegExp(r'^\w+\(', multiLine: true), start);
  final int close = build.indexOf(RegExp(r'^\)', multiLine: true), start);
  if (open == -1 || close == -1) return null;
  return build.substring(open, close + 1);
}

/// The `size = "…"` value declared directly in a rule block, or null.
String? _size(String block) =>
    RegExp(r'^\s+size = "(\w+)",', multiLine: true).firstMatch(block)?.group(1);

/// Source of the top-level `test(` declaration titled [title], up to the
/// next two-space-indented `test(` (or the end of the file), or null.
String? _testDeclaration(String text, String title) {
  final int at = text.indexOf(title);
  if (at == -1) return null;
  final int next = text.indexOf(RegExp(r'^  test\(', multiLine: true), at);
  return text.substring(at, next == -1 ? text.length : next);
}

/// The workspace root: the anchor is this file inside
/// `dart/tests/test_strength_guard/`, resolved through any symlink into the
/// real source tree, so the root is three directories above its package. A direct
/// `dart test` run passes no argument and uses the current directory.
String _workspaceRoot(List<String> args) {
  var anchor = '${Directory.current.path}/test_strength_guard_test.dart';
  if (args.isNotEmpty) {
    final String located = Runfiles.create().rlocation(args.first);
    if (File(located).existsSync()) anchor = located;
  }
  Directory dir = File(File(anchor).resolveSymbolicLinksSync()).parent;
  for (var i = 0; i < 3; i++) {
    dir = dir.parent;
  }
  return dir.path;
}
