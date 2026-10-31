/// Deterministic layered Dart monorepo generator for rules_dart benchmarks.
library;

import 'dart:io';
import 'dart:math';

/// Parsed module identity from a Bazel MODULE.bazel file.
final class ModuleIdentity {
  /// Creates a module identity.
  const ModuleIdentity({required this.moduleName, required this.repoName});

  /// The Bazel module name.
  final String moduleName;

  /// The Bazel repository name (defaults to moduleName).
  final String repoName;
}

/// Parses `module(name = "...", repo_name = "...")` from MODULE.bazel text.
ModuleIdentity parseModuleHeader(String content) {
  final match = RegExp(
    r'module\s*\(([^)]*)\)',
    multiLine: true,
    dotAll: true,
  ).firstMatch(content);
  if (match == null) {
    return const ModuleIdentity(
      moduleName: 'rules_dart',
      repoName: 'rules_dart',
    );
  }

  final body = match.group(1) ?? '';
  final nameMatch = RegExp(r'''name\s*=\s*["']([^"']+)["']''').firstMatch(body);
  final repoMatch = RegExp(r'''repo_name\s*=\s*["']([^"']+)["']''')
      .firstMatch(body);

  final moduleName = nameMatch?.group(1) ?? 'rules_dart';
  final repoName = repoMatch?.group(1) ?? moduleName;

  return ModuleIdentity(moduleName: moduleName, repoName: repoName);
}

/// Configuration options for workspace generation.
final class GeneratorOptions {
  /// Creates generator options.
  const GeneratorOptions({
    this.targetLoc = 500000,
    this.seed = 1,
    required this.rulesDartPath,
    required this.outputPath,
    this.layers = 8,
    this.fanout = 4,
  });

  /// Target total `.dart` line count.
  final int targetLoc;

  /// Deterministic PRNG seed.
  final int seed;

  /// Path to rules_dart under measurement.
  final String rulesDartPath;

  /// Destination directory for generated workspace.
  final String outputPath;

  /// Number of package DAG layers (default 8).
  final int layers;

  /// Number of packages per layer (default 4).
  final int fanout;
}

/// Generates a layered benchmark workspace.
void generateWorkspace(GeneratorOptions options) {
  final outDir = Directory(options.outputPath);
  if (outDir.existsSync()) outDir.deleteSync(recursive: true);
  outDir.createSync(recursive: true);

  final moduleFile = File('${options.rulesDartPath}/MODULE.bazel');
  final moduleContent = moduleFile.existsSync()
      ? moduleFile.readAsStringSync()
      : '';
  final identity = parseModuleHeader(moduleContent);

  _writeModuleBazel(options, identity);
  _copyPristineFiles(options);
  _writeRootBuild(options);
  _generatePackagesAndApp(options, identity);
}

void _writeModuleBazel(GeneratorOptions options, ModuleIdentity identity) {
  final repoArg = identity.repoName != identity.moduleName
      ? ', repo_name = "${identity.repoName}"'
      : '';

  final content =
      '''
module(name = "bench")

bazel_dep(name = "${identity.moduleName}", version = "0.0.0"$repoArg)
local_path_override(
    module_name = "${identity.moduleName}",
    path = "${options.rulesDartPath}",
)

dart = use_extension("@${identity.repoName}//dart:extensions.bzl", "dart")
dart.toolchain(dart_version = "3.13.5")
use_repo(dart, "dart_toolchains")
register_toolchains("@dart_toolchains//:all")

pub = use_extension("@${identity.repoName}//dart/pub:extensions.bzl", "pub")
pub.from_lock(
    name = "pub_deps",
    lock = "//:pubspec.lock",
)
use_repo(pub, "pub_deps")
''';

  File('${options.outputPath}/MODULE.bazel').writeAsStringSync(content);
}

void _copyPristineFiles(GeneratorOptions options) {
  final lock = File('${options.rulesDartPath}/e2e/dart_test_pkg/pubspec.lock');
  if (lock.existsSync()) {
    lock.copySync('${options.outputPath}/pubspec.lock');
  }

  final yaml = File('${options.rulesDartPath}/e2e/dart_test_pkg/pubspec.yaml');
  if (yaml.existsSync()) {
    yaml.copySync('${options.outputPath}/pubspec.yaml');
  }

  final bazelver = File('${options.rulesDartPath}/.bazelversion');
  if (bazelver.existsSync()) {
    bazelver.copySync('${options.outputPath}/.bazelversion');
  }
}

void _writeRootBuild(GeneratorOptions options) {
  const content = '''
exports_files([
    "pubspec.lock",
    "pubspec.yaml",
])
''';
  File('${options.outputPath}/BUILD.bazel').writeAsStringSync(content);
}

