/// Dart source layout planner and file emitters for generated bench packages.
library;

import 'dart:io';
import 'dart:math';

/// Source density mode selected to match small or large LOC budgets accurately.
enum LayoutMode {
  /// Full class + method bodies (`target_loc` >= ~1065 for 8x4).
  standard,

  /// Single-file compact class/function layout (`target_loc` >= ~367 for 8x4).
  compact,

  /// Inline entry expressions with hook-only `f0.dart` (`target_loc` >= ~188).
  ultraCompact,
}

/// Source-emission plan for a single generated package.
final class PackagePlan {
  /// Creates a package source-emission plan.
  const PackagePlan({
    required this.pkgDir,
    required this.pkgId,
    required this.isLeaf,
    required this.deps,
    required this.srcFilesCount,
    this.inlineSeed = 0,
  });

  /// Directory of the generated package.
  final String pkgDir;

  /// Numeric package identifier (`0 .. layers * fanout - 1`).
  final int pkgId;

  /// Whether this package belongs to the top leaf layer.
  final bool isLeaf;

  /// Lower-layer package IDs imported by this package.
  final List<int> deps;

  /// Number of `lib/src/f<i>.dart` files emitted for this package.
  final int srcFilesCount;

  /// Deterministic inline constant when [srcFilesCount] is zero.
  final int inlineSeed;
}

/// Source-emission plan for a single `lib/src/f<i>.dart` file.
final class SrcFilePlan {
  /// Creates a source-file emission plan.
  const SrcFilePlan({
    required this.pkgPlan,
    required this.fileIndex,
    required this.targetLines,
    required this.seedVal,
    this.ultraCompact = false,
  });

  /// Owning package plan.
  final PackagePlan pkgPlan;

  /// Index within `lib/src/` (`0 .. srcFilesCount - 1`).
  final int fileIndex;

  /// Exact target line count for this file.
  final int targetLines;

  /// Deterministic positive seed offset for method bodies.
  final int seedVal;

  /// Whether to emit the ultra-compact top-level hook form.
  final bool ultraCompact;

  /// Package directory path.
  String get pkgDir => pkgPlan.pkgDir;

  /// Owning package identifier.
  int get pkgId => pkgPlan.pkgId;

  /// Whether this file carries an incremental edit hook.
  bool get hasHook =>
      (pkgId == 0 && fileIndex == 0) || (pkgPlan.isLeaf && fileIndex == 0);

  /// Hook function/method name when [hasHook] is true.
  String get hookName => pkgId == 0 ? 'bodyHook' : 'leafTestHook';

  /// Initial integer literal returned by [hookName].
  int get hookVal => pkgId == 0 ? 1 : 10;
}

int _entryFileLines(int pkgId, int srcCount, int depCount, LayoutMode mode) {
  if (mode == LayoutMode.ultraCompact && pkgId != 0) {
    if (srcCount == 0) return depCount == 0 ? 1 : depCount + 2;
    return depCount == 0 ? 3 : depCount + 4;
  }
  if (mode == LayoutMode.compact && pkgId != 0) {
    return depCount == 0 ? 4 : depCount + 5;
  }
  return depCount == 0 ? 2 * srcCount + 6 : 2 * srcCount + 2 * depCount + 7;
}

int _computeBoilerplateLines({
  required int layers,
  required int fanout,
  required int srcCount,
  required Map<int, List<int>> packageDeps,
  required LayoutMode mode,
}) {
  final totalPackages = layers * fanout;
  final leafStart = (layers - 1) * fanout;
  final appLines = 2 * fanout + 7;
  final leafTestLines = 8 * fanout;
  var entryLinesTotal = 0;
  for (var p = 0; p < totalPackages; p++) {
    final isHookPkg = p == 0 || p >= leafStart;
    final pkgSrcCount = mode == LayoutMode.ultraCompact
        ? (isHookPkg ? 1 : 0)
        : srcCount;
    entryLinesTotal += _entryFileLines(
      p,
      pkgSrcCount,
      packageDeps[p]!.length,
      mode,
    );
  }
  return appLines + leafTestLines + entryLinesTotal;
}

