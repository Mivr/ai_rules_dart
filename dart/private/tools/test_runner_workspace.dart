import 'dart:io';

/// Deletes a scratch file or directory the launcher no longer needs, ignoring
/// failure.
///
/// Scratch cleanup is best-effort: the run's result no longer depends on these
/// files, so a failure to remove one must not fail the run or mask its exit
/// code. Only filesystem failures are ignored; anything else is a programming
/// error and propagates.
void deleteScratchQuietly(FileSystemEntity entity) {
  if (!entity.existsSync()) return;
  try {
    entity.deleteSync(recursive: true);
  } on FileSystemException {
    // Best-effort cleanup; the run already has its result.
  }
}

/// Whether the runfiles [workspace] is usable from the current directory.
///
/// A [testPath] that names a file which is not there means the suite cannot
/// run here. Where the manifest or workspace is unknown there is nothing to
/// check, so the answer is yes. Otherwise every manifest entry under
/// `<workspace>/` must already exist at its workspace-relative path.
bool workspaceInPlace({String? testPath, String? manifest, String? workspace}) {
  if (testPath != null && !File(testPath).existsSync()) {
    return false;
  }
  if (manifest == null || workspace == null) {
    return true;
  }
  final prefix = '$workspace/';
  for (final line in File(manifest).readAsLinesSync()) {
    final space = line.indexOf(' ');
    if (space < 0 || !line.startsWith(prefix)) continue;
    final relative = line.substring(prefix.length, space);
    final real = line.substring(space + 1);
    if (Directory(real).existsSync()) {
      if (!Directory(relative).existsSync()) return false;
    } else if (File(real).existsSync()) {
      if (!File(relative).existsSync()) return false;
    }
  }
  return true;
}

/// Lays out `workspace`'s runfiles under [into] from the lines of a runfiles
/// manifest, each `<runfiles path> <real path>`.
///
/// Where Bazel builds no runfiles tree (Windows by default, or
/// `--noenable_runfiles`) the manifest is all there is, and a test's working
/// directory would hold none of its `data`. A real path that is a directory (a
/// tree artifact is one entry) is copied whole.
void materializeWorkspace({
  required List<String> manifest,
  required String workspace,
  required String into,
}) {
  final prefix = '$workspace/';
  for (final line in manifest) {
    final space = line.indexOf(' ');
    if (space < 0 || !line.startsWith(prefix)) continue;
    final relative = line.substring(prefix.length, space);
    final real = line.substring(space + 1);
    final destination = joinPaths(into, relative);
    if (Directory(real).existsSync()) {
      copyDirectory(Directory(real), Directory(destination));
    } else if (File(real).existsSync()) {
      final destFile = File(destination);
      destFile.parent.createSync(recursive: true);
      if (destFile.existsSync()) {
        destFile.deleteSync();
      }
      File(real).copySync(destination);
    }
  }
}

/// Copies the directory tree at [from] onto [to], replacing files in place.
void copyDirectory(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync(recursive: true, followLinks: true)) {
    final relative = entity.path.substring(from.path.length + 1);
    final target = joinPaths(to.path, relative.replaceAll(r'\', '/'));
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      final targetFile = File(target);
      targetFile.parent.createSync(recursive: true);
      if (targetFile.existsSync()) {
        targetFile.deleteSync();
      }
      entity.copySync(target);
    }
  }
}

/// Joins a forward-slashed relative path onto [base], creating its parents.
String joinPaths(String base, String relative) {
  final path = [base, ...relative.split('/')].join(Platform.pathSeparator);
  File(path).parent.createSync(recursive: true);
  return path;
}