void _generatePackagesAndApp(
  GeneratorOptions options,
  ModuleIdentity identity,
) {
  final totalPackages = options.layers * options.fanout;
  final appFileLines = 25;
  final testLinesPerLeaf = 16;
  final totalTestLines = options.fanout * testLinesPerLeaf;
  final availableForPackages = max(
    100,
    options.targetLoc - appFileLines - totalTestLines,
  );
  final linesPerPackage = max(20, availableForPackages ~/ totalPackages);

  final rng = Random(options.seed);
  final packageDeps = <int, List<int>>{};

  for (var l = 0; l < options.layers; l++) {
    for (var f = 0; f < options.fanout; f++) {
      final pkgId = l * options.fanout + f;
      if (l == 0) {
        packageDeps[pkgId] = const [];
      } else {
        final deps = <int>[];
        // At least one dependency from l - 1
        final primary = (l - 1) * options.fanout + (f % options.fanout);
        deps.add(primary);

        // Optional secondary dependency from any layer < l
        if (l > 1 && rng.nextBool()) {
          final maxLowerPkg = (l - 1) * options.fanout;
          final sec = rng.nextInt(maxLowerPkg);
          if (!deps.contains(sec)) deps.add(sec);
        }
        packageDeps[pkgId] = deps;
      }
    }
  }

  for (var l = 0; l < options.layers; l++) {
    for (var f = 0; f < options.fanout; f++) {
      final pkgId = l * options.fanout + f;
      final isLeaf = l == options.layers - 1;
      _writePackage(
        options: options,
        identity: identity,
        layer: l,
        fanoutIndex: f,
        pkgId: pkgId,
        deps: packageDeps[pkgId]!,
        targetLines: linesPerPackage,
        isLeaf: isLeaf,
        rng: rng,
      );
    }
  }

  _writeApp(options, identity);
}

void _writePackage({
  required GeneratorOptions options,
  required ModuleIdentity identity,
  required int layer,
  required int fanoutIndex,
  required int pkgId,
  required List<int> deps,
  required int targetLines,
  required bool isLeaf,
  required Random rng,
}) {
  final pkgDir = Directory('${options.outputPath}/packages/pkg$pkgId');
  pkgDir.createSync(recursive: true);

  final depLabels = deps.map((d) => '        "//packages/pkg$d",').join('\n');
  final testTarget = isLeaf
      ? '''
dart_test(
    name = "pkg${pkgId}_test",
    size = "small",
    main = "test/pkg${pkgId}_test.dart",
    deps = [
        ":pkg$pkgId",
        "@pub_deps//:test",
    ],
)
'''
      : '';

  final buildContent =
      '''
load("@${identity.repoName}//dart:defs.bzl", "dart_library"${isLeaf ? ', "dart_test"' : ''})

dart_library(
    name = "pkg$pkgId",
    srcs = glob(["lib/**/*.dart"]),
    visibility = ["//visibility:public"],
    deps = [
$depLabels
    ],
)
$testTarget''';
  File('${pkgDir.path}/BUILD.bazel').writeAsStringSync(buildContent);

  // Files per package
  final srcFilesCount = max(1, min(10, targetLines ~/ 250));
  final linesForSrc = max(15, targetLines - 25);
  final linesPerFile = max(15, linesForSrc ~/ srcFilesCount);

  final srcDir = Directory('${pkgDir.path}/lib/src');
  srcDir.createSync(recursive: true);

  for (var f = 0; f < srcFilesCount; f++) {
    _writeSrcFile(
      srcDir: srcDir,
      pkgId: pkgId,
      fileIndex: f,
      layer: layer,
      isLeaf: isLeaf,
      targetLines: linesPerFile,
      seedVal: rng.nextInt(1000),
    );
  }

  // Write entry file
  final exports = List.generate(
    srcFilesCount,
    (i) => "export 'src/f$i.dart';",
  ).join('\n');
  final imports = List.generate(
    srcFilesCount,
    (i) => "import 'src/f$i.dart';",
  ).join('\n');
  final depImports = deps
      .map((d) => "import 'package:pkg$d/pkg$d.dart';")
      .join('\n');

  final depSum = deps.isEmpty
      ? 'x'
      : deps.map((d) => 'pkg${d}_entry(x)').join(' + ');

  final fileCalls = List.generate(
    srcFilesCount,
    (i) => 'fn${pkgId}x$i(x)',
  ).join(' + ');

  final entryContent =
      '''
$exports
$imports
$depImports

/// Entry function for package $pkgId.
int pkg${pkgId}_entry(int x) {
  return $fileCalls + $depSum;
}
''';
  File('${pkgDir.path}/lib/pkg$pkgId.dart').writeAsStringSync(entryContent);

  if (isLeaf) {
    final testDir = Directory('${pkgDir.path}/test');
    testDir.createSync(recursive: true);
    final testContent =
        '''
import 'package:pkg$pkgId/pkg$pkgId.dart';
import 'package:test/test.dart';

void main() {
  test('pkg$pkgId entry test', () {
    expect(pkg${pkgId}_entry(1), isPositive);
  });
}
''';
    File('${testDir.path}/pkg${pkgId}_test.dart')
        .writeAsStringSync(testContent);
  }
}

