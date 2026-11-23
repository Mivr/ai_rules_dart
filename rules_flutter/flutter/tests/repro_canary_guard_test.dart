/// Static guard test for Gate 07 reproducibility canary and its CI job.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Finds the rules_flutter repository root directory.
String _locateRepoRoot() {
  final String? buildDir = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (buildDir != null && buildDir.isNotEmpty && _hasRepoMarkers(buildDir)) {
    return buildDir;
  }
  final String? anchor = Platform.environment['GUARD_ROOT_ANCHOR'];
  final String? srcdir = Platform.environment['TEST_SRCDIR'];
  if (anchor != null && anchor.isNotEmpty && srcdir != null) {
    try {
      Directory candidate = File(
        File('$srcdir/$anchor').resolveSymbolicLinksSync(),
      ).parent;
      for (var depth = 0; depth < 8; depth++) {
        if (_hasRepoMarkers(candidate.path)) {
          return candidate.path;
        }
        candidate = candidate.parent;
      }
    } on FileSystemException {
      // Fall through to Directory.current resolution below.
    }
  }
  Directory currentDir = Directory.current;
  for (var depth = 0; depth < 8; depth++) {
    if (_hasRepoMarkers(currentDir.path)) {
      return currentDir.path;
    }
    currentDir = currentDir.parent;
  }
  throw StateError('Failed to discover rules_flutter repository root');
}

/// Returns true if [path] looks like the repository root.
bool _hasRepoMarkers(String path) =>
    File('$path/MODULE.bazel').existsSync() &&
    Directory('$path/flutter').existsSync() &&
    Directory('$path/e2e').existsSync();

/// Strips `#` comments line by line from YAML text.
String _stripYamlComments(String text) =>
    text.split('\n').map((line) => line.split('#').first).join('\n');

/// Strips `#` comments outside string literals from Starlark text.
String _stripStarlarkComments(String text) {
  final out = StringBuffer();
  String? quote;
  for (var i = 0; i < text.length; i++) {
    final String ch = text[i];
    if (quote != null) {
      out.write(ch);
      if (ch == r'\' && i + 1 < text.length) {
        out.write(text[++i]);
      } else if (ch == quote) {
        quote = null;
      }
      continue;
    }
    if (ch == '#') {
      while (i < text.length && text[i] != '\n') {
        i++;
      }
      if (i < text.length) {
        out.write('\n');
      }
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
    }
    out.write(ch);
  }
  return out.toString();
}

/// Extracts the block corresponding to two-space-indented [jobName] in [yaml].
String _extractJobBlock(String yaml, String jobName) {
  final header = '\n  $jobName:\n';
  final int start = yaml.indexOf(header);
  expect(
    start,
    isNot(-1),
    reason: 'Job $jobName not found at two-space indentation in YAML',
  );
  final int bodyStart = start + header.length;
  final nextJobRegex = RegExp(r'\n  [a-zA-Z0-9_-]+:\n');
  final RegExpMatch? nextJobMatch = nextJobRegex.firstMatch(
    yaml.substring(bodyStart),
  );
  if (nextJobMatch == null) {
    return yaml.substring(bodyStart);
  }
  return yaml.substring(bodyStart, bodyStart + nextJobMatch.start);
}

void _verifyCanaryFixture(String root) {
  final buildFile = File('$root/e2e/repro_canary/BUILD.bazel');
  final moduleFile = File('$root/e2e/repro_canary/MODULE.bazel');
  final nondetFile = File('$root/e2e/repro_canary/nondet.bzl');
  final bazelVersionFile = File('$root/e2e/repro_canary/.bazelversion');
  final lockFile = File('$root/e2e/repro_canary/MODULE.bazel.lock');

  expect(buildFile.existsSync(), isTrue, reason: 'BUILD.bazel must exist');
  expect(
    _stripStarlarkComments(buildFile.readAsStringSync()).trim(),
    isNotEmpty,
    reason: 'BUILD.bazel must not be empty',
  );

  expect(moduleFile.existsSync(), isTrue, reason: 'MODULE.bazel must exist');
  expect(nondetFile.existsSync(), isTrue, reason: 'nondet.bzl must exist');

  expect(
    bazelVersionFile.existsSync(),
    isTrue,
    reason: '.bazelversion must exist',
  );
  expect(
    bazelVersionFile.readAsStringSync().trim(),
    equals('9.3.0'),
    reason: '.bazelversion must contain 9.3.0',
  );

  expect(
    lockFile.existsSync(),
    isTrue,
    reason: 'MODULE.bazel.lock must exist',
  );
  expect(
    lockFile.readAsStringSync().trim(),
    isNotEmpty,
    reason: 'MODULE.bazel.lock must not be empty',
  );

  final String nondetCode = _stripStarlarkComments(
    nondetFile.readAsStringSync(),
  );
  expect(
    nondetCode.contains('/dev/urandom'),
    isTrue,
    reason: 'nondet.bzl must declare an action reading /dev/urandom',
  );
  expect(
    RegExp(r'\brule\s*\(').hasMatch(nondetCode),
    isTrue,
    reason: 'nondet.bzl must declare a rule',
  );
  expect(
    RegExp(r'\bactions\.run\s*\(').hasMatch(nondetCode),
    isTrue,
    reason: 'nondet.bzl must run an action reading /dev/urandom',
  );
}

