/// Where the floor chains find the sources, package config and test kernels.
library;

import 'dart:io';

import 'incremental_driver.dart';

/// The multi-root URI scheme the rules compile the workspace under.
const floorScheme = 'org-dartlang-root';

final _binDirPattern = RegExp(r'^(bazel-out/[^/]+/bin)/');

String _stripExe(String path) =>
    path.endsWith('.exe') ? path.substring(0, path.length - 4) : path;

String _resolveConfigPath(String path, String configSuffix) {
  final direct = '$path$configSuffix';
  if (File(direct).existsSync()) return direct;
  return '${_stripExe(path)}$configSuffix';
}

/// Where a layout looks for its package config, in order of preference.
final class _ConfigSource {
  const _ConfigSource(this.suffixes, {this.buildFromWorkspace = false});

  /// File name suffixes beside the executable; the first is the primary one.
  final List<String> suffixes;

  /// Whether to write a config for the generated workspace when none exists.
  final bool buildFromWorkspace;

  /// The first existing config beside [path], or null.
  String? find(String path) {
    for (final suffix in suffixes) {
      final config = _resolveConfigPath(path, suffix);
      if (File(config).existsSync()) return config;
    }
    return null;
  }
}

/// Writes the package config of the generated workspace under [floorScheme].
///
/// Each directory `packages/<name>` with a `lib/` is the package `<name>`,
/// named by the same `<scheme>:///<package dir>` root the rules write, so the
/// floor compiles the sources the Bazel build compiled. The packages are
/// sorted, so the file is the same on every run. Returns null when the
/// workspace has no such package.
String? _buildWorkspaceConfig(String workspaceDir) {
  final packages = Directory('$workspaceDir/packages');
  if (!packages.existsSync()) return null;
  final names = [
    for (final dir in packages.listSync().whereType<Directory>())
      if (Directory('${dir.path}/lib').existsSync())
        dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
  ]..sort();
  if (names.isEmpty) return null;
  final entries = [
    for (final name in names)
      '    {"name": "$name", "rootUri": "$floorScheme:///packages/$name", '
          '"packageUri": "lib/"}',
  ];
  final file = File('$workspaceDir/.dart_tool/floor_package_config.json')
    ..parent.createSync(recursive: true);
  file.writeAsStringSync(
    '{\n  "configVersion": 2,\n  "packages": [\n'
    '${entries.join(',\n')}\n  ]\n}\n',
  );
  return file.path;
}

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
  /// beside the executable. Inside the exec root the package config is the
  /// `<app>.package_config.json` beside the app when it exists; the linked
  /// kernel executables write `<app>.entry.kmod.package_config.json` instead,
  /// and without either the config is built from the packages of
  /// [workspaceDir]. With none of the three, the error names the missing
  /// input.
  factory FloorLayout.fromApp({
    required String appExecutable,
    required String workspaceDir,
  }) => FloorLayout._derive(
    executable: appExecutable,
    workspaceDir: workspaceDir,
    config: const _ConfigSource([
      '.package_config.json',
      '.entry.kmod.package_config.json',
    ], buildFromWorkspace: true),
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
    config: const _ConfigSource(['.entry.kmod.package_config.json']),
    entrypoint: (binRelative) => '$binRelative.vm_test.dart',
    plainEntrypoint: '${_stripExe(testExecutable)}.vm_test.dart',
  );

  factory FloorLayout._derive({
    required String executable,
    required String workspaceDir,
    required _ConfigSource config,
    required String Function(String binRelative) entrypoint,
    required String plainEntrypoint,
  }) {
    final path = executable.replaceAll(r'\', '/');
    final marker = path.indexOf('/bazel-out/');
    if (marker == -1) {
      final plain = _resolveConfigPath(path, config.suffixes.first);
      return FloorLayout._(
        workingDirectory: workspaceDir,
        entrypoint: plainEntrypoint,
        packageConfig: File(plain).existsSync() ? plain : null,
        scheme: null,
        roots: const [],
        workspaceDir: workspaceDir,
      );
    }
    final execroot = path.substring(0, marker);
    final rel = _stripExe(path.substring(marker + 1));
    final bin = _binDirPattern.firstMatch(rel)?.group(1);
    if (bin == null) {
      throw StateError('Cannot locate the bin directory in $executable');
    }
    final packageConfig =
        config.find(path) ??
        (config.buildFromWorkspace
            ? _buildWorkspaceConfig(workspaceDir)
            : null);
    if (packageConfig == null) {
      throw StateError(
        'Missing package config for $executable: '
        '${_resolveConfigPath(path, config.suffixes.first)}. The executable is '
        'expected to write its <name>.package_config.json, and '
        '$workspaceDir/packages has no package to build one from',
      );
    }
    return FloorLayout._(
      workingDirectory: execroot,
      entrypoint:
          '$floorScheme:///${entrypoint(rel.substring(bin.length + 1))}',
      packageConfig: packageConfig,
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