void _writeSrcFile({
  required Directory srcDir,
  required int pkgId,
  required int fileIndex,
  required int layer,
  required bool isLeaf,
  required int targetLines,
  required int seedVal,
}) {
  final buffer = StringBuffer();
  buffer.writeln('/// Class for pkg $pkgId file $fileIndex.');
  buffer.writeln('class C${pkgId}x$fileIndex {');
  buffer.writeln('  /// Constructor.');
  buffer.writeln('  const C${pkgId}x$fileIndex(this.value);');
  buffer.writeln('');
  buffer.writeln('  /// Value field.');
  buffer.writeln('  final int value;');
  buffer.writeln('');

  // Fixed overhead: 9 lines so far. Bottom helper adds 4 lines. Class close 1 line.
  var currentLines = 14;

  // Insert deterministic hooks in layer 0 file 0 or leaf file 0
  if (layer == 0 && fileIndex == 0) {
    buffer.writeln('  /// Hook for body edit.');
    buffer.writeln('  int bodyHook() {');
    buffer.writeln('    return 1;');
    buffer.writeln('  }');
    buffer.writeln('');
    currentLines += 5;
  } else if (isLeaf && fileIndex == 0) {
    buffer.writeln('  /// Hook for leaf test body edit.');
    buffer.writeln('  int leafTestHook() {');
    buffer.writeln('    return 10;');
    buffer.writeln('  }');
    buffer.writeln('');
    currentLines += 5;
  }

  var methodIdx = 0;
  while (currentLines + 9 <= targetLines) {
    buffer.writeln('  /// Method $methodIdx.');
    buffer.writeln('  int m$methodIdx(int x) {');
    buffer.writeln('    var acc = x + $methodIdx + $seedVal;');
    buffer.writeln('    for (var j = 0; j < 3; j++) {');
    buffer.writeln('      acc += j;');
    buffer.writeln('    }');
    buffer.writeln('    return acc;');
    buffer.writeln('  }');
    buffer.writeln('');
    currentLines += 9;
    methodIdx++;
  }

  while (currentLines < targetLines) {
    buffer.writeln('  // Line filler $currentLines.');
    currentLines++;
  }

  buffer.writeln('}');
  buffer.writeln('');
  buffer.writeln('/// Function for pkg $pkgId file $fileIndex.');
  buffer.writeln('int fn${pkgId}x$fileIndex(int x) {');
  buffer.writeln('  return const C${pkgId}x$fileIndex(0).value + x;');
  buffer.writeln('}');

  File('${srcDir.path}/f$fileIndex.dart').writeAsStringSync(buffer.toString());
}

void _writeApp(GeneratorOptions options, ModuleIdentity identity) {
  final appDir = Directory('${options.outputPath}/app');
  appDir.createSync(recursive: true);

  final leafPkgIds = List.generate(
    options.fanout,
    (i) => (options.layers - 1) * options.fanout + i,
  );
  final depLabels = leafPkgIds
      .map((id) => '        "//packages/pkg$id",')
      .join('\n');

  final buildContent =
      '''
load("@${identity.repoName}//dart:defs.bzl", "dart_binary")

dart_binary(
    name = "app",
    main = "bin/main.dart",
    deps = [
$depLabels
    ],
)
''';
  File('${appDir.path}/BUILD.bazel').writeAsStringSync(buildContent);

  final binDir = Directory('${appDir.path}/bin');
  binDir.createSync(recursive: true);

  final imports = leafPkgIds
      .map((id) => "import 'package:pkg$id/pkg$id.dart';")
      .join('\n');
  final sumCalls = leafPkgIds.map((id) => 'pkg${id}_entry(1)').join(' + ');

  final mainContent =
      '''
$imports

void main() {
  final total = $sumCalls;
  print('Result: \$total');
}
''';
  File('${binDir.path}/main.dart').writeAsStringSync(mainContent);
}