void _verifyReproducibilityJob(String root) {
  final ciFile = File('$root/.github/workflows/ci.yaml');
  expect(ciFile.existsSync(), isTrue, reason: 'ci.yaml must exist');
  final String rawCi = ciFile.readAsStringSync();
  final String rawJobBlock = _extractJobBlock(rawCi, 'reproducibility');
  final String jobBlock = _stripYamlComments(rawJobBlock);

  expect(
    jobBlock.contains('e2e/repro_canary'),
    isTrue,
    reason: 'reproducibility job block must name e2e/repro_canary',
  );

  final Set<String?> outputBaseMatches = RegExp(
    r"""--output_base=([^\s"'`]+)""",
  ).allMatches(jobBlock).map((m) => m.group(1)).toSet();
  expect(
    outputBaseMatches.length,
    greaterThanOrEqualTo(2),
    reason: 'reproducibility job must contain at least two distinct --output_base= values',
  );

  expect(
    rawJobBlock.contains('gates'),
    isFalse,
    reason: 'reproducibility job block must contain no "gates"',
  );
}

void _verifyConclusionNeeds(String root) {
  final String ciContent = _stripYamlComments(
    File('$root/.github/workflows/ci.yaml').readAsStringSync(),
  );
  final String conclusionBlock = _extractJobBlock(ciContent, 'conclusion');

  final RegExpMatch? needsMatch = RegExp(
    r'needs:\s*\[([^\]]+)\]',
  ).firstMatch(conclusionBlock);
  expect(
    needsMatch,
    isNotNull,
    reason: 'conclusion job must have inline needs: [...] list',
  );

  final List<String> items = needsMatch!
      .group(1)!
      .split(',')
      .map((s) => s.trim())
      .toList();
  expect(
    items.contains('reproducibility'),
    isTrue,
    reason: 'conclusion job inline needs must contain reproducibility',
  );
}

void _verifyNotExcusedOrSwept(String root) {
  final String coverageContent = File(
    '$root/tools/check_e2e_coverage/coverage.dart',
  ).readAsStringSync();
  expect(
    coverageContent.contains("'e2e/repro_canary'") ||
        coverageContent.contains('"e2e/repro_canary"'),
    isFalse,
    reason: 'coverage.dart uncoveredReasons must not name e2e/repro_canary',
  );

  final workflowsDir = Directory('$root/.github/workflows');
  final Iterable<File> workflowFiles = workflowsDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.yaml') || f.path.endsWith('.yml'));

  final matrixRegex = RegExp(
    r"""workspace:\s*(\[[^\]]*\brepro_canary\b[^\]]*\]|['"]?repro_canary['"]?\b|(\n\s+-\s*['"]?[A-Za-z0-9_-]+['"]?)*\n\s+-\s*['"]?repro_canary['"]?\b)""",
  );
  final workspacesRegex = RegExp(r'WORKSPACES:.*?\brepro_canary\b');

  for (final wf in workflowFiles) {
    final String text = _stripYamlComments(wf.readAsStringSync());
    expect(
      matrixRegex.hasMatch(text),
      isFalse,
      reason:
          '${wf.path} must not name repro_canary in a workspace: matrix entry',
    );
    expect(
      workspacesRegex.hasMatch(text),
      isFalse,
      reason: '${wf.path} must not name repro_canary in a WORKSPACES: list',
    );
  }
}

void main() {
  final String root = _locateRepoRoot();

  test('e2e/repro_canary workspace structure and nondeterministic action', () {
    _verifyCanaryFixture(root);
  });

  test(
    'ci.yaml reproducibility job configuration and distinct output bases',
    () {
      _verifyReproducibilityJob(root);
    },
  );

  test('conclusion job requires reproducibility', () {
    _verifyConclusionNeeds(root);
  });

  test(
    'repro_canary is not excused in coverage or in positive workflow sweeps',
    () {
      _verifyNotExcusedOrSwept(root);
    },
  );
}
