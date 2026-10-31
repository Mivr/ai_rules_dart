/// Deterministic layered Dart monorepo generator for rules_dart benchmarks.
library;

import 'dart:io';
import 'dart:math';

import 'cli_args.dart';

/// Parsed module identity from a Bazel MODULE.bazel file.
final class ModuleIdentity {
  /// Creates a module identity.
  const ModuleIdentity({
    required this.moduleName,
    required this.repoName,
    this.dartVersion = '3.13.5',
  });

  /// The Bazel module name.
  final String moduleName;

  /// The Bazel repository name (defaults to moduleName).
  final String repoName;

  /// The Dart SDK version from `dart.toolchain(...)` (defaults to 3.13.5).
  final String dartVersion;
}

String _stripStarlarkComments(String content) {
  final out = StringBuffer();
  String? quote;
  var escaped = false;
  for (var i = 0; i < content.length; i++) {
    final ch = content[i];
    if (quote != null) {
      out.write(ch);
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == quote) {
        quote = null;
      }
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
      out.write(ch);
    } else if (ch == '#') {
      while (i < content.length && content[i] != '\n') {
        i++;
      }
      if (i < content.length) out.write('\n');
    } else {
      out.write(ch);
    }
  }
  return out.toString();
}

String? _extractDartToolchainVersion(String cleanedContent) {
  final sdkMatch = RegExp(
    r'''\bdart\.toolchain\s*\([^)]*?\bdart_version\s*=\s*["']([^"']+)["']''',
    multiLine: true,
    dotAll: true,
  ).firstMatch(cleanedContent);
  return sdkMatch?.group(1);
}

/// Parses `module(name = "...", repo_name = "...")` from MODULE.bazel text.
ModuleIdentity parseModuleHeader(
  String content, {
  String fallbackContent = '',
}) {
  final cleaned = _stripStarlarkComments(content);
  final cleanedFallback = fallbackContent.isEmpty
      ? ''
      : _stripStarlarkComments(fallbackContent);
  final dartVersion =
      _extractDartToolchainVersion(cleaned) ??
      _extractDartToolchainVersion(cleanedFallback) ??
      '3.13.5';

  final match = RegExp(
    r'\bmodule\s*\(([^)]*)\)',
    multiLine: true,
    dotAll: true,
  ).firstMatch(cleaned);
  if (match == null) {
    return ModuleIdentity(
      moduleName: 'rules_dart',
      repoName: 'rules_dart',
      dartVersion: dartVersion,
    );
  }

  final body = match.group(1) ?? '';
  final nameMatch = RegExp(r'''\bname\s*=\s*["']([^"']+)["']''')
      .firstMatch(body);
  final repoMatch = RegExp(r'''\brepo_name\s*=\s*["']([^"']+)["']''')
      .firstMatch(body);

  final moduleName = nameMatch?.group(1) ?? 'rules_dart';
  final repoName = repoMatch?.group(1) ?? moduleName;

  return ModuleIdentity(
    moduleName: moduleName,
    repoName: repoName,
    dartVersion: dartVersion,
  );
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

  /// Deterministic positive seed offset for method bodies.
  final int seedVal;

  /// Package directory.
  String get pkgDir => packageConfig.pkgDir;

  /// Package id.
  int get pkgId => packageConfig.pkgId;

  /// Whether this file carries an edit hook.
  bool get hasHook =>
      (pkgId == 0 && fileIndex == 0) ||
      (packageConfig.isLeaf && fileIndex == 0);

  /// Hook method name when [hasHook] is true.
  String get hookName => packageConfig.layer == 0 ? 'bodyHook' : 'leafTestHook';

  /// Hook initial return value.
  int get hookVal => packageConfig.layer == 0 ? 1 : 10;
}

void _validateOptions(GeneratorOptions options) {
  if (options.targetLoc <= 0) {
    throw ArgumentError.value(
      options.targetLoc,
      'targetLoc',
      'must be positive',
    );
  }
  if (options.layers < 2) {
    throw ArgumentError.value(options.layers, 'layers', 'must be at least 2');
  }
  if (options.fanout < 1) {
    throw ArgumentError.value(options.fanout, 'fanout', 'must be positive');
  }
}

