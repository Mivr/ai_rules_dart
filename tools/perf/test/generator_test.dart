/// Unit tests for the deterministic layered Dart monorepo generator and edits.
library;

import 'dart:io';

import 'package:perf/generator.dart';
import 'package:perf/runner.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

void _expectArgumentError(void Function() action, String message) {
  try {
    action();
  } on ArgumentError catch (e) {
    _check(e.toString().isNotEmpty, message);
    return;
  }
  throw StateError('FAIL: $message (expected ArgumentError)');
}

void _deleteTemp(Directory dir) {
  try {
    dir.deleteSync(recursive: true);
  } on FileSystemException catch (e) {
    stderr.writeln('Temp directory cleanup skipped (${dir.path}): $e');
  }
}

int _countDartLines(Directory dir) {
  var total = 0;
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      total += entity.readAsLinesSync().length;
    }
  }
  return total;
}

Map<String, String> _snapshotFiles(Directory root) {
  final rootPath = root.path.replaceAll(r'\', '/');
  final map = <String, String>{};
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File) {
      final norm = entity.path.replaceAll(r'\', '/');
      final rel = norm.substring(rootPath.length + 1);
      map[rel] = entity.readAsStringSync();
    }
  }
  return map;
}

Directory _createMockRulesDart(
  Directory parent, {
  required String name,
  required String moduleContent,
}) {
  final dir = Directory('${parent.path}/$name')..createSync(recursive: true);
  File('${dir.path}/MODULE.bazel').writeAsStringSync(moduleContent);
  File('${dir.path}/.bazelversion').writeAsStringSync('9.3.0\n');
  final e2eDir = Directory('${dir.path}/e2e/dart_test_pkg')
    ..createSync(recursive: true);
  File('${e2eDir.path}/pubspec.lock').writeAsStringSync('packages: {}\n');
  File('${e2eDir.path}/pubspec.yaml').writeAsStringSync('name: mock\n');
  return dir;
}

void _testModuleBazelParsing() {
  final legacy = parseModuleHeader('''
module(
    name = "rules_dart",
    version = "0.13.0",
)
''');
  _check(legacy.moduleName == 'rules_dart', 'legacy moduleName');
  _check(legacy.repoName == 'rules_dart', 'legacy repoName defaults to name');
  _check(legacy.dartVersion == '3.13.5', 'default dartVersion');

  final current = parseModuleHeader('''
module(
    name = "ai_rules_dart",
    bazel_compatibility = [">=9.0.0"],
    repo_name = "rules_dart",
)
dart.toolchain(dart_version = "3.11.4")
''');
  _check(current.moduleName == 'ai_rules_dart', 'current moduleName');
  _check(current.repoName == 'rules_dart', 'current repoName');
  _check(current.dartVersion == '3.11.4', 'parsed dartVersion');
}

void _testInvalidOptionsValidation() {
  _expectArgumentError(
    () => generateWorkspace(
      const GeneratorOptions(
        targetLoc: 0,
        seed: 1,
        rulesDartPath: '/nonexistent',
        outputPath: '/nonexistent_out',
      ),
    ),
    'targetLoc == 0 rejected',
  );
  _expectArgumentError(
    () => generateWorkspace(
      const GeneratorOptions(
        targetLoc: -100,
        seed: 1,
        rulesDartPath: '/nonexistent',
        outputPath: '/nonexistent_out',
      ),
    ),
    'negative targetLoc rejected',
  );
}

