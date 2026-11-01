import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Representation of a named cell in the format-hermeticity matrix.
typedef MatrixCell = ({String flags, String name});

/// The eight required execution cells across runfiles and sandboxing modes.
const List<MatrixCell> _expectedCells = [
  (name: 'forest runfiles, unsandboxed worker', flags: ''),
  (name: 'forest runfiles, standalone', flags: '--spawn_strategy=standalone'),
  (name: 'forest runfiles, worker-sandboxed', flags: '--worker_sandboxing'),
  (
    name: 'forest runfiles, analyze sandboxed',
    flags: '--strategy=DartAnalyze=sandboxed',
  ),
  (name: 'manifest runfiles, unsandboxed worker', flags: '--noenable_runfiles'),
  (
    name: 'manifest runfiles, standalone',
    flags: '--noenable_runfiles --spawn_strategy=standalone',
  ),
  (
    name: 'manifest runfiles, worker-sandboxed',
    flags: '--noenable_runfiles --worker_sandboxing',
  ),
  (
    name: 'manifest runfiles, analyze sandboxed',
    flags: '--noenable_runfiles --strategy=DartAnalyze=sandboxed',
  ),
];

void main(List<String> args) {
  group('format-hermeticity sandbox cells guard', () {
    late final String rootDir;
    late final String jobBlock;

    setUpAll(() {
      rootDir = _resolveWorkspaceRoot(args);
      final workflowFile = File('$rootDir/.github/workflows/ci.yaml');
      expect(
        workflowFile.existsSync(),
        isTrue,
        reason: '.github/workflows/ci.yaml must exist',
      );
      jobBlock = _extractFormatHermeticityBlock(
        workflowFile.readAsStringSync(),
      );
    });

    test('matrix has exactly the eight required cells with no duplicates', () {
      final List<MatrixCell> cells = _parseMatrixCells(jobBlock);
      expect(
        cells.length,
        equals(8),
        reason: 'format-hermeticity matrix must have exactly 8 cells',
      );
      final Set<MatrixCell> uniqueCells = cells.toSet();
      expect(
        uniqueCells.length,
        equals(8),
        reason: 'format-hermeticity matrix must contain no duplicate entries',
      );
      expect(
        uniqueCells,
        equals(_expectedCells.toSet()),
        reason: 'format-hermeticity matrix entries must match expected pairs',
      );
    });

    test('the two unsandboxed worker cells carry neither sandboxing flag', () {
      final List<MatrixCell> cells = _parseMatrixCells(jobBlock);
      final List<MatrixCell> unsandboxed = cells
          .where((MatrixCell cell) => cell.name.endsWith('unsandboxed worker'))
          .toList();
      expect(
        unsandboxed.length,
        equals(2),
        reason: 'expected exactly 2 unsandboxed worker cells',
      );
      for (final cell in unsandboxed) {
        expect(
          cell.flags.contains('--worker_sandboxing'),
          isFalse,
          reason: '${cell.name} must not specify --worker_sandboxing',
        );
        expect(
          cell.flags.contains('--strategy=DartAnalyze=sandboxed'),
          isFalse,
          reason:
              '${cell.name} must not specify --strategy=DartAnalyze=sandboxed',
        );
        expect(
          cell.flags.contains('sandboxed'),
          isFalse,
          reason: '${cell.name} must not specify any sandboxed flag',
        );
      }
    });

    test('both steps run analysis workspaces and neither carries continue-on-error', () {
      _verifyExecutionSteps(jobBlock);
    });
  });
}

/// Locates and extracts the `format-hermeticity:` job block up to the next job.
String _extractFormatHermeticityBlock(String yaml) {
  final RegExpMatch? start = RegExp(
    r'^  format-hermeticity:\s*$',
    multiLine: true,
  ).firstMatch(yaml);
  if (start == null) {
    fail('ci.yaml must define a two-space indented format-hermeticity: job');
  }

  final int from = start.start;
  final Iterable<RegExpMatch> nextJobs = RegExp(
    r'^  [a-zA-Z0-9_-]+:\s*$',
    multiLine: true,
  ).allMatches(yaml).where((RegExpMatch m) => m.start > from);

  final int to = nextJobs.isNotEmpty ? nextJobs.first.start : yaml.length;
  return yaml.substring(from, to);
}

