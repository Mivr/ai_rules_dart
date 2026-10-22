// Build-action runner for `dart analyze` over a staged project directory.
//
// `dart analyze` produces no output artifact, but a Bazel action must; this
// runner forwards the analyzer's diagnostics and writes the stamp file only
// on success. Pure Dart (no shell) so the action is portable to Windows.
import 'dart:io';

import 'package:rules_dart_guard/directive_guard.dart';

void main(List<String> args) {
  final parsed = _parseAnalyzeArgs(args);
  final project = parsed.project;
  final allowed = pruneOrphanedStagedFiles(project);
  _checkStagedSources(project, parsed.sources, allowed);
  if (!_hasAnalyzableDartFile(project, allowed)) {
    stderr.writeln('analyze_runner: no Dart files to analyze in $project');
    exit(1);
  }

  // No staged source may read the host: a `file:` URI (in any spelling), any
  // other non-`dart:`/`package:` directive URI, a `package:` URI climbing
  // above its package, or a relative URI climbing out of the staged tree
  // would reach an undeclared file through the analyzer's working directory.
  // Refuse before analyzing, through the one shared staged-source check.
  final violations = findStagedDirectiveViolations(
    projectStagedRoots(project),
    tool: 'analyze_runner',
  );
  if (violations.isNotEmpty) {
    for (final violation in violations) {
      stderr.writeln(violation);
    }
    exit(1);
  }

  final tempHome = Directory.systemTemp.createTempSync(
    'rules_dart_analyze_home.',
  );
  final ProcessResult result;
  try {
    result = Process.runSync(
      parsed.dart,
      ['analyze', if (parsed.fatalInfos) '--fatal-infos', project],
      environment: {
        'HOME': tempHome.path,
        'USERPROFILE': tempHome.path,
        'LOCALAPPDATA': tempHome.path,
        'APPDATA': tempHome.path,
      },
    );
  } finally {
    if (tempHome.existsSync()) {
      try {
        tempHome.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
  }
  // Bazel echoes any action output, so a clean run stays silent rather than
  // printing the analyzer's "No issues found!" on every build.
  stderr.write(unstage(result.stderr as String, project));
  if (result.exitCode != 0) {
    stdout.write(unstage(result.stdout as String, project));
    exit(result.exitCode);
  }
  File(parsed.stamp).writeAsStringSync('analyzed\n');
}

/// Parsed `analyze_runner` command line.
typedef _AnalyzeArgs = ({
  String dart,
  String project,
  String stamp,
  bool fatalInfos,
  List<String> sources,
});

/// Parses the command line, exiting 64 on an unknown or missing argument.
_AnalyzeArgs _parseAnalyzeArgs(List<String> args) {
  String? dart;
  String? project;
  String? stamp;
  var fatalInfos = false;
  final sources = <String>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--dart':
        dart = args[++i];
      case '--project':
        project = args[++i];
      case '--stamp':
        stamp = args[++i];
      case '--source':
        sources.add(args[++i]);
      case '--fatal-infos':
        fatalInfos = true;
      default:
        stderr.writeln('analyze_runner: unknown argument ${args[i]}');
        exit(64);
    }
  }
  if (dart == null || project == null || stamp == null) {
    stderr.writeln(
      'analyze_runner: --dart, --project, and --stamp are required',
    );
    exit(64);
  }
  return (
    dart: dart,
    project: project,
    stamp: stamp,
    fatalInfos: fatalInfos,
    sources: sources,
  );
}

/// Rejects a `--source` that the manifest does not list or that is missing
/// from the staged tree, exiting 1 on the first one.
void _checkStagedSources(
  String project,
  List<String> sources,
  Set<String>? allowed,
) {
  for (final s in sources) {
    final norm = _normRel(s);
    if (allowed != null &&
        norm.startsWith('src/') &&
        !allowed.contains(norm.substring(4))) {
      stderr.writeln(
        'analyze_runner: source not listed in src_manifest.txt: $s',
      );
      exit(1);
    }
    if (!FileSystemEntity.isFileSync('$project/$norm')) {
      stderr.writeln('analyze_runner: expected source missing: $s');
      exit(1);
    }
  }
}

