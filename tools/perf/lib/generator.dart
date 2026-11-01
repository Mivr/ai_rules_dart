/// Deterministic layered Dart monorepo generator for rules_dart benchmarks.
library;

import 'dart:io';
import 'dart:math';

import 'cli_args.dart';
import 'generator_sources.dart';

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

int _scanTripleQuoted(
  String content,
  int start,
  String delim,
  StringBuffer out,
) {
  out.write('   ');
  var i = start + 3;
  var escaped = false;
  while (i < content.length) {
    if (!escaped && content.startsWith(delim, i)) {
      out.write('   ');
      return i + 3;
    }
    final ch = content[i];
    out.write(ch == '\n' ? '\n' : ' ');
    escaped = !escaped && ch == r'\';
    i++;
  }
  return i;
}

int _scanSingleQuoted(
  String content,
  int start,
  String quote,
  StringBuffer out,
) {
  out.write(quote);
  var i = start + 1;
  var escaped = false;
  while (i < content.length) {
    final ch = content[i];
    out.write(ch);
    i++;
    if (escaped) {
      escaped = false;
    } else if (ch == r'\') {
      escaped = true;
    } else if (ch == quote) {
      break;
    }
  }
  return i;
}

String _stripStarlarkComments(String content) {
  final out = StringBuffer();
  var i = 0;
  while (i < content.length) {
    final ch = content[i];
    if (ch == '"' || ch == "'") {
      final triple = '$ch$ch$ch';
      i = content.startsWith(triple, i)
          ? _scanTripleQuoted(content, i, triple, out)
          : _scanSingleQuoted(content, i, ch, out);
    } else if (ch == '#') {
      while (i < content.length && content[i] != '\n') {
        i++;
      }
    } else {
      out.write(ch);
      i++;
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
    r'^\s*module\s*\(([^)]*)\)',
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

File? _findPristineLockFile(String resolvedRulesPath) {
  const candidates = [
    'e2e/dart_test_pkg/pubspec.lock',
    'pubspec.lock',
    'dart/ext/pubspec.lock',
  ];
  for (final rel in candidates) {
    final candidate = File('$resolvedRulesPath/$rel');
    if (candidate.existsSync()) return candidate;
  }
  return null;
}

void _copyPristineFiles(String outputPath, String resolvedRulesPath) {
  final lock = _findPristineLockFile(resolvedRulesPath);
  if (lock != null) {
    lock.copySync('$outputPath/pubspec.lock');
  } else {
    File('$outputPath/pubspec.lock').writeAsStringSync('packages: {}\n');
  }

  final yaml = File('$resolvedRulesPath/e2e/dart_test_pkg/pubspec.yaml');
  if (yaml.existsSync()) {
    yaml.copySync('$outputPath/pubspec.yaml');
  } else {
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

void _generatePackagesAndApp(
  GeneratorOptions options,
  ModuleIdentity identity,
) {
  final totalPackages = options.layers * options.fanout;
  final srcCount = max(1, min(10, (options.targetLoc ~/ totalPackages) ~/ 250));
  final rng = Random(options.seed);
  final packageDeps = _computePackageDeps(options.layers, options.fanout, rng);
  final (mode, budgets) = planSrcLineBudgets(
    targetLoc: options.targetLoc,
    layers: options.layers,
    fanout: options.fanout,
    srcCount: srcCount,
    packageDeps: packageDeps,
  );

  var fileCounter = 0;
  for (var l = 0; l < options.layers; l++) {
    final isLeaf = l == options.layers - 1;
    for (var f = 0; f < options.fanout; f++) {
      final pkgId = l * options.fanout + f;
      final isHookPkg = pkgId == 0 || isLeaf;
      final pkgSrcCount = mode == LayoutMode.ultraCompact
          ? (isHookPkg ? 1 : 0)
          : srcCount;
      final plan = PackagePlan(
        pkgDir: '${options.outputPath}/packages/pkg$pkgId',
        pkgId: pkgId,
        isLeaf: isLeaf,
        deps: packageDeps[pkgId]!,
        srcFilesCount: pkgSrcCount,
        inlineSeed: pkgSrcCount == 0 ? rng.nextInt(900) + 1 : 0,
      );

      _writePackageBuildFile(plan, identity.repoName);

      for (var s = 0; s < pkgSrcCount; s++) {
        writeSrcFile(
          SrcFilePlan(
            pkgPlan: plan,
            fileIndex: s,
            targetLines: budgets[fileCounter++],
            seedVal: rng.nextInt(900) + 1,
            ultraCompact: mode == LayoutMode.ultraCompact,
          ),
        );
      }

      writePackageEntryFile(plan, mode);
      if (isLeaf) {
        writePackageTestFile(plan.pkgDir, pkgId);
      }
    }
  }

  _writeApp(options, identity);
}

void _writePackageBuildFile(PackagePlan plan, String repoName) {
  final pkgDir = Directory(plan.pkgDir)..createSync(recursive: true);
  final depLabels = plan.deps
      .map((d) => '        "//packages/pkg$d",')
      .join('\n');
  final testTarget = plan.isLeaf
      ? '''

dart_test(
    name = "pkg${plan.pkgId}_test",
    size = "small",
    main = "test/pkg${plan.pkgId}_test.dart",
    deps = [
        ":pkg${plan.pkgId}",
        "@pub_deps//:test",
    ],
)
'''
      : '';

  final depsBlock = plan.deps.isEmpty
      ? '    deps = [],'
      : '    deps = [\n$depLabels\n    ],';

  final buildContent =
      '''
load("@$repoName//dart:defs.bzl", "dart_library"${plan.isLeaf ? ', "dart_test"' : ''})

dart_library(
    name = "pkg${plan.pkgId}",
    srcs = glob(["lib/**/*.dart"]),
    visibility = ["//visibility:public"],
$depsBlock
)
$testTarget''';
  File('${pkgDir.path}/BUILD.bazel').writeAsStringSync(buildContent);
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
