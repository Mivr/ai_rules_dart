import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

typedef _MatrixCell = ({String flags, String name});

const List<_MatrixCell> _expectedCells = [
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

/// Entry point for the `format-hermeticity` sandbox cells repository guard.
void main(List<String> args) {
  group('format-hermeticity sandbox cells guard', () {
    late final String jobBlock;

    setUpAll(() {
      final String rootDir = _resolveWorkspaceRoot(args);
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

    test(
      'matrix has exactly the eight required cells with no duplicates',
      () => _verifyMatrixCells(jobBlock),
    );

    test(
      'the two unsandboxed worker cells carry neither sandboxing flag',
      () => _verifySandboxModes(jobBlock),
    );

    test(
      'both steps run analysis workspaces without continue-on-error',
      () => _verifyExecutionSteps(jobBlock),
    );
  });

  group('guard parser unit tests', () {
    test(
      'rejects base matrix, extra cell keys, and commented or foreign flags',
      _verifyMatrixRejections,
    );

    test(
      'rejects continue-on-error and missing workspace steps',
      _verifyStepRejections,
    );
  });
}

void _verifyMatrixCells(String jobBlock) {
  final String cleaned = _stripCommentLines(jobBlock);
  final String header = cleaned
      .split(RegExp(r'^    steps:\s*$', multiLine: true))
      .first;
  expect(
    RegExp(r'^    name\s*:', multiLine: true).hasMatch(header),
    isFalse,
    reason: 'format-hermeticity must not override matrix display names via job name:',
  );

  final List<_MatrixCell> cells = _parseMatrixCells(jobBlock);
  expect(
    cells,
    hasLength(8),
    reason: 'format-hermeticity matrix must have exactly 8 cells',
  );
  final Set<_MatrixCell> uniqueCells = cells.toSet();
  expect(
    uniqueCells,
    hasLength(8),
    reason: 'format-hermeticity matrix must contain no duplicate (name, flags) pairs',
  );
  expect(
    uniqueCells,
    equals(_expectedCells.toSet()),
    reason: 'format-hermeticity matrix entries must match expected (name, flags) pairs',
  );
}

void _verifySandboxModes(String jobBlock) {
  final List<_MatrixCell> cells = _parseMatrixCells(jobBlock);
  final List<_MatrixCell> unsandboxed = cells
      .where((cell) => cell.name.endsWith('unsandboxed worker'))
      .toList();
  expect(
    unsandboxed,
    hasLength(2),
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
      reason: '${cell.name} must not specify --strategy=DartAnalyze=sandboxed',
    );
    expect(
      cell.flags.contains('sandboxed'),
      isFalse,
      reason: '${cell.name} must not specify any sandboxed flag',
    );
  }

  final List<_MatrixCell> sandboxed = cells
      .where((cell) => cell.name.endsWith('sandboxed'))
      .toList();
  expect(sandboxed, hasLength(4));
  for (final cell in sandboxed) {
    expect(
      cell.flags.contains('--spawn_strategy=standalone'),
      isFalse,
      reason: '${cell.name} must not add --spawn_strategy=standalone',
    );
  }
}

String _extractFormatHermeticityBlock(String yaml) {
  final String normalized = yaml.replaceAll('\r\n', '\n');
  final RegExpMatch? start = RegExp(
    r'^  format-hermeticity:\s*(?:#.*)?$',
    multiLine: true,
  ).firstMatch(normalized);
  if (start == null) {
    fail('ci.yaml must define a two-space indented format-hermeticity: job');
  }

  final int from = start.start;
  final Iterable<RegExpMatch> nextBlocks = RegExp(
    r'^ {0,2}[a-zA-Z0-9_-]+:\s*(?:#.*)?$',
    multiLine: true,
  ).allMatches(normalized).where((m) => m.start > from);

  final int to = nextBlocks.isNotEmpty
      ? nextBlocks.first.start
      : normalized.length;
  return normalized.substring(from, to);
}

String _stripCommentLines(String text) {
  return text
      .split('\n')
      .where((line) {
        final String trimmed = line.trimLeft();
        return trimmed.isNotEmpty && !trimmed.startsWith('#');
      })
      .join('\n');
}

List<_MatrixCell> _parseMatrixCells(String block) {
  final String cleaned = _stripCommentLines(block);
  final RegExpMatch? stepsMatch = RegExp(
    r'^    steps:\s*$',
    multiLine: true,
  ).firstMatch(cleaned);
  final String matrixSection = stepsMatch != null
      ? cleaned.substring(0, stepsMatch.start)
      : cleaned;

  final RegExpMatch? includeMatch = RegExp(
    r'^        include:\s*$',
    multiLine: true,
  ).firstMatch(matrixSection);
  if (includeMatch == null) {
    fail('format-hermeticity job does not define matrix include: section');
  }

  final String afterInclude = matrixSection.substring(includeMatch.end);
  final List<RegExpMatch> itemStarts = RegExp(
    r'^          -\s+',
    multiLine: true,
  ).allMatches(afterInclude).toList();
  if (itemStarts.isEmpty) {
    fail('format-hermeticity matrix include: section has no entries');
  }

  return [
    for (var i = 0; i < itemStarts.length; i++)
      _parseSingleCell(
        afterInclude.substring(
          itemStarts[i].start,
          i + 1 < itemStarts.length
              ? itemStarts[i + 1].start
              : afterInclude.length,
        ),
      ),
  ];
}

_MatrixCell _parseSingleCell(String chunk) {
  final fields = <String, String>{};
  for (final String rawLine in chunk.split('\n')) {
    if (rawLine.trim().isEmpty) {
      continue;
    }
    final String stripped = rawLine.trimLeft().replaceFirst(
      RegExp(r'^-\s+'),
      '',
    );
    final RegExpMatch? kv = RegExp(r'^([a-zA-Z0-9_-]+):\s*(.*?)\s*$')
        .firstMatch(stripped);
    if (kv == null) {
      fail('Malformed matrix include line: $rawLine');
    }
    final String key = kv.group(1)!;
    if (fields.containsKey(key)) {
      fail('Duplicate key "$key" in matrix cell: $chunk');
    }
    fields[key] = _stripQuotes(kv.group(2)!);
  }
  expect(
    fields.keys.toSet(),
    equals({'name', 'flags'}),
    reason:
        'Each matrix cell must declare only name and flags, found: ${fields.keys.toList()}',
  );
  return (name: fields['name']!, flags: fields['flags']!);
}

String _stripQuotes(String value) {
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

void _verifyExecutionSteps(String block) {
  final String cleaned = _stripCommentLines(block);
  expect(
    cleaned.contains('continue-on-error'),
    isFalse,
    reason: 'format-hermeticity must not declare continue-on-error',
  );

  final Map<String, String> workspaceSteps = _collectWorkspaceSteps(cleaned);
  expect(
    workspaceSteps.keys.toSet(),
    equals({'e2e/analysis', 'e2e/analysis_failure'}),
    reason: 'format-hermeticity must run exactly e2e/analysis and e2e/analysis_failure',
  );
  expect(
    workspaceSteps['e2e/analysis'],
    allOf(
      contains('bazel'),
      contains(r'${{ matrix.flags }}'),
      contains('//...'),
    ),
  );
  expect(
    workspaceSteps['e2e/analysis_failure'],
    allOf(
      contains('bazel'),
      contains(r'${{ matrix.flags }}'),
      contains('//:clean_lib'),
    ),
  );
}

Map<String, String> _collectWorkspaceSteps(String cleanedBlock) {
  final RegExpMatch? stepsMatch = RegExp(
    r'^    steps:\s*$',
    multiLine: true,
  ).firstMatch(cleanedBlock);
  if (stepsMatch == null) {
    fail('format-hermeticity job does not declare steps');
  }

  final String stepsBody = cleanedBlock.substring(stepsMatch.end);
  final List<RegExpMatch> stepStarts = RegExp(
    r'^      -\s+',
    multiLine: true,
  ).allMatches(stepsBody).toList();
  final workspaceSteps = <String, String>{};

  for (var i = 0; i < stepStarts.length; i++) {
    final String stepChunk = stepsBody.substring(
      stepStarts[i].start,
      i + 1 < stepStarts.length ? stepStarts[i + 1].start : stepsBody.length,
    );
    expect(
      stepChunk.contains('|| true'),
      isFalse,
      reason: 'format-hermeticity step must not swallow failures with || true',
    );
    final RegExpMatch? wdMatch = RegExp(
      r'^\s*working-directory:\s*(\S+)\s*$',
      multiLine: true,
    ).firstMatch(stepChunk);
    if (wdMatch != null) {
      final String wd = _stripQuotes(wdMatch.group(1)!);
      expect(
        workspaceSteps.containsKey(wd),
        isFalse,
        reason: 'format-hermeticity must not duplicate steps for $wd',
      );
      workspaceSteps[wd] = stepChunk;
    }
  }
  return workspaceSteps;
}

void _verifyMatrixRejections() {
  const baseYaml = r'''
jobs:
  format-hermeticity:
    strategy:
      matrix:
        include:
          # --worker_sandboxing --strategy=DartAnalyze=sandboxed
          - name: forest runfiles, sandboxed
            flags: ""
          - name: forest runfiles, local
            flags: "--spawn_strategy=standalone"
          - name: manifest runfiles, sandboxed
            flags: "--noenable_runfiles"
          - name: manifest runfiles, local
            flags: "--noenable_runfiles --spawn_strategy=standalone"
    steps:
      - working-directory: e2e/analysis
        run: bazel test ${{ matrix.flags }} //...
  other-job:
    run: bazel test --worker_sandboxing --strategy=DartAnalyze=sandboxed //...
''';
  final String block = _extractFormatHermeticityBlock(baseYaml);
  expect(block.contains('other-job'), isFalse);
  expect(() => _verifyMatrixCells(block), throwsA(isA<TestFailure>()));

  const extraKeyBlock = '''
  format-hermeticity:
    strategy:
      matrix:
        include:
          - name: forest runfiles, unsandboxed worker
            flags: ""
            compat: "old name"
    steps:
      - uses: actions/checkout@v7
''';
  expect(() => _parseMatrixCells(extraKeyBlock), throwsA(isA<TestFailure>()));
}

void _verifyStepRejections() {
  const continueOnErrorBlock = r'''
  format-hermeticity:
    steps:
      - working-directory: e2e/analysis
        continue-on-error: true
        run: bazel test ${{ matrix.flags }} //...
      - working-directory: e2e/analysis_failure
        run: bazel build ${{ matrix.flags }} //:clean_lib
''';
  expect(
    () => _verifyExecutionSteps(continueOnErrorBlock),
    throwsA(isA<TestFailure>()),
  );
}

String _resolveWorkspaceRoot(List<String> args) {
  if (args.isNotEmpty) {
    try {
      final String located = Runfiles.create().rlocation(args.first);
      final anchor = File(located);
      if (anchor.existsSync()) {
        final String? root = _climbWorkspaceRoot(
          File(anchor.resolveSymbolicLinksSync()).parent,
        );
        if (root != null) {
          return root;
        }
      }
    } on Object catch (_) {
      // Runfiles lookup is unavailable outside Bazel; check environment next.
    }
  }
  for (final varName in [
    'BUILD_WORKSPACE_DIRECTORY',
    'BUILD_WORKING_DIRECTORY',
  ]) {
    final String? candidate = Platform.environment[varName];
    if (candidate != null) {
      final String? root = _climbWorkspaceRoot(Directory(candidate));
      if (root != null) {
        return root;
      }
    }
  }
  return _climbWorkspaceRoot(Directory.current) ?? Directory.current.path;
}

String? _climbWorkspaceRoot(Directory start) {
  var cursor = start;
  while (cursor.path != cursor.parent.path) {
    final moduleFile = File('${cursor.path}/MODULE.bazel');
    if (moduleFile.existsSync()) {
      final String resolvedRoot = File(moduleFile.resolveSymbolicLinksSync())
          .parent
          .path;
      if (Directory('$resolvedRoot/dart').existsSync()) {
        return resolvedRoot;
      }
    }
    cursor = cursor.parent;
  }
  return null;
}