void _testDeterminismAndModuleCompatibility() {
  final tempDir = Directory.systemTemp.createTempSync('rd_gen_det_');
  try {
    final aiRules = _createMockRulesDart(
      tempDir,
      name: 'ai_rules',
      moduleContent:
          'module(name = "ai_rules_dart", repo_name = "rules_dart")\n',
    );
    final legacyRules = _createMockRulesDart(
      tempDir,
      name: 'legacy_rules',
      moduleContent: 'module(name = "rules_dart", version = "0.13.0")\n',
    );

    final out1 = '${tempDir.path}/out1';
    final out2 = '${tempDir.path}/out2';
    final out3 = '${tempDir.path}/out3';
    final outLegacy = '${tempDir.path}/out_legacy';

    for (final (out, seed, rules) in [
      (out1, 1, aiRules.path),
      (out2, 1, aiRules.path),
      (out3, 2, aiRules.path),
      (outLegacy, 1, legacyRules.path),
    ]) {
      generateWorkspace(
        GeneratorOptions(
          targetLoc: 2000,
          seed: seed,
          rulesDartPath: rules,
          outputPath: out,
          layers: 4,
          fanout: 2,
        ),
      );
    }

    final snap1 = _snapshotFiles(Directory(out1));
    final snap2 = _snapshotFiles(Directory(out2));
    final snap3 = _snapshotFiles(Directory(out3));
    _check(snap1.length == snap2.length, 'Same seed produces same file count');
    for (final entry in snap1.entries) {
      _check(
        snap2[entry.key] == entry.value,
        'Byte-identical file for same seed: ${entry.key}',
      );
    }
    _check(
      snap1['packages/pkg0/lib/src/f0.dart'] !=
          snap3['packages/pkg0/lib/src/f0.dart'],
      'Different seed produces distinct Dart sources',
    );

    _check(File('$out1/.bazelversion').existsSync(), '.bazelversion copied');
    _check(File('$out1/pubspec.lock').existsSync(), 'pubspec.lock copied');
    final aiMod = File('$out1/MODULE.bazel').readAsStringSync();
    _check(aiMod.contains('name = "ai_rules_dart"'), 'ai_rules_dart dep');
    _check(aiMod.contains('repo_name = "rules_dart"'), 'ai_rules_dart repo');

    final legMod = File('$outLegacy/MODULE.bazel').readAsStringSync();
    _check(legMod.contains('name = "rules_dart"'), 'legacy rules_dart dep');
    _check(
      legMod.contains('module_name = "rules_dart"'),
      'legacy override module_name',
    );
  } finally {
    _deleteTemp(tempDir);
  }
}

Set<int> _extractPackageDeps(String buildContent) {
  final matches = RegExp(r'"//packages/pkg(\d+)"').allMatches(buildContent);
  return {for (final m in matches) int.parse(m.group(1)!)};
}

void _verifyPackageLayerRules({
  required String out,
  required int layers,
  required int fanout,
}) {
  for (var l = 0; l < layers; l++) {
    for (var f = 0; f < fanout; f++) {
      final pkgId = l * fanout + f;
      final content = File('$out/packages/pkg$pkgId/BUILD.bazel')
          .readAsStringSync();
      final deps = _extractPackageDeps(content);

      if (l == 0) {
        _check(deps.isEmpty, 'Layer 0 pkg$pkgId has no package deps');
        _check(content.contains('deps = []'), 'Layer 0 explicit deps = []');
      } else {
        _check(
          deps.every((d) => d < l * fanout),
          'Layer $l pkg$pkgId depends strictly on lower layers: $deps',
        );
        _check(
          deps.any((d) => d >= (l - 1) * fanout && d < l * fanout),
          'Layer $l pkg$pkgId depends on at least one package in layer ${l - 1}',
        );
      }

      final isLeaf = l == layers - 1;
      _check(
        content.contains('dart_test(') == isLeaf,
        'dart_test presence on pkg$pkgId matches leaf=$isLeaf',
      );
      if (isLeaf) {
        _check(
          content.contains('size = "small"'),
          'Leaf dart_test declares size = "small"',
        );
      }
    }
  }
}

