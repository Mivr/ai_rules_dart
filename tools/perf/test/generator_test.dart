/// Unit tests for deterministic layered monorepo generator.
library;

import 'dart:io';

import 'package:perf/generator.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
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

void _testModuleBazelParsing() {
  final legacy = parseModuleHeader('''
module(
    name = "rules_dart",
    version = "0.13.0",
)
''');
  _check(legacy.moduleName == 'rules_dart', 'legacy moduleName');
  _check(legacy.repoName == 'rules_dart', 'legacy repoName defaults to name');

  final current = parseModuleHeader('''
module(
    name = "ai_rules_dart",
    bazel_compatibility = [">=9.0.0"],
    repo_name = "rules_dart",
)
''');
  _check(current.moduleName == 'ai_rules_dart', 'current moduleName');
  _check(current.repoName == 'rules_dart', 'current repoName');
}

void _testDeterminismAndSensitivity() {
  final tempDir = Directory.systemTemp.createTempSync('rd_gen_test_');
  try {
    final rulesMock = Directory('${tempDir.path}/rules_mock')..createSync();
    File('${rulesMock.path}/MODULE.bazel').writeAsStringSync(
      'module(name = "ai_rules_dart", repo_name = "rules_dart")\n',
    );
    File('${rulesMock.path}/.bazelversion').writeAsStringSync('9.3.0\n');
    final e2eDir = Directory('${rulesMock.path}/e2e/dart_test_pkg')
      ..createSync(recursive: true);
    File('${e2eDir.path}/pubspec.lock').writeAsStringSync('packages: {}\n');
    File('${e2eDir.path}/pubspec.yaml').writeAsStringSync('name: mock\n');

    final out1 = '${tempDir.path}/out1';
    final out2 = '${tempDir.path}/out2';
    final out3 = '${tempDir.path}/out3';

    // Same seed (1) -> identical output
    generateWorkspace(
      GeneratorOptions(
        targetLoc: 2000,
        seed: 1,
        rulesDartPath: rulesMock.path,
        outputPath: out1,
        layers: 4,
        fanout: 2,
      ),
    );

    generateWorkspace(
      GeneratorOptions(
        targetLoc: 2000,
        seed: 1,
        rulesDartPath: rulesMock.path,
        outputPath: out2,
        layers: 4,
        fanout: 2,
      ),
    );

    // Different seed (2) -> sensitive to seed
    generateWorkspace(
      GeneratorOptions(
        targetLoc: 2000,
        seed: 2,
        rulesDartPath: rulesMock.path,
        outputPath: out3,
        layers: 4,
        fanout: 2,
      ),
    );

    final f0Out1 = File('$out1/packages/pkg0/lib/src/f0.dart')
        .readAsStringSync();
    final f0Out2 = File('$out2/packages/pkg0/lib/src/f0.dart')
        .readAsStringSync();
    final f0Out3 = File('$out3/packages/pkg0/lib/src/f0.dart')
        .readAsStringSync();

    _check(f0Out1 == f0Out2, 'Same seed produces byte-identical files');
    _check(f0Out1 != f0Out3, 'Different seed produces different files');

    // Check .bazelversion and pubspec copy
    _check(File('$out1/.bazelversion').existsSync(), '.bazelversion copied');
    _check(File('$out1/pubspec.lock').existsSync(), 'pubspec.lock copied');

    // Check MODULE.bazel loads
    final mod = File('$out1/MODULE.bazel').readAsStringSync();
    _check(mod.contains('repo_name = "rules_dart"'), 'MODULE.bazel repo_name');
  } finally {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // Best-effort cleanup.
    }
  }
}

void _testLineCountAndAcyclicLayering() {
  final tempDir = Directory.systemTemp.createTempSync('rd_layer_test_');
  try {
    final rulesMock = Directory('${tempDir.path}/rules_mock')..createSync();
    File('${rulesMock.path}/MODULE.bazel')
        .writeAsStringSync('module(name = "rules_dart")\n');

    const targetLoc = 5000;
    const layers = 4;
    const fanout = 3;
    final out = '${tempDir.path}/out';

    generateWorkspace(
      GeneratorOptions(
        targetLoc: targetLoc,
        seed: 42,
        rulesDartPath: rulesMock.path,
        outputPath: out,
        layers: layers,
        fanout: fanout,
      ),
    );

    // Line count within 5% of targetLoc
    final totalLines = _countDartLines(Directory(out));
    final diff = (totalLines - targetLoc).abs();
    final maxAllowedDiff = (targetLoc * 0.05).round();
    _check(
      diff <= maxAllowedDiff,
      'Line count $totalLines is within 5% of $targetLoc (allowed diff $maxAllowedDiff, got $diff)',
    );

    // Acyclic layering & dependency checks
    final totalPkgs = layers * fanout;
    for (var l = 0; l < layers; l++) {
      for (var f = 0; f < fanout; f++) {
        final pkgId = l * fanout + f;
        final buildFile = File('$out/packages/pkg$pkgId/BUILD.bazel');
        _check(buildFile.existsSync(), 'Package $pkgId BUILD.bazel exists');
        final content = buildFile.readAsStringSync();

        if (l == 0) {
          _check(
            !content.contains('//packages/'),
            'Layer 0 pkg$pkgId must have deps = []',
          );
        } else {
          // Must depend on lower layers only
          for (var p = l * fanout; p < totalPkgs; p++) {
            _check(
              !content.contains('"//packages/pkg$p"'),
              'Layer $l pkg$pkgId cannot depend on higher/same layer pkg$p',
            );
          }
          // Must depend on at least one package in l - 1
          var hasLMinus1 = false;
          for (var prevF = 0; prevF < fanout; prevF++) {
            final prevId = (l - 1) * fanout + prevF;
            if (content.contains('"//packages/pkg$prevId"')) {
              hasLMinus1 = true;
              break;
            }
          }
          _check(
            hasLMinus1,
            'Layer $l pkg$pkgId must depend on layer ${l - 1}',
          );
        }

        // Leaf layer declares dart_test
        if (l == layers - 1) {
          _check(
            content.contains('dart_test('),
            'Leaf pkg$pkgId must declare dart_test',
          );
          _check(
            File('$out/packages/pkg$pkgId/test/pkg${pkgId}_test.dart')
                .existsSync(),
            'Leaf pkg$pkgId must have test file',
          );
        } else {
          _check(
            !content.contains('dart_test('),
            'Non-leaf pkg$pkgId should not declare dart_test',
          );
        }
      }
    }

    // App reaches leaf layer
    final appBuild = File('$out/app/BUILD.bazel').readAsStringSync();
    for (var f = 0; f < fanout; f++) {
      final leafId = (layers - 1) * fanout + f;
      _check(
        appBuild.contains('"//packages/pkg$leafId"'),
        'App depends on leaf package $leafId',
      );
    }
  } finally {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // Best-effort cleanup.
    }
  }
}

void main() {
  _testModuleBazelParsing();
  _testDeterminismAndSensitivity();
  _testLineCountAndAcyclicLayering();
  stdout.writeln('All generator tests passed.');
}
