// Build-action runner for `dart analyze` over a staged project directory.
//
// `dart analyze` produces no output artifact, but a Bazel action must; this
// runner forwards the analyzer's diagnostics and writes the stamp file only
// on success. Pure Dart (no shell) so the action is portable to Windows.
import 'dart:io';

import 'package:rules_dart_guard/directive_guard.dart';

import 'analysis_baseline.dart';
import 'analyze_runner_staged_prune.dart';
import 'private_home.dart';

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

  if (parsed.baseline != null) {
    _analyzeWithBaseline(parsed, project);
    return;
  }

  final ProcessResult result = withPrivateHome(
    'rules_dart_analyze_home.',
    (env) => Process.runSync(parsed.dart, [
      'analyze',
      if (parsed.fatalInfos) '--fatal-infos',
      project,
    ], environment: env),
  );
  // Bazel echoes any action output, so a clean run stays silent rather than
  // printing the analyzer's "No issues found!" on every build.
  stderr.write(unstage(result.stderr as String, project));
  if (result.exitCode != 0) {
    stdout.write(unstage(result.stdout as String, project));
    exit(result.exitCode);
  }
  File(parsed.stamp).writeAsStringSync('analyzed\n');
}

/// Runs `dart analyze --format=machine` and decides the verdict from the
/// baseline ceilings instead of the analyzer's exit code.
void _analyzeWithBaseline(_AnalyzeArgs parsed, String project) {
  final baselinePath = parsed.baseline!;
  final baselineFile = File(baselinePath);
  if (!baselineFile.existsSync()) {
    stderr.writeln('analyze_runner: missing baseline file $baselinePath');
    exit(1);
  }
  final AnalysisBaseline baseline;
  try {
    baseline = AnalysisBaseline.parse(
      baselineFile.readAsStringSync(),
      source: baselinePath,
    );
  } on BaselineException catch (e) {
    stderr.writeln('analyze_runner: $e');
    exit(1);
  }
  final ProcessResult result = withPrivateHome(
    'rules_dart_analyze_home.',
    (env) => Process.runSync(parsed.dart, [
      'analyze',
      '--format=machine',
      if (parsed.fatalInfos) '--fatal-infos',
      project,
    ], environment: env),
  );
  final stdoutText = result.stdout as String;
  final stderrText = result.stderr as String;
  stderr.write(unstage(stderrText, project));
  final diagnostics = parseMachineDiagnostics(stdoutText, project);
  if (diagnostics == null) exit(1);
  final report = BaselineReport.of(diagnostics, baseline);
  for (final diagnostic in diagnostics) {
    final group = report.groupFor(diagnostic.path, diagnostic.code)!;
    final marker = group.withinCeiling ? ' - ${baselinedMarker(group)}' : '';
    stdout.writeln('${diagnostic.text}$marker');
  }
  for (final group in report.groups) {
    if (!group.withinCeiling) stdout.writeln(baselineFailureLine(group));
  }
  if (diagnostics.isEmpty && result.exitCode != 0) {
    stdout.write(unstage(stdoutText, project));
    exit(1);
  }
  if (!report.passes) exit(1);
  File(parsed.stamp).writeAsStringSync('analyzed\n');
}

/// The severities the analyzer's machine format may report.
const _levels = {'error', 'warning', 'info'};

/// Parses every machine-format diagnostic, or reports the first unparsable
/// line to stderr and returns null.
List<BaselineDiagnostic>? parseMachineDiagnostics(String out, String project) {
  final diagnostics = <BaselineDiagnostic>[];
  for (final raw in out.split('\n')) {
    final line = raw.trimRight();
    if (line.trim().isEmpty) continue;
    final diagnostic = _parseMachineLine(line, project);
    if (diagnostic == null) {
      stderr.writeln('analyze_runner: cannot parse analyzer diagnostic: $line');
      return null;
    }
    diagnostics.add(diagnostic);
  }
  return diagnostics;
}

/// One machine-format line as `SEVERITY|TYPE|CODE|FILE|LINE|COL|LENGTH|MESSAGE`.
BaselineDiagnostic? _parseMachineLine(String line, String project) {
  final fields = _splitMachineFields(line);
  if (fields == null || fields.length < 8) return null;
  final level = fields[0].trim().toLowerCase();
  final code = fields[2].trim().toLowerCase();
  final lineNumber = int.tryParse(fields[4].trim());
  final column = int.tryParse(fields[5].trim());
  final length = int.tryParse(fields[6].trim());
  if (!_levels.contains(level) ||
      code.isEmpty ||
      lineNumber == null ||
      column == null ||
      length == null) {
    return null;
  }
  final path = _workspacePath(fields[3], project);
  final message = unstage(fields.sublist(7).join('|'), project);
  final text =
      '${level.padLeft(7)} - $path:$lineNumber:$column - $message - $code';
  return BaselineDiagnostic(path: path, code: code, level: level, text: text);
}

