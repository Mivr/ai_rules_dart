/// Workspace SDK toolchain resolution and lowest-level compiler chains.
library;

import 'dart:io';

import 'cli_args.dart';

String _requireToolFile(String path, String toolName) {
  if (!File(path).existsSync()) {
    throw StateError('Missing SDK tool: $toolName not found at $path');
  }
  return resolveCliPath(path);
}

/// Binaries provided by the Dart SDK.
final class SdkBinaries {
  /// Creates an SDK binaries record.
  const SdkBinaries({
    required this.dart,
    required this.dartaotruntime,
    required this.genSnapshot,
  });

  /// Path to the `dart` VM executable.
  final String dart;

  /// Path to the `dartaotruntime` executable.
  final String dartaotruntime;

  /// Path to the `gen_snapshot` binary.
  final String genSnapshot;
}

/// Snapshots and platform dills provided by the Dart SDK.
final class SdkSnapshots {
  /// Creates an SDK snapshots record.
  const SdkSnapshots({
    required this.genKernelSnapshot,
    required this.frontendServerSnapshot,
    required this.platformProductDill,
    required this.platformStrongDill,
  });

  /// Path to `gen_kernel_aot.dart.snapshot`.
  final String genKernelSnapshot;

  /// Path to `frontend_server_aot.dart.snapshot` (or JIT snapshot fallback).
  final String frontendServerSnapshot;

  /// Path to `vm_platform_product.dill`.
  final String platformProductDill;

  /// Path to `vm_platform_strong.dill`.
  final String platformStrongDill;
}

/// Resolved SDK binaries and platform snapshots.
final class SdkTools {
  /// Creates an SDK tools record.
  const SdkTools({
    required this.sdkRoot,
    required this.binaries,
    required this.snapshots,
  });

  /// Root directory of the SDK.
  final String sdkRoot;

  /// SDK executable binaries.
  final SdkBinaries binaries;

  /// SDK snapshots and platform libraries.
  final SdkSnapshots snapshots;

  /// Path to the `dart` VM executable.
  String get dart => binaries.dart;

  /// Path to the `dartaotruntime` executable.
  String get dartaotruntime => binaries.dartaotruntime;

  /// Path to the `gen_snapshot` binary.
  String get genSnapshot => binaries.genSnapshot;

  /// Path to `gen_kernel_aot.dart.snapshot`.
  String get genKernelSnapshot => snapshots.genKernelSnapshot;

  /// Path to `frontend_server_aot.dart.snapshot` (or JIT snapshot fallback).
  String get frontendServerSnapshot => snapshots.frontendServerSnapshot;

  /// Path to `vm_platform_product.dill`.
  String get platformProductDill => snapshots.platformProductDill;

  /// Path to `vm_platform_strong.dill`.
  String get platformStrongDill => snapshots.platformStrongDill;

  /// Resolves all required SDK tools from [sdkDir], throwing if any is missing.
  static SdkTools fromSdkDir(String sdkDir) {
    final normSdk = resolveCliPath(sdkDir);
    final isWin = Platform.isWindows;
    final exeExt = isWin ? '.exe' : '';

    final dartPath = '$normSdk/bin/dart$exeExt';
    final aotPath = '$normSdk/bin/dartaotruntime$exeExt';
    final gsPath = '$normSdk/bin/utils/gen_snapshot$exeExt';
    final gkPath = '$normSdk/bin/snapshots/gen_kernel_aot.dart.snapshot';

    var fsPath = '$normSdk/bin/snapshots/frontend_server_aot.dart.snapshot';
    if (!File(fsPath).existsSync()) {
      final jitFs = '$normSdk/bin/snapshots/frontend_server.dart.snapshot';
      if (File(jitFs).existsSync()) {
        fsPath = jitFs;
      }
    }

    final prodDill = '$normSdk/lib/_internal/vm_platform_product.dill';
    final strongDill = '$normSdk/lib/_internal/vm_platform_strong.dill';

    return SdkTools(
      sdkRoot: normSdk,
      binaries: SdkBinaries(
        dart: _requireToolFile(dartPath, 'dart'),
        dartaotruntime: _requireToolFile(aotPath, 'dartaotruntime'),
        genSnapshot: _requireToolFile(gsPath, 'gen_snapshot'),
      ),
      snapshots: SdkSnapshots(
        genKernelSnapshot: _requireToolFile(gkPath, 'gen_kernel_aot'),
        frontendServerSnapshot: _requireToolFile(fsPath, 'frontend_server'),
        platformProductDill: _requireToolFile(
          prodDill,
          'vm_platform_product.dill',
        ),
        platformStrongDill: _requireToolFile(
          strongDill,
          'vm_platform_strong.dill',
        ),
      ),
    );
  }

