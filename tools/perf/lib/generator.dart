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

/// Configuration for writing a single package.
final class PackageConfig {
  /// Creates package configuration.
  const PackageConfig({
    required this.options,
    required this.identity,
    required this.layer,
    required this.pkgId,
    required this.deps,
    required this.srcFilesCount,
  });

  /// Generator options.
  final GeneratorOptions options;

  /// Module identity.
  final ModuleIdentity identity;

  /// Layer index (0..layers-1).
  final int layer;

  /// Unique package id.
  final int pkgId;

  /// Direct package dependencies.
  final List<int> deps;

  /// Number of src files in this package.
  final int srcFilesCount;

  /// Package root directory path.
  String get pkgDir => '${options.outputPath}/packages/pkg$pkgId';

  /// Whether this is a leaf-layer package.
  bool get isLeaf => layer == options.layers - 1;
}

/// Configuration for writing a single src file.
final class SrcFileConfig {
  /// Creates src file configuration.
  const SrcFileConfig({
    required this.packageConfig,
    required this.fileIndex,
    required this.targetLines,
    required this.seedVal,
  });

  /// Owning package configuration.
  final PackageConfig packageConfig;

  /// File index within package.
  final int fileIndex;

  /// Target lines for this file.
  final int targetLines;

  /// Deterministic seed value for method bodies.
  final int seedVal;

  /// Package directory.
  String get pkgDir => packageConfig.pkgDir;

  /// Package id.
  int get pkgId => packageConfig.pkgId;

  /// Whether this file carries an edit hook.
  bool get hasHook =>
      (packageConfig.layer == 0 && fileIndex == 0) ||
      (packageConfig.isLeaf && fileIndex == 0);