/// Generates a layered benchmark workspace.
void generateWorkspace(GeneratorOptions options) {
  _validateOptions(options);
  final resolvedRulesPath = resolveCliPath(options.rulesDartPath);
  final outDir = Directory(options.outputPath);
  if (outDir.existsSync()) outDir.deleteSync(recursive: true);
  outDir.createSync(recursive: true);

  final moduleFile = File('$resolvedRulesPath/MODULE.bazel');
  final moduleContent = moduleFile.existsSync()
      ? moduleFile.readAsStringSync()
      : '';
  final e2eModuleFile = File(
    '$resolvedRulesPath/e2e/dart_test_pkg/MODULE.bazel',
  );
  final fallbackContent = e2eModuleFile.existsSync()
      ? e2eModuleFile.readAsStringSync()
      : '';
  final identity = parseModuleHeader(
    moduleContent,
    fallbackContent: fallbackContent,
  );

  _writeModuleBazel(options.outputPath, identity, resolvedRulesPath);
  _copyPristineFiles(options.outputPath, resolvedRulesPath);
  _writeRootBuild(options.outputPath);
  _generatePackagesAndApp(options, identity);
}

void _writeModuleBazel(
  String outputPath,
  ModuleIdentity identity,
  String resolvedRulesPath,
) {
  final repoArg = identity.repoName != identity.moduleName
      ? ', repo_name = "${identity.repoName}"'
      : '';
  final normRulesPath = resolvedRulesPath.replaceAll(r'\', '/');

  final content =
      '''
module(name = "bench")

bazel_dep(name = "${identity.moduleName}", version = "0.0.0"$repoArg)
local_path_override(
    module_name = "${identity.moduleName}",
    path = "$normRulesPath",
)

dart = use_extension("@${identity.repoName}//dart:extensions.bzl", "dart")
dart.toolchain(dart_version = "${identity.dartVersion}")
use_repo(dart, "dart_toolchains")
register_toolchains("@dart_toolchains//:all")

pub = use_extension("@${identity.repoName}//dart/pub:extensions.bzl", "pub")
pub.from_lock(
    name = "pub_deps",
    lock = "//:pubspec.lock",
)
use_repo(pub, "pub_deps")
''';

  File('$outputPath/MODULE.bazel').writeAsStringSync(content);
}

void _copyPristineFiles(String outputPath, String resolvedRulesPath) {
  final lock = File('$resolvedRulesPath/e2e/dart_test_pkg/pubspec.lock');
  if (lock.existsSync()) {
    lock.copySync('$outputPath/pubspec.lock');
  }

  final yaml = File('$resolvedRulesPath/e2e/dart_test_pkg/pubspec.yaml');
  if (yaml.existsSync()) {
    yaml.copySync('$outputPath/pubspec.yaml');
  } else if (lock.existsSync()) {
    File('$outputPath/pubspec.yaml').writeAsStringSync(
      'name: bench\nenvironment:\n  sdk: ^3.0.0\ndev_dependencies:\n  test: any\n',
    );
  }

  final bazelver = File('$resolvedRulesPath/.bazelversion');
  if (bazelver.existsSync()) {
    bazelver.copySync('$outputPath/.bazelversion');
  }
}

void _writeRootBuild(String outputPath) {
  const content = '''
exports_files([
    "pubspec.lock",
    "pubspec.yaml",
])
''';
  File('$outputPath/BUILD.bazel').writeAsStringSync(content);
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
        deps.sort();
        packageDeps[pkgId] = deps;
      }
    }
  }
  return packageDeps;
}

int _entryFileLines(
  int pkgId,
  int srcCount,
  int depCount, {
  required bool compactEntry,
}) {
  if (compactEntry && pkgId != 0) {
    return depCount == 0 ? 4 : depCount + 5;
  }
  return depCount == 0 ? 2 * srcCount + 6 : 2 * srcCount + 2 * depCount + 7;
}

int _computeBoilerplateLines({
  required int fanout,
  required int totalPackages,
  required int srcCount,
  required Map<int, List<int>> packageDeps,
  required bool compactEntry,
}) {
  final appLines = 2 * fanout + 7;
  final leafTestLines = 8 * fanout;
  var entryLinesTotal = 0;
  for (var p = 0; p < totalPackages; p++) {
    final d = packageDeps[p]!;
    entryLinesTotal += _entryFileLines(
      p,
      srcCount,
      d.length,
      compactEntry: compactEntry,
    );
  }
  return appLines + leafTestLines + entryLinesTotal;
}