List<int> _distributeBudgets(List<int> minLines, int extraTotal) {
  final baseExtra = extraTotal ~/ minLines.length;
  final remExtra = extraTotal % minLines.length;
  return List<int>.generate(
    minLines.length,
    (i) => minLines[i] + baseExtra + (i < remExtra ? 1 : 0),
  );
}

/// Plans layout mode and per-source-file line budgets to hit [targetLoc].
(LayoutMode, List<int>) planSrcLineBudgets({
  required int targetLoc,
  required int layers,
  required int fanout,
  required int srcCount,
  required Map<int, List<int>> packageDeps,
}) {
  final isHookFile = <bool>[];
  for (var l = 0; l < layers; l++) {
    final isLeaf = l == layers - 1;
    for (var f = 0; f < fanout; f++) {
      final pkgId = l * fanout + f;
      for (var s = 0; s < srcCount; s++) {
        isHookFile.add((pkgId == 0 && s == 0) || (isLeaf && s == 0));
      }
    }
  }

  final stdBoilerplate = _computeBoilerplateLines(
    layers: layers,
    fanout: fanout,
    srcCount: srcCount,
    packageDeps: packageDeps,
    mode: LayoutMode.standard,
  );
  final stdMinSrc = isHookFile.fold<int>(0, (sum, h) => sum + (h ? 18 : 13));
  if (srcCount > 1 || targetLoc >= stdBoilerplate + stdMinSrc) {
    final minLines = [for (final h in isHookFile) h ? 18 : 13];
    final extra = max(0, targetLoc - stdBoilerplate - stdMinSrc);
    return (LayoutMode.standard, _distributeBudgets(minLines, extra));
  }

  final compactBoilerplate = _computeBoilerplateLines(
    layers: layers,
    fanout: fanout,
    srcCount: srcCount,
    packageDeps: packageDeps,
    mode: LayoutMode.compact,
  );
  final compactMinSrc = isHookFile.fold<int>(0, (sum, h) => sum + (h ? 13 : 2));
  if (targetLoc >= compactBoilerplate + compactMinSrc) {
    final minLines = [for (final h in isHookFile) h ? 13 : 2];
    final extra = max(0, targetLoc - compactBoilerplate - compactMinSrc);
    return (LayoutMode.compact, _distributeBudgets(minLines, extra));
  }

  final ultraBoilerplate = _computeBoilerplateLines(
    layers: layers,
    fanout: fanout,
    srcCount: srcCount,
    packageDeps: packageDeps,
    mode: LayoutMode.ultraCompact,
  );
  final hookMinLines = List<int>.filled(1 + fanout, 5);
  final ultraMinSrc = hookMinLines.length * 5;
  final extra = max(0, targetLoc - ultraBoilerplate - ultraMinSrc);
  return (LayoutMode.ultraCompact, _distributeBudgets(hookMinLines, extra));
}

String _formatUltraCompactEntry(
  PackagePlan plan,
  List<String> depImports,
  List<String> relImports,
) {
  final sections = <String>[
    if (depImports.isNotEmpty) depImports.join('\n'),
    if (relImports.isNotEmpty) relImports.join('\n'),
  ];
  final prefix = sections.isEmpty ? '' : '${sections.join('\n\n')}\n\n';
  final terms = <String>[
    'x',
    if (plan.srcFilesCount == 0) '${plan.inlineSeed}',
    for (var i = 0; i < plan.srcFilesCount; i++) 'fn${plan.pkgId}x$i(x)',
    for (final d in plan.deps) 'pkg${d}Entry(x)',
  ];
  return '${prefix}int pkg${plan.pkgId}Entry(int x) => '
      '${terms.join(' + ')};\n';
}

