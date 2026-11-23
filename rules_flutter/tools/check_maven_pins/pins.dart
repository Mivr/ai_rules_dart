/// Maven pin validation for the e2e workspaces.
///
/// Every `maven.install` in every e2e workspace must name a checked-in lock
/// file inside the workspace. The lock must carry a 64-hex sha256 for every
/// artifact and must pin every coordinate the workspace declares at the
/// declared version.
library;

import 'dart:io';

import 'lock_check.dart';
import 'module_parse.dart';

export 'lock_check.dart';
export 'module_parse.dart';

/// Resolves a Bazel lock file label (e.g. `//:rules_android_maven_install.json`)
/// to a filesystem path relative to the workspace directory.
String resolveLockFilePath(String workspacePath, String lockFileLabel) {
  final String normalized = lockFileLabel.startsWith('@//')
      ? lockFileLabel.substring(1)
      : lockFileLabel;
  if (normalized.startsWith('//:')) {
    return '$workspacePath/${normalized.substring(3)}';
  }
  if (normalized.startsWith('//')) {
    final String rel = normalized.substring(2).replaceAll(':', '/');
    return '$workspacePath/$rel';
  }
  if (normalized.startsWith(':')) {
    return '$workspacePath/${normalized.substring(1)}';
  }
  return '$workspacePath/$normalized';
}

bool _pointsOutsideWorkspace(String label) {
  if (label.startsWith('@') && !label.startsWith('@//')) return true;
  return label.split(RegExp('[/:]')).contains('..');
}

List<String> _checkInstall(
  String workspacePath,
  MavenInstall install,
  String modulePath,
) {
  final InstallSource moduleSource = (
    workspacePath: workspacePath,
    filePath: modulePath,
    installName: install.name,
  );
  final List<String> errors = validateDeclaredShape(
    moduleSource,
    install.coordinates,
  );

  final Set<String> labels = install.lockFiles.toSet();
  if (labels.contains('')) {
    return errors..add(describeProblem(moduleSource, 'has no lock_file'));
  }
  if (labels.length > 1) {
    return errors..add(
      describeProblem(
        moduleSource,
        "install blocks disagree on lock_file (${labels.join(', ')})",
      ),
    );
  }
  final String label = labels.single;
  if (_pointsOutsideWorkspace(label)) {
    return errors..add(
      describeProblem(
        moduleSource,
        "lock_file '$label' must point inside the workspace",
      ),
    );
  }

  final String lockPath = resolveLockFilePath(workspacePath, label);
  final InstallSource lockSource = (
    workspacePath: workspacePath,
    filePath: lockPath,
    installName: install.name,
  );
  final lockFile = File(lockPath);
  if (!lockFile.existsSync()) {
    return errors..add(describeProblem(lockSource, 'lock file is missing'));
  }
  return errors..addAll(
    validateLockContent(
      source: lockSource,
      lockJsonContent: lockFile.readAsStringSync(),
      declared: install.coordinates,
    ),
  );
}

/// Parses the installs of the workspace's `MODULE.bazel`, or null when the
/// file does not exist.
List<MavenInstall>? _readInstalls(String workspacePath) {
  final moduleFile = File('$workspacePath/MODULE.bazel');
  if (!moduleFile.existsSync()) return null;
  return parseMavenInstalls(moduleFile.readAsStringSync());
}

/// Checks every `maven.install` of one workspace.
List<String> checkWorkspacePins(String workspacePath) {
  final modulePath = '$workspacePath/MODULE.bazel';
  final List<MavenInstall>? installs = _readInstalls(workspacePath);
  if (installs == null) {
    return [
      "workspace '$workspacePath', file '$modulePath': MODULE.bazel does not exist",
    ];
  }
  if (installs.isEmpty) {
    return [
      "workspace '$workspacePath', file '$modulePath': no maven.install declaration found",
    ];
  }
  return <String>[
    for (final MavenInstall install in installs)
      ..._checkInstall(workspacePath, install, modulePath),
  ];
}

List<String> _childDirNames(String dirPath) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return <String>[];
  final names = <String>[];
  for (final FileSystemEntity entry in dir.listSync(followLinks: false)) {
    if (entry is! Directory) continue;
    final String name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (!name.startsWith('bazel-')) names.add(name);
  }
  return names;
}

/// Workspace-relative paths of every `e2e/*` and `e2e/*/*` module whose
/// `MODULE.bazel` declares a `maven.install`, sorted.
///
/// Symlinked directories and `bazel-*` convenience links are never entered.
List<String> discoverMavenWorkspaces(String rootPath) {
  final candidates = <String>[];
  for (final String top in _childDirNames('$rootPath/e2e')) {
    candidates.add('e2e/$top');
    for (final String nested in _childDirNames('$rootPath/e2e/$top')) {
      candidates.add('e2e/$top/$nested');
    }
  }
  final List<String> found = candidates.where((String rel) {
    final List<MavenInstall>? installs = _readInstalls('$rootPath/$rel');
    return installs != null && installs.isNotEmpty;
  }).toList()..sort();
  return found;
}

/// Checks the explicit [workspaces], or every discovered Maven workspace
/// under `<rootPath>/e2e` when none are given.
List<String> checkAllWorkspaces({
  required String rootPath,
  List<String>? workspaces,
}) {
  final List<String> pathsToCheck =
      workspaces ?? discoverMavenWorkspaces(rootPath);
  if (pathsToCheck.isEmpty) {
    return ['no maven.install declaration found under $rootPath/e2e'];
  }
  return <String>[
    for (final String relPath in pathsToCheck)
      ...checkWorkspacePins('$rootPath/$relPath'),
  ];
}

/// Counts the `maven.install` names declared across [workspaces].
int countInstalls(String rootPath, List<String> workspaces) {
  var total = 0;
  for (final rel in workspaces) {
    total += _readInstalls('$rootPath/$rel')?.length ?? 0;
  }
  return total;
}