(bool, List<int>) _planSrcLineBudgets({
  required GeneratorOptions options,
  required int srcCount,
  required Map<int, List<int>> packageDeps,
}) {
  final totalPackages = options.layers * options.fanout;
  final isHookFile = <bool>[];
  for (var l = 0; l < options.layers; l++) {
    final isLeaf = l == options.layers - 1;
    for (var f = 0; f < options.fanout; f++) {
      final pkgId = l * options.fanout + f;
      for (var s = 0; s < srcCount; s++) {
        isHookFile.add((pkgId == 0 && s == 0) || (isLeaf && s == 0));
      }
    }
  }

  final stdBoilerplate = _computeBoilerplateLines(
    fanout: options.fanout,
    totalPackages: totalPackages,
    srcCount: srcCount,
    packageDeps: packageDeps,
    compactEntry: false,
  );
  final stdMinSrc = isHookFile.fold<int>(0, (sum, h) => sum + (h ? 19 : 13));
  final useCompact =
      srcCount == 1 && options.targetLoc < (stdBoilerplate + stdMinSrc);

  final boilerplate = useCompact
      ? _computeBoilerplateLines(
          fanout: options.fanout,
          totalPackages: totalPackages,
          srcCount: srcCount,
          packageDeps: packageDeps,
          compactEntry: true,
        )
      : stdBoilerplate;

  final minLines = [
    for (final h in isHookFile)
      h ? (useCompact ? 13 : 19) : (useCompact ? 2 : 13),
  ];
  final minSum = minLines.fold<int>(0, (a, b) => a + b);
  final extraTotal = max(0, options.targetLoc - boilerplate - minSum);
  final baseExtra = extraTotal ~/ minLines.length;
  final remExtra = extraTotal % minLines.length;

  final budgets = List<int>.generate(
    minLines.length,
    (i) => minLines[i] + baseExtra + (i < remExtra ? 1 : 0),
  );
  return (useCompact, budgets);
}

void _generatePackagesAndApp(
  GeneratorOptions options,
  ModuleIdentity identity,
) {
  final totalPackages = options.layers * options.fanout;
  final srcCount = max(1, min(10, (options.targetLoc ~/ totalPackages) ~/ 250));
  final rng = Random(options.seed);
  final packageDeps = _computePackageDeps(options.layers, options.fanout, rng);
  final (useCompact, budgets) = _planSrcLineBudgets(
    options: options,
    srcCount: srcCount,
    packageDeps: packageDeps,
  );

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
        _writeSrcFile(
          SrcFileConfig(
            packageConfig: config,
            fileIndex: s,
            targetLines: budgets[fileCounter++],
            seedVal: rng.nextInt(900) + 1,
          ),
        );
      }

      _writePackageEntryFile(config, compactEntry: useCompact);
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

  final depsBlock = config.deps.isEmpty
      ? '    deps = [],'
      : '    deps = [\n$depLabels\n    ],';

  final buildContent =
      '''
load("@${config.identity.repoName}//dart:defs.bzl", "dart_library"${config.isLeaf ? ', "dart_test"' : ''})

dart_library(
    name = "pkg${config.pkgId}",
    srcs = glob(["lib/**/*.dart"]),
    visibility = ["//visibility:public"],
$depsBlock
)
$testTarget''';
  File('${pkgDir.path}/BUILD.bazel').writeAsStringSync(buildContent);
}