/// Writes `lib/pkg<id>.dart` for [plan] under [mode].
void writePackageEntryFile(PackagePlan plan, LayoutMode mode) {
  final depImports =
      plan.deps.map((d) => "import 'package:pkg$d/pkg$d.dart';").toList()
        ..sort();
  final relImports = List.generate(
    plan.srcFilesCount,
    (i) => "import 'src/f$i.dart';",
  )..sort();

  final entryFile = File('${plan.pkgDir}/lib/pkg${plan.pkgId}.dart');
  entryFile.parent.createSync(recursive: true);

  if (mode == LayoutMode.ultraCompact && plan.pkgId != 0) {
    entryFile.writeAsStringSync(
      _formatUltraCompactEntry(plan, depImports, relImports),
    );
    return;
  }

  final depImportBlock = depImports.isNotEmpty
      ? '${depImports.join('\n')}\n\n'
      : '';
  final header =
      '$depImportBlock${relImports.join('\n')}\n\n'
      '/// Entry function for package ${plan.pkgId}.\n';

  final String body;
  if (mode == LayoutMode.compact && plan.pkgId != 0) {
    final terms = <String>[
      'x',
      for (var i = 0; i < plan.srcFilesCount; i++) 'fn${plan.pkgId}x$i(x)',
      for (final d in plan.deps) 'pkg${d}Entry(x)',
    ];
    body = 'int pkg${plan.pkgId}Entry(int x) => ${terms.join(' + ')};\n';
  } else {
    final fileCalls = List.generate(
      plan.srcFilesCount,
      (i) => '  acc += fn${plan.pkgId}x$i(x);',
    ).join('\n');
    final depCalls = plan.deps.isEmpty
        ? ''
        : '${plan.deps.map((d) => '  acc += pkg${d}Entry(x);').join('\n')}\n';
    body =
        'int pkg${plan.pkgId}Entry(int x) {\n'
        '  var acc = x;\n'
        '$fileCalls\n'
        '$depCalls'
        '  return acc;\n'
        '}\n';
  }

  entryFile.writeAsStringSync('$header$body');
}

/// Writes `test/pkg<id>_test.dart` for a leaf package.
void writePackageTestFile(String pkgDir, int pkgId) {
  final testDir = Directory('$pkgDir/test')..createSync(recursive: true);
  final testContent =
      '''
import 'package:pkg$pkgId/pkg$pkgId.dart';
import 'package:test/test.dart';

void main() {
  test('pkg$pkgId entry test', () {
    expect(pkg${pkgId}Entry(1), isPositive);
  });
}
''';
  File('${testDir.path}/pkg${pkgId}_test.dart').writeAsStringSync(testContent);
}

List<String> _buildFnLines({
  required int pkgId,
  required int fileIndex,
  required String baseExpr,
  required int seedVal,
  required int lineCount,
}) {
  final doc = '/// Function for pkg $pkgId file $fileIndex.';
  final name = 'fn${pkgId}x$fileIndex';
  if (lineCount <= 2) {
    return [doc, 'int $name(int x) => $baseExpr + x;'];
  }
  if (lineCount == 3) {
    return [
      doc,
      '/// Seed offset $seedVal.',
      'int $name(int x) => $baseExpr + x;',
    ];
  }
  if (lineCount == 4) {
    return [doc, 'int $name(int x) {', '  return $baseExpr + x;', '}'];
  }
  if (lineCount == 5) {
    return [
      doc,
      'int $name(int x) {',
      '  final base = $baseExpr + x;',
      '  return base;',
      '}',
    ];
  }
  return [
    doc,
    'int $name(int x) {',
    '  var acc = $baseExpr + x;',
    for (var k = 1; k <= lineCount - 5; k++) '  acc += $k;',
    '  return acc;',
    '}',
  ];
}