/// Parses the list of matrix include cells from the job block.
List<MatrixCell> _parseMatrixCells(String block) {
  final RegExpMatch? stepsMatch = RegExp(
    r'^\s*steps:\s*$',
    multiLine: true,
  ).firstMatch(block);
  final String matrixSection = stepsMatch != null
      ? block.substring(0, stepsMatch.start)
      : block;

  final RegExpMatch? includeMatch = RegExp(
    r'^\s*include:\s*$',
    multiLine: true,
  ).firstMatch(matrixSection);
  if (includeMatch == null) {
    fail('format-hermeticity job does not define matrix include: section');
  }

  final String textAfterInclude = matrixSection.substring(includeMatch.end);
  final List<RegExpMatch> itemSplits = RegExp(
    r'^\s*-\s+',
    multiLine: true,
  ).allMatches(textAfterInclude).toList();
  final List<MatrixCell> cells = [];

  for (var i = 0; i < itemSplits.length; i++) {
    final int start = itemSplits[i].start;
    final int end = (i + 1 < itemSplits.length)
        ? itemSplits[i + 1].start
        : textAfterInclude.length;
    final String chunk = textAfterInclude.substring(start, end);

    final RegExpMatch? nameMatch = RegExp(
      r'^\s*(?:-\s+)?name:\s*(.*?)\s*$',
      multiLine: true,
    ).firstMatch(chunk);
    final RegExpMatch? flagsMatch = RegExp(
      r'^\s*(?:-\s+)?flags:\s*(.*?)\s*$',
      multiLine: true,
    ).firstMatch(chunk);

    if (nameMatch == null || flagsMatch == null) {
      fail('Matrix include entry missing name or flags: $chunk');
    }

    cells.add((
      name: _stripQuotes(nameMatch.group(1)!),
      flags: _stripQuotes(flagsMatch.group(1)!),
    ));
  }
  return cells;
}

/// Strips outer single or double quotes if present.
String _stripQuotes(String value) {
  final String trimmed = value.trim();
  if ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
      (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}

/// Validates that both analysis steps are present and continue-on-error is absent.
void _verifyExecutionSteps(String block) {
  final RegExpMatch? stepsMatch = RegExp(
    r'^\s*steps:\s*$',
    multiLine: true,
  ).firstMatch(block);
  if (stepsMatch == null) {
    fail('format-hermeticity job does not declare steps');
  }
  final String stepsBlock = block.substring(stepsMatch.start);

  expect(
    stepsBlock.contains('continue-on-error'),
    isFalse,
    reason: 'format-hermeticity steps must not declare continue-on-error',
  );

  final bool hasAnalysisStep = RegExp(r'working-directory:\s*e2e/analysis\b')
      .hasMatch(stepsBlock);
  expect(
    hasAnalysisStep,
    isTrue,
    reason: 'format-hermeticity must contain a step running in e2e/analysis',
  );

  final bool hasAnalysisFailureStep = RegExp(
    r'working-directory:\s*e2e/analysis_failure\b',
  ).hasMatch(stepsBlock);
  expect(
    hasAnalysisFailureStep,
    isTrue,
    reason: 'format-hermeticity must contain a step running in e2e/analysis_failure',
  );
}

/// Resolves the repository root directory from the runfiles anchor or environment.
String _resolveWorkspaceRoot(List<String> args) {
  if (args.isNotEmpty) {
    try {
      final String runfilesPath = Runfiles.create().rlocation(args.first);
      final anchorFile = File(runfilesPath);
      if (anchorFile.existsSync()) {
        final String realPath = anchorFile.resolveSymbolicLinksSync();
        Directory cursor = Directory(realPath).parent;
        while (cursor.path != cursor.parent.path) {
          if (File('${cursor.path}/MODULE.bazel').existsSync() &&
              Directory('${cursor.path}/dart').existsSync()) {
            return cursor.path;
          }
          cursor = cursor.parent;
        }
      }
    } on Object catch (_) {
      // Runfiles anchor resolution failed; fall back to environment check below.
    }
  }

  for (final varName in [
    'BUILD_WORKSPACE_DIRECTORY',
    'BUILD_WORKING_DIRECTORY',
  ]) {
    final String? candidate = Platform.environment[varName];
    if (candidate != null && Directory(candidate).existsSync()) {
      return candidate;
    }
  }

  return Directory.current.path;
}