/// Splits a machine-format line on unescaped `|`, unescaping `\\` and `\|`.
List<String>? _splitMachineFields(String line) {
  final fields = <String>[];
  final current = StringBuffer();
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == r'\') {
      if (i + 1 >= line.length) return null;
      final next = line[i + 1];
      if (next == r'\' || next == '|') {
        current.write(next);
        i++;
        continue;
      }
    }
    if (ch == '|') {
      fields.add(current.toString());
      current.clear();
    } else {
      current.write(ch);
    }
  }
  fields.add(current.toString());
  return fields;
}

/// The workspace path of a machine-format file field.
String _workspacePath(String raw, String project) {
  var path = unstage(raw, project).replaceAll(r'\', '/');
  while (path.startsWith('./')) {
    path = path.substring(2);
  }
  if (path.startsWith('src/')) path = path.substring(4);
  return path;
}

/// Parsed `analyze_runner` command line.
typedef _AnalyzeArgs = ({
  String dart,
  String project,
  String stamp,
  bool fatalInfos,
  List<String> sources,
  String? baseline,
});

/// Parses the command line, exiting 64 on an unknown or missing argument.
_AnalyzeArgs _parseAnalyzeArgs(List<String> args) {
  String? dart;
  String? project;
  String? stamp;
  String? baseline;
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
      case '--baseline':
        baseline = args[++i];
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
    baseline: baseline,
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
Set<String>? pruneOrphanedStagedFiles(String project) => pruneStagedSrcTree(
  project,
  spelling: (
    manifestSrcEntry: _normRel,
    manifestExtEntry: _normRel,
    relativeSrcPath: _relative,
    relativeExtPath: _relative,
  ),
);

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

/// Normalized absolute and symlink-resolved prefixes for [project].
Set<String> _projectRoots(String project) {
  final isAbs =
      project.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(project);
  final lexical = isAbs ? project : Directory(project).absolute.path;
  final roots = <String>{_normalizeSlashPath(lexical)};
  try {
    roots.add(
      _normalizeSlashPath(Directory(project).resolveSymbolicLinksSync()),
    );
  } on FileSystemException {
    // Non-existent synthetic project paths in unit tests have no symlink target
    // on disk; the normalized lexical absolute path above still unstages them.
  }
  return roots;
}

String _normalizeSlashPath(String raw) {
  final slashed = raw.replaceAll(r'\', '/');
  final prefix = slashed.startsWith('/')
      ? '/'
      : RegExp(r'^[A-Za-z]:').stringMatch(slashed) ?? '';
  final body = slashed.substring(prefix.length);
  final parts = <String>[];
  for (final part in body.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..' && parts.isNotEmpty) {
      parts.removeLast();
    } else if (part != '..') {
      parts.add(part);
    }
  }
  if (prefix == '/') return '/${parts.join('/')}';
  if (prefix.isNotEmpty) {
    return parts.isEmpty ? prefix : '$prefix/${parts.join('/')}';
  }
  return parts.join('/');
}

/// Rewrites staged paths in the analyzer's output to the workspace paths they
/// were copied from, so a diagnostic names a file the user can open.
///
/// The analyzer names a file relative to the directory it analyzed — here the
/// staged project, whose sources sit at `src/<workspace path>` — and quotes
/// absolute paths inside some messages (an unresolvable `include:` names the
/// options file that holds it). Both forms lose their staging prefix. Only the
/// `src/` tree is rewritten: nothing outside it has a workspace path.
String unstage(String out, String project) {
  var result = out;
  for (final root in _projectRoots(project)) {
    result = result
        .replaceAll('$root/src/', '')
        .replaceAll('${root.replaceAll('/', r'\')}\\src\\', '');
  }
  return result.replaceAllMapped(_diagnosticPath, (m) => m[1]!);
}

/// A diagnostic line's leading severity, up to its project-relative path.
final _diagnosticPath = RegExp(r'^(\s*\w+ - )src/', multiLine: true);
