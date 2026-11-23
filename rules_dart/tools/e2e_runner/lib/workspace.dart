/// Workspace resolution and staging.
///
/// The runner never trusts its own working directory to find the repository
/// root: a staged workspace lives under a scratch directory, so the original
/// `local_path_override(path = "../..")` would escape into the scratch parent
/// instead of the checkout. This library resolves the root from the workspace
/// itself and rewrites the escaping overrides to point back at it.
library;

import 'dart:io';

/// Whether [path] is an absolute POSIX or Windows path.
bool isAbsoluteOverridePath(String path) =>
    path.startsWith('/') ||
    path.startsWith(r'\') ||
    RegExp(r'^[A-Za-z]:[/\\]').hasMatch(path);

/// Whether a `local_path_override` path escapes its workspace.
///
/// An override stays inside when its first component is a normal name or a
/// single `.` (e.g. `dep_module`, `./dep_module`); it escapes when it is
/// relative and its first component is `..` (e.g. `../..`).
bool pathEscapesWorkspace(String path) =>
    !isAbsoluteOverridePath(path) &&
    (path == '..' || path.startsWith('../') || path.startsWith(r'..\'));

final RegExp _overrideBlock = RegExp(
  r'local_path_override\(([^()]*)\)',
  dotAll: true,
);
final RegExp _pathValue = RegExp(r'''path\s*=\s*['"]([^'"]*)['"]''');

/// The first `local_path_override` path that escapes the workspace, if any.
String? escapingOverridePath(String moduleBazel) {
  for (final match in _overrideBlock.allMatches(moduleBazel)) {
    final block = match.group(1)!;
    final pathMatch = _pathValue.firstMatch(block);
    if (pathMatch == null) continue;
    final path = pathMatch.group(1)!;
    if (pathEscapesWorkspace(path)) return path;
  }
  return null;
}

/// Resolves [path] (possibly relative to [base]) to an absolute, normalized
/// path without requiring the target to exist.
String absolutePath(String path, {String? base}) {
  final p = File(path);
  if (p.isAbsolute) return p.absolute.path;
  final baseDir = base ?? Directory.current.path;
  return File('$baseDir/$path').absolute.path;
}

final RegExp _driveOnly = RegExp(r'^[A-Za-z]:$');

/// Normalizes `.` and `..` components lexically, without touching the disk.
String normalizePath(String path) {
  final absolute = File(path).absolute.path;
  final sep = Platform.pathSeparator;
  final parts = <String>[];
  for (final part in absolute.split(RegExp(r'[/\\]'))) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty && parts.last != '..') {
        parts.removeLast();
      } else {
        parts.add(part);
      }
    } else {
      parts.add(part);
    }
  }
  if (parts.length == 1 && _driveOnly.hasMatch(parts.single)) {
    return '${parts.single}$sep';
  }
  final joined = parts.join(sep);
  if (absolute.startsWith(r'\\')) return '\\\\$joined';
  return absolute.startsWith('/') ? '/$joined' : joined;
}

/// Resolves the repository root from [workspaceDir]'s escaping override.
///
/// Throws when the workspace has no escaping override, so a workspace whose
/// module does not point at the repository cannot silently resolve to the
/// caller's own root.
String resolveRepoRoot(String workspaceDir) {
  final moduleFile = File('$workspaceDir/MODULE.bazel');
  final text = _readText(moduleFile, 'workspace module');
  final escape = escapingOverridePath(text);
  if (escape == null) {
    throw StateError(
      'workspace $workspaceDir has no escaping local_path_override to resolve '
      'the repository root from',
    );
  }
  return normalizePath('$workspaceDir/$escape');
}