List<String> _buildUltraCompactHookLines(SrcFilePlan plan) {
  final header = <String>[
    'int ${plan.hookName}() {',
    '  return ${plan.hookVal};',
    '}',
    '',
  ];
  final rem = plan.targetLines - 4;
  final expr = '${plan.hookName}() + ${plan.seedVal}';
  if (rem <= 1) {
    return [
      ...header,
      'int fn${plan.pkgId}x${plan.fileIndex}(int x) => $expr + x;',
    ];
  }
  return [
    ...header,
    ..._buildFnLines(
      pkgId: plan.pkgId,
      fileIndex: plan.fileIndex,
      baseExpr: expr,
      seedVal: plan.seedVal,
      lineCount: rem,
    ),
  ];
}

List<String> _buildCompactSrcLines(SrcFilePlan plan) {
  if (!plan.hasHook) {
    return _buildFnLines(
      pkgId: plan.pkgId,
      fileIndex: plan.fileIndex,
      baseExpr: '${plan.seedVal}',
      seedVal: plan.seedVal,
      lineCount: plan.targetLines,
    );
  }

  final cls = 'C${plan.pkgId}x${plan.fileIndex}';
  return [
    '/// Class for pkg ${plan.pkgId} file ${plan.fileIndex}.',
    'class $cls {',
    '  /// Constructor.',
    '  const $cls();',
    '',
    '  /// Hook for edit.',
    '  int ${plan.hookName}() {',
    '    return ${plan.hookVal};',
    '  }',
    '}',
    '',
    ..._buildFnLines(
      pkgId: plan.pkgId,
      fileIndex: plan.fileIndex,
      baseExpr: 'const $cls().${plan.hookName}() + ${plan.seedVal}',
      seedVal: plan.seedVal,
      lineCount: plan.targetLines - 11,
    ),
  ];
}

List<String> _buildStandardSrcLines(SrcFilePlan plan) {
  final cls = 'C${plan.pkgId}x${plan.fileIndex}';
  final lines = <String>[
    '/// Class for pkg ${plan.pkgId} file ${plan.fileIndex}.',
    'class $cls {',
    '  /// Constructor.',
    '  const $cls(this.value);',
    '',
    '  /// Value field.',
    '  final int value;',
  ];
  if (plan.hasHook) {
    lines.addAll([
      '',
      '  /// Hook for edit.',
      '  int ${plan.hookName}() {',
      '    return ${plan.hookVal};',
      '  }',
    ]);
  }

  final minTotal = plan.hasHook ? 18 : 13;
  final neededExtra = max(0, plan.targetLines - minTotal);
  final numMethods = neededExtra ~/ 9;
  final remLines = neededExtra % 9;

  for (var m = 0; m < numMethods; m++) {
    lines.addAll([
      '',
      '  /// Method $m.',
      '  int m$m(int x) {',
      '    var acc = x + $m + ${plan.seedVal};',
      '    for (var j = 0; j < 3; j++) {',
      '      acc += j;',
      '    }',
      '    return acc;',
      '  }',
    ]);
  }

  final memberExpr = plan.hasHook ? '${plan.hookName}()' : 'value';
  lines.addAll([
    '}',
    '',
    ..._buildFnLines(
      pkgId: plan.pkgId,
      fileIndex: plan.fileIndex,
      baseExpr: 'const $cls(${plan.seedVal}).$memberExpr',
      seedVal: plan.seedVal,
      lineCount: 4 + remLines,
    ),
  ]);
  return lines;
}

/// Writes `lib/src/f<i>.dart` for [plan].
void writeSrcFile(SrcFilePlan plan) {
  final minStd = plan.hasHook ? 18 : 13;
  final List<String> lines;
  if (plan.ultraCompact) {
    lines = _buildUltraCompactHookLines(plan);
  } else if (plan.targetLines < minStd) {
    lines = _buildCompactSrcLines(plan);
  } else {
    lines = _buildStandardSrcLines(plan);
  }

  final srcDir = Directory('${plan.pkgDir}/lib/src')
    ..createSync(recursive: true);
  File('${srcDir.path}/f${plan.fileIndex}.dart')
      .writeAsStringSync('${lines.join('\n')}\n');
}