void _verifyTransitiveReachabilityAndHygiene(
  String out,
  int layers,
  int fanout,
) {
  final appBuild = File('$out/app/BUILD.bazel').readAsStringSync();
  final frontier = _extractPackageDeps(appBuild).toList();
  _check(frontier.length == fanout, 'App depends on all leaf packages');

  final visited = <int>{...frontier};
  while (frontier.isNotEmpty) {
    final current = frontier.removeLast();
    final content = File('$out/packages/pkg$current/BUILD.bazel')
        .readAsStringSync();
    for (final dep in _extractPackageDeps(content)) {
      if (visited.add(dep)) frontier.add(dep);
    }
  }
  _check(
    visited.any((id) => id < fanout),
    '//app:app transitively reaches layer 0',
  );

  for (final entity in Directory(out).listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final lines = entity.readAsLinesSync();
    var seenExport = false;
    String? prevImport;
    for (final line in lines) {
      _check(!line.contains('print('), 'No print() calls in ${entity.path}');
      if (line.startsWith('export ')) seenExport = true;
      if (line.startsWith('import ')) {
        _check(!seenExport, 'import before export in ${entity.path}');
        if (prevImport != null) {
          _check(
            prevImport.compareTo(line) <= 0,
            'Sorted imports in ${entity.path}: $prevImport vs $line',
          );
        }
        prevImport = line;
      }
    }
  }
}

void _testDefaultGraphAndEdits() {
  final tempDir = Directory.systemTemp.createTempSync('rd_layer_edits_');
  try {
    final rulesMock = _createMockRulesDart(
      tempDir,
      name: 'rules_mock',
      moduleContent: 'module(name = "rules_dart")\n',
    );
    final out = '${tempDir.path}/ws';
    generateWorkspace(
      GeneratorOptions(
        targetLoc: 6000,
        seed: 7,
        rulesDartPath: rulesMock.path,
        outputPath: out,
      ),
    );

    _verifyPackageLayerRules(out: out, layers: 8, fanout: 4);
    _verifyTransitiveReachabilityAndHygiene(out, 8, 4);

    applyLayer0BodyEdit(out);
    final f0After = File('$out/packages/pkg0/lib/src/f0.dart')
        .readAsStringSync();
    _check(f0After.contains('    return 2;\n'), 'Layer 0 body edit applied');

    applyLayer0ApiEdit(out);
    final apiAfter = File('$out/packages/pkg0/lib/pkg0.dart')
        .readAsStringSync();
    _check(
      apiAfter.contains('int pkg0Entry(int x, [int bonus = 0])'),
      'Layer 0 API edit applied cleanly',
    );

    applyLeafBodyEdit(out, 'pkg28');
    final leafAfter = File('$out/packages/pkg28/lib/src/f0.dart')
        .readAsStringSync();
    _check(
      leafAfter.contains('    return 20;\n'),
      'Leaf body edit applied cleanly',
    );

    final copied = Directory('${tempDir.path}/copied_ws');
    copyDirectorySync(Directory(out), copied);
    final origSnap = _snapshotFiles(Directory(out));
    final copiedSnap = _snapshotFiles(copied);
    _check(
      origSnap.length == copiedSnap.length,
      'copyDirectorySync preserves exact file count',
    );
    for (final entry in origSnap.entries) {
      _check(
        copiedSnap[entry.key] == entry.value,
        'copyDirectorySync preserves ${entry.key}',
      );
    }
  } finally {
    _deleteTemp(tempDir);
  }
}

void _testLineCountAccuracyAcrossScales() {
  final tempDir = Directory.systemTemp.createTempSync('rd_loc_scales_');
  try {
    final rulesMock = _createMockRulesDart(
      tempDir,
      name: 'rules_mock',
      moduleContent: 'module(name = "rules_dart")\n',
    );

    for (final loc in [1000, 2000, 10000, 50000]) {
      final out = '${tempDir.path}/out_$loc';
      generateWorkspace(
        GeneratorOptions(
          targetLoc: loc,
          seed: 1,
          rulesDartPath: rulesMock.path,
          outputPath: out,
        ),
      );
      final total = _countDartLines(Directory(out));
      final diff = (total - loc).abs();
      final maxAllowed = (loc * 0.05).round();
      _check(
        diff <= maxAllowed,
        'Target $loc got $total lines (diff $diff, max allowed $maxAllowed)',
      );
    }
  } finally {
    _deleteTemp(tempDir);
  }
}

void main() {
  _testModuleBazelParsing();
  _testInvalidOptionsValidation();
  _testDeterminismAndModuleCompatibility();
  _testDefaultGraphAndEdits();
  _testLineCountAccuracyAcrossScales();
  stdout.writeln('All generator tests passed.');
}