  /// Discovers the resolved SDK root from [outputBase] and [execroot].
  static SdkTools discover({
    required String outputBase,
    required String execroot,
  }) {
    final candidateDirs = <String>[];
    for (final base in [outputBase, execroot]) {
      final ext = Directory('$base/external');
      if (ext.existsSync()) {
        try {
          for (final entity in ext.listSync(followLinks: false)) {
            candidateDirs.add(entity.path);
          }
        } on FileSystemException catch (e) {
          stderr.writeln('External dir listing skipped ($base): $e');
        }
      }
    }

    candidateDirs.sort((a, b) {
      final aDart = a.toLowerCase().contains('dart') ? 0 : 1;
      final bDart = b.toLowerCase().contains('dart') ? 0 : 1;
      return aDart.compareTo(bDart);
    });

    final isWin = Platform.isWindows;
    final exeExt = isWin ? '.exe' : '';
    for (final dir in candidateDirs) {
      final hasDart = File('$dir/bin/dart$exeExt').existsSync();
      final hasAot = File('$dir/bin/dartaotruntime$exeExt').existsSync();
      if (hasDart && hasAot) {
        try {
          return SdkTools.fromSdkDir(dir);
        } on StateError catch (e) {
          stderr.writeln('Candidate SDK dir $dir incomplete: $e');
        }
      }
    }

    throw StateError(
      'Could not locate workspace Dart SDK in $outputBase/external or $execroot/external',
    );
  }
}

/// A single process step within a toolchain floor chain.
final class ToolchainStep {
  /// Creates a toolchain execution step.
  const ToolchainStep({
    required this.executable,
    required this.arguments,
    this.workingDirectory,
    this.environment = const {},
  });

  /// Executable to run.
  final String executable;

  /// Command arguments.
  final List<String> arguments;

  /// Working directory for execution.
  final String? workingDirectory;

  /// Environment variables.
  final Map<String, String> environment;
}

/// Specification for building the AOT toolchain floor chain.
final class AppAotChainSpec {
  /// Creates an AOT chain specification.
  const AppAotChainSpec({
    required this.sdk,
    required this.entrypoint,
    required this.outputDill,
    required this.outputAot,
    this.packageConfig,
    this.workingDirectory,
    this.filesystemScheme,
    this.filesystemRoots = const [],
  });

  /// SDK tool paths.
  final SdkTools sdk;

  /// Multi-root URI scheme the entrypoint and package config use, if any.
  final String? filesystemScheme;

  /// Roots of [filesystemScheme], relative to [workingDirectory].
  final List<String> filesystemRoots;

  /// Source entrypoint path or scheme URI.
  final String entrypoint;

  /// Destination path for kernel dill.
  final String outputDill;

  /// Destination path for AOT snapshot output.
  final String outputAot;

  /// Optional package configuration file.
  final String? packageConfig;

  /// Working directory.
  final String? workingDirectory;
}

