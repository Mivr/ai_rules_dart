/// Repo guard: the `Unit tests` job in `.github/workflows/ci.yaml` must rerun
/// the `tree-reader` tests uncached.
///
/// Tests tagged `tree-reader` read the checkout through runfiles-to-tree
/// walks that Bazel cannot see, so the cached root unit-test step can replay
/// a stale PASS. A later step of the same job must run
/// `bazel test ... --test_tag_filters=tree-reader --nocache_test_results`.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Whether [root] is the rules_flutter workspace root.
bool _looksLikeRoot(String root) =>
    Directory('$root/flutter').existsSync() &&
    File('$root/MODULE.bazel').existsSync();

/// Resolves the rules_flutter workspace root directory.
String? _workspaceRoot() {
  final String? fromEnv = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (fromEnv != null && fromEnv.isNotEmpty && _looksLikeRoot(fromEnv)) {
    return fromEnv;
  }
  final String? anchor = Platform.environment['GUARD_ROOT_ANCHOR'];
  final String? srcdir = Platform.environment['TEST_SRCDIR'];
  if (anchor != null && anchor.isNotEmpty && srcdir != null) {
    try {
      Directory dir = File(
        File('$srcdir/$anchor').resolveSymbolicLinksSync(),
      ).parent;
      for (var i = 0; i < 8; i++) {
        if (_looksLikeRoot(dir.path)) return dir.path;
        dir = dir.parent;
      }
    } on FileSystemException {
      // Fall through to the working-directory search when the anchor fails.
    }
  }
  Directory dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (_looksLikeRoot(dir.path)) return dir.path;
    dir = dir.parent;
  }
  return null;
}

/// Returns the lines of the job named `Unit tests` in [workflow], or null.
List<String>? _unitTestsJob(String workflow) {
  final List<String> lines = workflow.split('\n');
  final int nameIdx = lines.indexWhere(
    (l) => RegExp(r'^    name:\s*Unit tests\s*$').hasMatch(l),
  );
  if (nameIdx < 1) return null;
  int start = nameIdx - 1;
  while (start > 0 && !RegExp(r'^  [^\s#]').hasMatch(lines[start])) {
    start--;
  }
  int end = nameIdx + 1;
  while (end < lines.length && !RegExp(r'^  [^\s#]').hasMatch(lines[end])) {
    end++;
  }
  return lines.sublist(start, end);
}

/// Splits [job] into its steps, each a list of lines.
List<List<String>> _steps(List<String> job) {
  final steps = <List<String>>[];
  for (final line in job) {
    if (RegExp('^      - ').hasMatch(line)) {
      steps.add(<String>[line]);
    } else if (steps.isNotEmpty) {
      steps.last.add(line);
    }
  }
  return steps;
}

/// The step text without comment-only lines, with continuations joined.
String _code(List<String> step) => step
    .where((l) => !l.trimLeft().startsWith('#'))
    .join('\n')
    .replaceAll(RegExp(r'\\\n\s*'), ' ');

/// Whether [step] is the cached root unit-test step.
bool _isRootStep(List<String> step) => step.first.contains(
  RegExp(r'name:\s*bazel test //\.\.\. \(root unit tests\)'),
);

/// Whether a `bazel test` command in [code] carries both required flags.
bool _isUncachedTreeReaderRun(String code) {
  for (final String line in code.split('\n')) {
    if (!RegExp(r'\bbazel\b.*\btest\b').hasMatch(line)) continue;
    final RegExpMatch? filter = RegExp(
      r'--test_tag_filters=(\S+)',
    ).firstMatch(line);
    if (filter == null) continue;
    final List<String> tags = filter
        .group(1)!
        .replaceAll(RegExp('["\']'), '')
        .split(',');
    final bool uncached = RegExp(
      r'--nocache_test_results(?![=\w-])|--nocache_test_results=(true|1|yes)\b',
    ).hasMatch(line);
    if (tags.contains('tree-reader') && uncached) return true;
  }
  return false;
}

/// Problems with the `Unit tests` job of [workflow]; empty when it is fine.
List<String> validateWorkflow(String workflow) {
  final List<String>? job = _unitTestsJob(workflow);
  if (job == null) return ['ci.yaml has no job named "Unit tests"'];
  final List<List<String>> steps = _steps(job);
  final int rootIdx = steps.indexWhere(_isRootStep);
  if (rootIdx < 0) {
    return ['"Unit tests" lacks the step "bazel test //... (root unit tests)"'];
  }
  for (final List<String> step in steps.skip(rootIdx + 1)) {
    final String code = _code(step);
    if (!_isUncachedTreeReaderRun(code)) continue;
    if (RegExp(r'^\s+if:', multiLine: true).hasMatch(code) ||
        code.contains('continue-on-error')) {
      return ['the uncached tree-reader step must be unconditional and fatal'];
    }
    return [];
  }
  const msg =
      '"Unit tests" needs a step after the root unit tests that runs '
      '`bazel test` with --test_tag_filters=tree-reader and '
      '--nocache_test_results';
  return [msg];
}

/// [workflow] with every step that reruns tree readers uncached removed.
String withoutTreeReaderStep(String workflow) {
  final List<String> job = _unitTestsJob(workflow)!;
  final List<List<String>> steps = _steps(job);
  final drop = <String>{};
  for (final step in steps) {
    if (_isUncachedTreeReaderRun(_code(step))) drop.addAll(step);
  }
  final String edited = job.where((l) => !drop.contains(l)).join('\n');
  return workflow.replaceFirst(job.join('\n'), edited);
}

void main() {
  final String? root = _workspaceRoot();
  if (root == null) {
    test('workspace root discovery', () {
      fail(
        'Could not locate rules_flutter workspace root; ensure '
        'GUARD_ROOT_ANCHOR or BUILD_WORKSPACE_DIRECTORY is set.',
      );
    });
    return;
  }
  final workflowFile = File('$root/.github/workflows/ci.yaml');

  test('Unit tests job reruns tree-reader tests uncached', () {
    expect(workflowFile.existsSync(), isTrue);
    final List<String> errors = validateWorkflow(
      workflowFile.readAsStringSync(),
    );
    expect(errors, isEmpty, reason: errors.join('\n'));
  });

  test('negative: a workflow without the step is rejected', () {
    final String text = workflowFile.readAsStringSync();
    final String edited = withoutTreeReaderStep(text);
    expect(edited, isNot(equals(text)), reason: 'edit removed nothing');
    expect(validateWorkflow(edited), isNotEmpty);
  });

  test('negative: a cached or conditional step is rejected', () {
    const base =
        '  unit-tests:\n    name: Unit tests\n    steps:\n'
        '      - name: bazel test //... (root unit tests)\n'
        '        run: bazel test //... --test_output=errors\n';
    const step = '      - name: x\n';
    const tr = 'bazel test //... --test_tag_filters=tree-reader';
    expect(validateWorkflow('$base$step        run: $tr\n'), isNotEmpty);
    expect(
      validateWorkflow(
        '$base      - name: x\n        if: always()\n'
        '        run: bazel test //... --test_tag_filters=tree-reader '
        '--nocache_test_results\n',
      ),
      isNotEmpty,
    );
    expect(
      validateWorkflow(
        '$base      - name: x\n'
        '        run: bazel test //... --test_tag_filters=-tree-reader '
        '--nocache_test_results\n',
      ),
      isNotEmpty,
    );
    expect(
      validateWorkflow(
        '$base      - name: x\n'
        '        run: bazel test //... --test_tag_filters=tree-reader,-manual '
        '--nocache_test_results\n',
      ),
      isEmpty,
    );
  });
}