/// Rewrites every relative escaping override in [moduleBazel] to [repoRoot].
String rewriteEscapingOverrides(
  String moduleBazel,
  String repoRoot, {
  String? moduleDir,
  String? stagedDir,
}) {
  final starlarkRoot = repoRoot.replaceAll(r'\', '/');
  final buffer = StringBuffer();
  var last = 0;
  for (final match in _overrideBlock.allMatches(moduleBazel)) {
    final block = match.group(1)!;
    final pathMatch = _pathValue.firstMatch(block);
    if (pathMatch == null) continue;
    final path = pathMatch.group(1)!;
    if (!_escapesStagedWorkspace(path, moduleDir, stagedDir)) continue;
    final absStart = match.start + match.group(0)!.indexOf(pathMatch.group(0)!);
    buffer.write(moduleBazel.substring(last, absStart));
    buffer.write('path = "$starlarkRoot"');
    last = absStart + pathMatch.group(0)!.length;
  }
  if (last == 0) return moduleBazel;
  buffer.write(moduleBazel.substring(last));
  return buffer.toString();
}

bool _escapesStagedWorkspace(
  String path,
  String? moduleDir,
  String? stagedDir,
) {
  if (isAbsoluteOverridePath(path)) return false;
  if (moduleDir == null || stagedDir == null) {
    return pathEscapesWorkspace(path);
  }
  final target = normalizePath('$moduleDir/$path');
  final cmpTarget = Platform.isWindows ? target.toLowerCase() : target;
  final cmpStaged = Platform.isWindows ? stagedDir.toLowerCase() : stagedDir;
  final inside =
      cmpTarget.startsWith('$cmpStaged/') ||
      cmpTarget.startsWith('$cmpStaged${Platform.pathSeparator}');
  return cmpTarget == cmpStaged || !inside;
}

String _readText(File file, String what) {
  try {
    return file.readAsStringSync();
  } on FileSystemException catch (e) {
    throw StateError('cannot read $what ${file.path}: ${e.message}');
  }
}

/// Deletes [path] recursively without following symbolic links.
///
/// Bazel's `bazel-*` convenience links and the `external/<module>+` override
/// links can form cycles between the scratch output base and the checkout;
/// `Directory.deleteSync(recursive: true)` follows them and fails, so this
/// deletes each link in place instead.
void deleteTree(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type != FileSystemEntityType.directory) {
    _deleteEntity(path);
    return;
  }
  _makeWritableDir(path);
  for (final entry in Directory(path).listSync(followLinks: false)) {
    deleteTree(entry.path);
  }
  Directory(path).deleteSync();
}

/// Adds owner-write permission to a directory so its read-only Bazel outputs
/// can be unlinked. No-op on Windows, where the read-only bit does not gate
/// deletion.
void _makeWritableDir(String path) {
  if (Platform.isWindows) return;
  try {
    Process.runSync('chmod', ['u+w', path]);
  } on ProcessException catch (e) {
    stderr.writeln('chmod $path failed: ${e.message}');
  }
}

void _deleteEntity(String path) {
  final isLink =
      FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.link;
  try {
    if (isLink) {
      Link(path).deleteSync();
    } else {
      File(path).deleteSync();
    }
  } on FileSystemException catch (e) {
    if (Platform.isWindows && !isLink) {
      Process.runSync('attrib', ['-R', path]);
      File(path).deleteSync();
      return;
    }
    throw FileSystemException('cannot delete $path: ${e.message}');
  }
}

/// Recursively copies [source] into [target], skipping Bazel output symlinks
/// and any `.git` directory.
void copyDirectory(String source, String target) {
  final sourceDir = Directory(source);
  if (!sourceDir.existsSync()) {
    throw StateError('workspace directory $source does not exist');
  }
  Directory(target).createSync(recursive: true);
  for (final entry in sourceDir.listSync(followLinks: false)) {
    final name = _entryName(entry);
    if (name.startsWith('bazel-') || name == '.git') continue;
    final dest = '$target/$name';
    if (entry is Directory) {
      copyDirectory(entry.path, dest);
    } else if (entry is Link) {
      _copyLink(entry, dest);
    } else if (entry is File) {
      entry.copySync(dest);
    }
  }
}

/// The last non-empty path segment of [entry], its name (directories' URIs
/// carry a trailing slash, so `.last` would be empty).
String _entryName(FileSystemEntity entry) {
  final segments = entry.uri.pathSegments.where((s) => s.isNotEmpty).toList();
  return segments.isEmpty ? '' : segments.last;
}

void _copyLink(Link link, String dest) {
  final target = link.targetSync();
  if (isAbsoluteOverridePath(target) || pathEscapesWorkspace(target)) return;
  Link(dest).createSync(target);
}

/// Stages [workspaceDir] into [stagedDir], rewriting escaping overrides to
/// [repoRoot] and guaranteeing a `.bazelversion` (derived from the root when
/// the workspace does not carry one).
void stageWorkspace(String workspaceDir, String stagedDir, String repoRoot) {
  copyDirectory(workspaceDir, stagedDir);
  final stagedNorm = normalizePath(stagedDir);
  final stagedDirEntity = Directory(stagedDir);
  if (stagedDirEntity.existsSync()) {
    for (final entry in stagedDirEntity.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is File && entry.path.endsWith('MODULE.bazel')) {
        final text = _readText(entry, 'staged module');
        final rewritten = rewriteEscapingOverrides(
          text,
          repoRoot,
          moduleDir: normalizePath(entry.parent.path),
          stagedDir: stagedNorm,
        );
        if (rewritten != text) {
          entry.writeAsStringSync(rewritten);
        }
      }
    }
  }
  final versionFile = File('$stagedDir/.bazelversion');
  if (!versionFile.existsSync()) {
    final rootVersion = File('$repoRoot/.bazelversion');
    if (rootVersion.existsSync()) {
      versionFile.writeAsStringSync(rootVersion.readAsStringSync());
    }
  }
}