/// Builds the two-step AOT chain: `gen_kernel_aot` via `dartaotruntime`, then `gen_snapshot`.
List<ToolchainStep> buildAppAotChain(AppAotChainSpec spec) {
  final step1 = ToolchainStep(
    executable: spec.sdk.dartaotruntime,
    arguments: [
      spec.sdk.genKernelSnapshot,
      '--platform',
      spec.sdk.platformProductDill,
      if (spec.packageConfig != null && spec.packageConfig!.isNotEmpty) ...[
        '--packages',
        spec.packageConfig!,
      ],
      if (spec.filesystemScheme != null) ...[
        '--filesystem-scheme',
        spec.filesystemScheme!,
        for (final root in spec.filesystemRoots) ...['--filesystem-root', root],
      ],
      '--aot',
      '--tfa',
      '-Ddart.vm.product=true',
      '--no-embed-sources',
      '-o',
      spec.outputDill,
      spec.entrypoint,
    ],
    workingDirectory: spec.workingDirectory,
  );

  final step2 = ToolchainStep(
    executable: spec.sdk.genSnapshot,
    arguments: [
      '--deterministic',
      '--snapshot_kind=app-aot-elf',
      '--elf=${spec.outputAot}',
      spec.outputDill,
    ],
    workingDirectory: spec.workingDirectory,
  );

  return [step1, step2];
}

/// Specification for resident incremental compiler startup.
final class IncrementalCompilerSpec {
  /// Creates an incremental compiler specification.
  const IncrementalCompilerSpec({
    required this.sdk,
    required this.outputDill,
    this.packageConfig,
    this.workingDirectory,
    this.filesystemScheme,
    this.filesystemRoots = const [],
  });

  /// SDK tool paths.
  final SdkTools sdk;

  /// Multi-root URI scheme the compiled sources use, if any.
  final String? filesystemScheme;

  /// Roots of [filesystemScheme], relative to [workingDirectory].
  final List<String> filesystemRoots;

  /// Base output dill path.
  final String outputDill;

  /// Optional package configuration file.
  final String? packageConfig;

  /// Working directory.
  final String? workingDirectory;
}

/// Builds the startup step for the resident frontend server in incremental mode.
ToolchainStep buildIncrementalCompilerStep(IncrementalCompilerSpec spec) {
  return ToolchainStep(
    executable: spec.sdk.dartaotruntime,
    arguments: [
      spec.sdk.frontendServerSnapshot,
      '--sdk-root=${spec.sdk.sdkRoot}',
      '--incremental',
      '--platform=${spec.sdk.platformStrongDill}',
      if (spec.packageConfig != null && spec.packageConfig!.isNotEmpty)
        '--packages=${spec.packageConfig}',
      if (spec.filesystemScheme != null) ...[
        '--filesystem-scheme=${spec.filesystemScheme}',
        for (final root in spec.filesystemRoots) '--filesystem-root=$root',
      ],
      '--output-dill=${spec.outputDill}',
      '--target=vm',
    ],
    workingDirectory: spec.workingDirectory,
  );
}

/// The `--precompiled` directory and test path a prebuilt test kernel holds,
/// or null when [dill] does not sit in that layout.
///
/// The rules declare the kernel at
/// `<name>.precompiled/<testPath>.vm_test.vm.app.dill`, which is where the
/// package:test runner looks for it.
({String precompiled, String testPath})? splitPrecompiledDill(String dill) {
  const suffix = '.vm_test.vm.app.dill';
  final path = dill.replaceAll(r'\', '/');
  final marker = path.indexOf('.precompiled/');
  if (marker == -1 || !path.endsWith(suffix)) return null;
  final dirEnd = marker + '.precompiled'.length;
  return (
    precompiled: path.substring(0, dirEnd),
    testPath: path.substring(dirEnd + 1, path.length - suffix.length),
  );
}

/// Builds the SDK test runner step (`dart test`) on a prebuilt test kernel.
///
/// A kernel outside the `.precompiled` layout is handed to the VM directly.
ToolchainStep buildTestRunnerStep({
  required SdkTools sdk,
  required String testDill,
  String? workingDirectory,
}) {
  final parts = splitPrecompiledDill(testDill);
  return ToolchainStep(
    executable: sdk.dart,
    arguments: parts == null
        ? [testDill]
        : [
            'test',
            '--precompiled=${parts.precompiled}',
            '--reporter=expanded',
            parts.testPath,
          ],
    workingDirectory: workingDirectory,
  );
}