void _writePackageEntryFile(
  PackageConfig config, {
  required bool compactEntry,
}) {
  final depImports =
      config.deps.map((d) => "import 'package:pkg$d/pkg$d.dart';").toList()
        ..sort();
  final relImports = List.generate(
    config.srcFilesCount,
    (i) => "import 'src/f$i.dart';",
  )..sort();

  final depImportBlock = depImports.isNotEmpty
      ? '${depImports.join('\n')}\n\n'
      : '';
  final header =
      '$depImportBlock${relImports.join('\n')}\n\n'
      '/// Entry function for package ${config.pkgId}.\n';

  final String body;
  if (compactEntry && config.pkgId != 0) {
    final terms = <String>[
      'x',
      for (var i = 0; i < config.srcFilesCount; i++) 'fn${config.pkgId}x$i(x)',
      for (final d in config.deps) 'pkg${d}Entry(x)',
    ];
    body = 'int pkg${config.pkgId}Entry(int x) => ${terms.join(' + ')};\n';
  } else {
    final fileCalls = List.generate(
      config.srcFilesCount,
      (i) => '  acc += fn${config.pkgId}x$i(x);',
    ).join('\n');
    final depCalls = config.deps.isEmpty
        ? ''
        : '${config.deps.map((d) => '  acc += pkg${d}Entry(x);').join('\n')}\n';
    body =
        'int pkg${config.pkgId}Entry(int x) {\n'
        '  var acc = x;\n'
        '$fileCalls\n'
        '$depCalls'
        '  return acc;\n'
        '}\n';
  }

  File('${config.pkgDir}/lib/pkg${config.pkgId}.dart')
      .writeAsStringSync('$header$body');
}

void _writePackageTestFile(String pkgDir, int pkgId) {
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

List<String> _buildCompactSrcLines(SrcFileConfig config) {
  if (!config.hasHook) {
    return _buildFnLines(
      pkgId: config.pkgId,
      fileIndex: config.fileIndex,
      baseExpr: '${config.seedVal}',
      seedVal: config.seedVal,
      lineCount: config.targetLines,
    );
  }

  final cls = 'C${config.pkgId}x${config.fileIndex}';
  return [
    '/// Class for pkg ${config.pkgId} file ${config.fileIndex}.',
    'class $cls {',
    '  /// Constructor.',
    '  const $cls();',
    '',
    '  /// Hook for edit.',
    '  int ${config.hookName}() {',
    '    return ${config.hookVal};',
    '  }',
    '}',
    '',
    ..._buildFnLines(
      pkgId: config.pkgId,
      fileIndex: config.fileIndex,
      baseExpr: 'const $cls().${config.hookName}() + ${config.seedVal}',
      seedVal: config.seedVal,
      lineCount: config.targetLines - 11,
    ),
  ];
}

List<String> _buildStandardSrcLines(SrcFileConfig config) {
  final cls = 'C${config.pkgId}x${config.fileIndex}';
  final lines = <String>[
    '/// Class for pkg ${config.pkgId} file ${config.fileIndex}.',
    'class $cls {',
    '  /// Constructor.',
    '  const $cls(this.value);',
    '',
    '  /// Value field.',
    '  final int value;',
  ];
  if (config.hasHook) {
    lines.addAll([
      '',
      '  /// Hook for edit.',
      '  int ${config.hookName}() {',
      '    return ${config.hookVal};',
      '  }',
    ]);
  }

  final minTotal = config.hasHook ? 19 : 13;
  final neededExtra = max(0, config.targetLines - minTotal);
  final numMethods = neededExtra ~/ 9;
  final remLines = neededExtra % 9;

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

  final memberExpr = config.hasHook ? '${config.hookName}()' : 'value';
  lines.addAll([
    '}',
    '',
    ..._buildFnLines(
      pkgId: config.pkgId,
      fileIndex: config.fileIndex,
      baseExpr: 'const $cls(${config.seedVal}).$memberExpr',
      seedVal: config.seedVal,
      lineCount: 4 + remLines,
    ),
  ]);
  return lines;
}

void _writeSrcFile(SrcFileConfig config) {
  final minStd = config.hasHook ? 19 : 13;
  final lines = config.targetLines < minStd
      ? _buildCompactSrcLines(config)
      : _buildStandardSrcLines(config);

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
  final imports =
      leafPkgIds.map((id) => "import 'package:pkg$id/pkg$id.dart';").toList()
        ..sort();
  final sumLines = leafPkgIds
      .map((id) => '  total += pkg${id}Entry(1);')
      .join('\n');

  final mainContent =
      '''
import 'dart:io';

${imports.join('\n')}

void main() {
  var total = 0;
$sumLines
  stdout.writeln('Result: \$total');
}
''';
  File('${binDir.path}/main.dart').writeAsStringSync(mainContent);
}