  /// Hook return value.
  int get hookVal => packageConfig.layer == 0 ? 1 : 10;
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

Map<int, List<int>> _computePackageDeps(int layers, int fanout, Random rng) {
  final packageDeps = <int, List<int>>{};
  for (var l = 0; l < layers; l++) {
    for (var f = 0; f < fanout; f++) {
      final pkgId = l * fanout + f;
      if (l == 0) {
        packageDeps[pkgId] = const [];
      } else {
        final deps = <int>[];
        final primary = (l - 1) * fanout + (f % fanout);
        deps.add(primary);

        if (l > 1 && rng.nextBool()) {
          final maxLowerPkg = (l - 1) * fanout;
          final sec = rng.nextInt(maxLowerPkg);
          if (!deps.contains(sec)) deps.add(sec);
        }
        packageDeps[pkgId] = deps;
      }
    }
  }
  return packageDeps;
}

int _computeBoilerplateLines({
  required int fanout,
  required int totalPackages,
  required int srcCount,
  required Map<int, List<int>> packageDeps,
}) {
  final appLines = 2 * fanout + 5;
  final leafTestLines = 8 * fanout;
  var entryLinesTotal = 0;
  for (var p = 0; p < totalPackages; p++) {
    final d = packageDeps[p]!;
    entryLinesTotal += d.isEmpty
        ? 3 * srcCount + 7
        : 3 * srcCount + 2 * d.length + 8;
  }
  return appLines + leafTestLines + entryLinesTotal;
}

void _generatePackagesAndApp(
  GeneratorOptions options,
  ModuleIdentity identity,
) {
  final totalPackages = options.layers * options.fanout;
  final srcCount = max(1, min(10, (options.targetLoc ~/ totalPackages) ~/ 250));
  final rng = Random(options.seed);
  final packageDeps = _computePackageDeps(options.layers, options.fanout, rng);

  final boilerplate = _computeBoilerplateLines(
    fanout: options.fanout,
    totalPackages: totalPackages,
    srcCount: srcCount,
    packageDeps: packageDeps,
  );
  final totalSrcFiles = totalPackages * srcCount;
  final remaining = max(totalSrcFiles * 13, options.targetLoc - boilerplate);
  final basePerFile = remaining ~/ totalSrcFiles;
  final remPerFile = remaining % totalSrcFiles;

  var fileCounter = 0;
  for (var l = 0; l < options.layers; l++) {
    for (var f = 0; f < options.fanout; f++) {
      final pkgId = l * options.fanout + f;
      final config = PackageConfig(
        options: options,
        identity: identity,
        layer: l,
        pkgId: pkgId,
        deps: packageDeps[pkgId]!,
        srcFilesCount: srcCount,
      );

      _writePackageBuildFile(config);

      for (var s = 0; s < srcCount; s++) {
        final targetLines = basePerFile + (fileCounter < remPerFile ? 1 : 0);
        fileCounter++;
        final minLines = (l == 0 && s == 0) || (config.isLeaf && s == 0)
            ? 18
            : 13;
        _writeSrcFile(
          SrcFileConfig(
            packageConfig: config,
            fileIndex: s,
            targetLines: max(minLines, targetLines),
            seedVal: rng.nextInt(1000),
          ),
        );
      }

      _writePackageEntryFile(config);
      if (config.isLeaf) {
        _writePackageTestFile(config.pkgDir, pkgId);
      }
    }
  }

  _writeApp(options, identity);
}

void _writePackageBuildFile(PackageConfig config) {
  final pkgDir = Directory(config.pkgDir)..createSync(recursive: true);
  final depLabels = config.deps
      .map((d) => '        "//packages/pkg$d",')
      .join('\n');
  final testTarget = config.isLeaf
      ? '''
dart_test(
    name = "pkg${config.pkgId}_test",
    size = "small",
    main = "test/pkg${config.pkgId}_test.dart",
    deps = [
        ":pkg${config.pkgId}",
        "@pub_deps//:test",
    ],
)
'''
      : '';

  final buildContent =
      '''
load("@${config.identity.repoName}//dart:defs.bzl", "dart_library"${config.isLeaf ? ', "dart_test"' : ''})

dart_library(
    name = "pkg${config.pkgId}",
    srcs = glob(["lib/**/*.dart"]),
    visibility = ["//visibility:public"],
    deps = [
$depLabels
    ],
)
$testTarget''';
  File('${pkgDir.path}/BUILD.bazel').writeAsStringSync(buildContent);
}

void _writePackageEntryFile(PackageConfig config) {
  final exports = List.generate(
    config.srcFilesCount,
    (i) => "export 'src/f$i.dart';",
  ).join('\n');
  final imports = List.generate(
    config.srcFilesCount,
    (i) => "import 'src/f$i.dart';",
  ).join('\n');

  final depImports = config.deps
      .map((d) => "import 'package:pkg$d/pkg$d.dart';")
      .join('\n');
  final depSection = config.deps.isNotEmpty ? '$depImports\n\n' : '';

  final fileCalls = List.generate(
    config.srcFilesCount,
    (i) => '  acc += fn${config.pkgId}x$i(x);',
  ).join('\n');
  final depCalls = config.deps.isEmpty
      ? ''
      : '${config.deps.map((d) => '  acc += pkg${d}_entry(x);').join('\n')}\n';

  final entryContent =
      '''
$exports

$depSection$imports

/// Entry function for package ${config.pkgId}.
int pkg${config.pkgId}_entry(int x) {
  var acc = x;
$fileCalls
$depCalls  return acc;
}
''';
  File('${config.pkgDir}/lib/pkg${config.pkgId}.dart')
      .writeAsStringSync(entryContent);
}

void _writePackageTestFile(String pkgDir, int pkgId) {
  final testDir = Directory('$pkgDir/test')..createSync(recursive: true);
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
  File('${testDir.path}/pkg${pkgId}_test.dart').writeAsStringSync(testContent);
}

void _writeSrcFile(SrcFileConfig config) {
  final lines = <String>[
    '/// Class for pkg ${config.pkgId} file ${config.fileIndex}.',
    'class C${config.pkgId}x${config.fileIndex} {',
    '  /// Constructor.',
    '  const C${config.pkgId}x${config.fileIndex}(this.value);',
    '',
    '  /// Value field.',
    '  final int value;',
  ];
  if (config.hasHook) {
    final hookName = config.pkgId == 0 ? 'bodyHook' : 'leafTestHook';
    lines.addAll([
      '',
      '  /// Hook for edit.',
      '  int $hookName() {',
      '    return ${config.hookVal};',
      '  }',
    ]);
  }

  final fixedSoFar = lines.length;
  const footerLines = 6;
  final neededExtra = max(0, config.targetLines - (fixedSoFar + footerLines));

  final numMethods = neededExtra ~/ 9;
  final remFillers = neededExtra % 9;

  for (var m = 0; m < numMethods; m++) {
    lines.addAll([
      '',
      '  /// Method $m.',
      '  int m$m(int x) {',
      '    var acc = x + $m + ${config.seedVal};',
      '    for (var j = 0; j < 3; j++) {',
      '      acc += j;',
      '    }',
      '    return acc;',
      '  }',
    ]);
  }

  for (var fill = 0; fill < remFillers; fill++) {
    lines.add('  // Line filler $fill.');
  }

  lines.addAll([
    '}',
    '',
    '/// Function for pkg ${config.pkgId} file ${config.fileIndex}.',
    'int fn${config.pkgId}x${config.fileIndex}(int x) {',
    '  return const C${config.pkgId}x${config.fileIndex}(0).value + x;',
    '}',
  ]);

  final srcDir = Directory('${config.pkgDir}/lib/src')
    ..createSync(recursive: true);
  File('${srcDir.path}/f${config.fileIndex}.dart')
      .writeAsStringSync('${lines.join('\n')}\n');
}

void _writeApp(GeneratorOptions options, ModuleIdentity identity) {
  final appDir = Directory('${options.outputPath}/app')
    ..createSync(recursive: true);

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

  final binDir = Directory('${appDir.path}/bin')..createSync(recursive: true);
  final imports = leafPkgIds
      .map((id) => "import 'package:pkg$id/pkg$id.dart';")
      .join('\n');
  final sumLines = leafPkgIds
      .map((id) => '  total += pkg${id}_entry(1);')
      .join('\n');

  final mainContent =
      '''
$imports

void main() {
  var total = 0;
$sumLines
  print('Result: \$total');
}
''';
  File('${binDir.path}/main.dart').writeAsStringSync(mainContent);
}
