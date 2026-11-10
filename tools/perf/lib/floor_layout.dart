/// Where the floor chains find the sources, package config and test kernels.
library;

import 'dart:io';

import 'incremental_driver.dart';

/// The multi-root URI scheme the rules compile the workspace under.
const floorScheme = 'org-dartlang-root';

final _binDirPattern = RegExp(r'^(bazel-out/[^/]+/bin)/');

/// How the floor reaches the workspace the Bazel build compiled.
///
/// The generated workspace has no `package_config.json` of its own: Bazel
/// writes one beside the app, naming each package under [floorScheme]. The
/// floor reads that file and resolves the scheme against the same two roots
/// the rules give `gen_kernel` (the exec root and the bin root), so both
/// compile the same sources.
final class FloorLayout {
  const FloorLayout._({
    required this.workingDirectory,
    required this.entrypoint,
    required this.packageConfig,
    required this.scheme,
    required this.roots,
    required this.workspaceDir,
  });

  /// Derives the layout from the Bazel-built [appExecutable].
  ///
  /// A path outside `<execroot>/bazel-out/<cfg>/bin` gives the plain layout:
  /// the sources under [workspaceDir], and no package config unless one sits
  /// beside the executable. Inside the exec root the package config must
  /// exist, and a missing one is an error that names it.
  factory FloorLayout.fromApp({
    required String appExecutable,
    required String workspaceDir,
  }) => FloorLayout._derive(
    executable: appExecutable,
    workspaceDir: workspaceDir,
    configSuffix: '.package_config.json',
    entrypoint: (_) => 'app/bin/main.dart',
    plainEntrypoint: '$workspaceDir/app/bin/main.dart',
  );

  /// Derives the layout of a test from its Bazel-built [testExecutable].
  ///
  /// The entrypoint is the `<name>.vm_test.dart` bootstrap that the rules
  /// write beside the executable, and the package config is the one of the
  /// test's entry module, which names every package the test reaches.
  factory FloorLayout.fromTest({
    required String testExecutable,
    required String workspaceDir,
  }) => FloorLayout._derive(
    executable: testExecutable,
    workspaceDir: workspaceDir,
    configSuffix: '.entry.kmod.package_config.json',
    entrypoint: (binRelative) => '$binRelative.vm_test.dart',
    plainEntrypoint: '$testExecutable.vm_test.dart',
  );

  factory FloorLayout._derive({
    required String executable,
    required String workspaceDir,
    required String configSuffix,
    required String Function(String binRelative) entrypoint,
    required String plainEntrypoint,
  }) {
    final path = executable.replaceAll(r'\', '/');
    final marker = path.indexOf('/bazel-out/');
    final config = '$path$configSuffix';
    if (marker == -1) {
      return FloorLayout._(
        workingDirectory: workspaceDir,
        entrypoint: plainEntrypoint,
        packageConfig: File(config).existsSync() ? config : null,
        scheme: null,
        roots: const [],
        workspaceDir: workspaceDir,
      );
    }
    final execroot = path.substring(0, marker);
    final rel = path.substring(marker + 1);
    final bin = _binDirPattern.firstMatch(rel)?.group(1);
    if (bin == null) {
      throw StateError('Cannot locate the bin directory in $executable');
    }
    if (!File(config).existsSync()) {
      throw StateError('Missing package config for $executable: $config');
    }
    return FloorLayout._(
      workingDirectory: execroot,
      entrypoint:
          '$floorScheme:///${entrypoint(rel.substring(bin.length + 1))}',
      packageConfig: config,
      scheme: floorScheme,
      roots: ['.', bin],
      workspaceDir: workspaceDir,
    );
  }

  /// Directory the compilers run in.
  final String workingDirectory;

  /// Entrypoint of the app, as a path or a scheme URI.
  final String entrypoint;

  /// Package config to compile with, when one exists.
  final String? packageConfig;

  /// Multi-root scheme, or null for plain file paths.
  final String? scheme;

  /// Filesystem roots of [scheme], relative to [workingDirectory].
  final List<String> roots;

  /// The workspace copy the edits are applied to.
  final String workspaceDir;

  /// The URI under which the compilers know the workspace file [path].
  String uriFor(String path) {
    final norm = path.replaceAll(r'\', '/');
    final ws = workspaceDir.replaceAll(r'\', '/');
    if (scheme == null || !norm.startsWith('$ws/')) return norm;
    return '$scheme:///${norm.substring(ws.length + 1)}';
  }
}

/// The command that runs the incremental driver with [flags].
///
/// The driver is compiled into the runner binary, so the runner runs itself;
/// under `dart run` the VM is the executable and the script comes along.
(String, List<String>) incrementalDriverCommand(List<String> flags) {
  final exe = Platform.resolvedExecutable;
  final name = exe.split(RegExp(r'[\\/]')).last.toLowerCase();
  final isVm = name == 'dart' || name == 'dart.exe';
  return (
    exe,
    [if (isVm) Platform.script.toFilePath(), incrementalDriverFlag, ...flags],
  );
}