/// Removes any orphaned symlinks or unlisted files under `<project>/src/` when
/// `.dart_tool/src_manifest.txt` is present, and under sibling `<name>.extpkgs/`
/// when `.dart_tool/extpkgs_manifest.txt` is present. Returns the set of `/`
/// relative paths under `src/` (or `null` when no manifest is present).
/// Never prunes without a manifest.
Set<String>? pruneOrphanedStagedFiles(String project) {
  _pruneExtpkgs(project);

  final srcDir = Directory('$project/src');
  if (!srcDir.existsSync()) return null;
  final manifestFile = File('$project/.dart_tool/src_manifest.txt');
  if (!manifestFile.existsSync()) return null;

  final lines = [
    for (final line in manifestFile.readAsLinesSync())
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (lines.contains('*')) return null;

  final allowed = <String>{for (final line in lines) _normRel(line)};
  final rootPath = srcDir.path;
  for (final entity in srcDir.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) continue;
    final rel = _relative(rootPath, entity.path);
    if (!allowed.contains(rel)) {
      try {
        entity.deleteSync();
      } on FileSystemException {
        // Ignore if read-only or already removed.
      }
    }
  }
  return allowed;
}

void _pruneExtpkgs(String project) {
  var normProject = project;
  while (normProject.length > 1 &&
      (normProject.endsWith('/') || normProject.endsWith(r'\'))) {
    normProject = normProject.substring(0, normProject.length - 1);
  }
  if (!normProject.endsWith('.proj')) return;
  final extDir = Directory(
    '${normProject.substring(0, normProject.length - '.proj'.length)}.extpkgs',
  );
  if (!extDir.existsSync()) return;
  final extManifest = File('$normProject/.dart_tool/extpkgs_manifest.txt');
  if (!extManifest.existsSync()) return;

  final allowedFiles = <String>{};
  final allowedDirPrefixes = <String>[];
  for (final raw in extManifest.readAsLinesSync()) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.endsWith('/')) {
      allowedDirPrefixes.add(_normRel(trimmed));
    } else {
      allowedFiles.add(_normRel(trimmed));
    }
  }
  final rootPath = extDir.path;
  for (final entity in extDir.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) continue;
    final rel = _relative(rootPath, entity.path);
    final inAllowedDir = allowedDirPrefixes.any(rel.startsWith);
    if (!inAllowedDir && !allowedFiles.contains(rel)) {
      try {
        entity.deleteSync();
      } on FileSystemException {
        // Ignore if read-only or already removed.
      }
    }
  }
}

bool _hasAnalyzableDartFile(String project, Set<String>? allowed) {
  if (allowed != null) {
    for (final rel in allowed) {
      if (rel.endsWith('.dart') &&
          FileSystemEntity.isFileSync('$project/src/$rel')) {
        return true;
      }
    }
    return false;
  }
  final srcDir = Directory('$project/src');
  final searchRoot = srcDir.existsSync() ? srcDir : Directory(project);
  for (final entity in searchRoot.listSync(recursive: true)) {
    if (entity.path.endsWith('.dart') &&
        FileSystemEntity.isFileSync(entity.path)) {
      return true;
    }
  }
  return false;
}

String _normRel(String raw) {
  var rel = raw.replaceAll(r'\', '/');
  while (rel.startsWith('./')) {
    rel = rel.substring(2);
  }
  while (rel.startsWith('/')) {
    rel = rel.substring(1);
  }
  return rel;
}

String _relative(String root, String path) =>
    _normRel(path.substring(root.length));

/// Rewrites staged paths in the analyzer's output to the workspace paths they
/// were copied from, so a diagnostic names a file the user can open.
///
/// The analyzer names a file relative to the directory it analyzed — here the
/// staged project, whose sources sit at `src/<workspace path>` — and quotes
/// absolute paths inside some messages (an unresolvable `include:` names the
/// options file that holds it). Both forms lose their staging prefix. Only the
/// `src/` tree is rewritten: nothing outside it has a workspace path.
String unstage(String out, String project) {
  final absolute = Directory(project).absolute.path.replaceAll(r'\', '/');
  return out
      .replaceAll('$absolute/src/', '')
      .replaceAllMapped(_diagnosticPath, (m) => m[1]!);
}

/// A diagnostic line's leading severity, up to its project-relative path.
final _diagnosticPath = RegExp(r'^(\s*\w+ - )src/', multiLine: true);
