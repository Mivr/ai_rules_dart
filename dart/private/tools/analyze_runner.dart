// Build-action runner for `dart analyze` over a staged project directory.
//
// `dart analyze` produces no output artifact, but a Bazel action must; this
// runner forwards the analyzer's diagnostics and writes the stamp file only
// on success. Pure Dart (no shell) so the action is portable to Windows.
import 'dart:io';

import 'package:rules_dart_guard/directive_guard.dart';

import 'analysis_baseline.dart';
import 'analyze_runner_machine.dart';
import 'analyze_runner_staged_prune.dart';
import 'cli_flags.dart';
import 'private_home.dart';
import 'project_lint_options.dart';
import 'staged_project_copy.dart';

export 'analyze_runner_machine.dart' show parseMachineDiagnostics, unstage;

void main(List<String> args) {
  final _AnalyzeArgs parsed = _parseAnalyzeArgs(args);
  final String project = parsed.project;
  final Set<String>? allowed = pruneOrphanedStagedFiles(project);
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
  final List<String> violations = findStagedDirectiveViolations(
    projectStagedRoots(project),
    tool: 'analyze_runner',
  );
  if (violations.isNotEmpty) {
    for (final violation in violations) {
      stderr.writeln(violation);
    }
    exit(1);
  }

  // The stock SDK `dart analyze` does not know the project lint rules: when
  // the staged options enable any, analyze a writable copy with those keys
  // stripped instead of the read-only staged tree (never through its
  // symlinks), and map the diagnostics back from the copy's paths.
  final String? stripped = stageStrippedProjectCopy(project, allowed);
  final String effective = stripped ?? project;
  try {
    if (parsed.baseline != null) {
      _analyzeWithBaseline(parsed, effective);
      return;
    }

    final ProcessResult result = _runDartAnalyze(
      parsed,
      effective,
      machine: false,
    );
    // Bazel echoes any action output, so a clean run stays silent rather than
    // printing the analyzer's "No issues found!" on every build.
    stderr.write(unstage(result.stderr as String, effective));
    if (result.exitCode != 0) {
      stdout.write(unstage(result.stdout as String, effective));
      exit(result.exitCode);
    }
    File(parsed.stamp).writeAsStringSync('analyzed\n');
  } finally {
    if (stripped != null) {
      _removeStagingCopy(stripped);
    }
  }
}

/// Copies the staged project into a scratch directory with the project lint
/// rule keys stripped from its options copies, or returns null when the
/// staged options enable none.
///
/// Returns the scratch directory holding the stripped copy.
String? stageStrippedProjectCopy(String project, Set<String>? allowed) {
  if (findStagedProjectLintOptions(project).isEmpty) {
    return null;
  }
  final String normProject = project.endsWith('/') || project.endsWith(r'\')
      ? project.substring(0, project.length - 1)
      : project;
  final scratch = Directory('$normProject.stripped');
  if (scratch.existsSync()) {
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup of previous scratch directory.
    }
  }
  copyStagedTree(
    project,
    scratch.path,
    projectRoot: project,
    allowedSrcPaths: allowed == null
        ? null
        : {for (final entry in allowed) 'src/$entry'},
  );
  stripStagedProjectLintOptions(scratch.path);
  repointPackageConfig(project, scratch.path);
  return scratch.path;
}

/// Deletes a staging copy created by [stageStrippedProjectCopy].
///
/// A failed recursive delete on Windows (a child still holds the directory)
/// must not mask the analysis' own result.
void _removeStagingCopy(String scratch) {
  final dir = Directory(scratch);
  if (!dir.existsSync()) return;
  try {
    dir.deleteSync(recursive: true);
  } on FileSystemException {
    // Ignore cleanup errors; see the documentation above.
  }
}

ProcessResult _runDartAnalyze(
  _AnalyzeArgs parsed,
  String project, {
  required bool machine,
}) => withPrivateHome(
  'rules_dart_analyze_home.',
  (env) => Process.runSync(parsed.dart, [
    'analyze',
    if (machine) '--format=machine',
    if (parsed.fatalInfos) '--fatal-infos',
    project,
  ], environment: env),
);

/// Runs `dart analyze --format=machine` and decides the verdict from the
/// baseline ceilings instead of the analyzer's exit code.
void _analyzeWithBaseline(_AnalyzeArgs parsed, String project) {
  final AnalysisBaseline baseline = _loadBaselineOrExit(parsed.baseline!);
  final ProcessResult result = _runDartAnalyze(parsed, project, machine: true);
  final stdoutText = result.stdout as String;
  stderr.write(unstage(result.stderr as String, project));
  final List<BaselineDiagnostic>? diagnostics = parseMachineDiagnostics(
    stdoutText,
    project,
  );
  if (diagnostics == null) exit(1);
  if (!_reconcileExitCode(parsed, project, result.exitCode, diagnostics)) {
    _writeBaselineReport(diagnostics, baseline);
    if (diagnostics.isEmpty) stdout.write(unstage(stdoutText, project));
    exit(1);
  }
  final BaselineReport report = _writeBaselineReport(diagnostics, baseline);
  if (!report.passes) exit(1);
  File(parsed.stamp).writeAsStringSync('analyzed\n');
}

AnalysisBaseline _loadBaselineOrExit(String baselinePath) {
  final baselineFile = File(baselinePath);
  if (!baselineFile.existsSync()) {
    stderr.writeln('analyze_runner: missing baseline file $baselinePath');
    exit(1);
  }
  try {
    return AnalysisBaseline.parse(
      baselineFile.readAsStringSync(),
      source: baselinePath,
    );
  } on BaselineException catch (e) {
    stderr.writeln('analyze_runner: $e');
    exit(1);
  }
}

/// Ensures an exit code more severe than [diagnostics] (an options `parse_error`
/// omitted by `--format=machine`, or an analyzer crash) never passes silently.
bool _reconcileExitCode(
  _AnalyzeArgs parsed,
  String project,
  int exitCode,
  List<BaselineDiagnostic> diagnostics,
) {
  if (exitCode == 0) return true;
  if (exitCode < 0 || exitCode > 3) return false;
  if (exitCode <=
      maxDiagnosticRank(diagnostics, fatalInfos: parsed.fatalInfos)) {
    return true;
  }
  final ProcessResult fallback = _runDartAnalyze(
    parsed,
    project,
    machine: false,
  );
  final fallbackOut = fallback.stdout as String;
  diagnostics.addAll(parseContextDiagnostics(fallbackOut, project));
  if (exitCode <=
      maxDiagnosticRank(diagnostics, fatalInfos: parsed.fatalInfos)) {
    return true;
  }
  stderr.write(unstage(fallback.stderr as String, project));
  stdout.write(unstage(fallbackOut, project));
  return false;
}

BaselineReport _writeBaselineReport(
  List<BaselineDiagnostic> diagnostics,
  AnalysisBaseline baseline,
) {
  final report = BaselineReport.of(diagnostics, baseline);
  for (final diagnostic in diagnostics) {
    final BaselineGroup? group = diagnostic.keyed
        ? report.groupFor(diagnostic.path, diagnostic.code)
        : null;
    final marker = group != null && group.withinCeiling
        ? ' - ${baselinedMarker(group)}'
        : '';
    stdout.writeln('${diagnostic.text}$marker');
  }
  for (final BaselineGroup group in report.groups) {
    if (!group.withinCeiling) stdout.writeln(baselineFailureLine(group));
  }
  return report;
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
  const requiredSummary = '--dart, --project, and --stamp are required';
  final flags = ToolFlags.parse(
    'analyze_runner',
    args,
    valueFlags: {'--dart', '--project', '--stamp', '--baseline'},
    listFlags: {'--source'},
    boolFlags: {'--fatal-infos'},
  );
  return (
    dart: flags.require('--dart', requiredSummary),
    project: flags.require('--project', requiredSummary),
    stamp: flags.require('--stamp', requiredSummary),
    fatalInfos: flags.flag('--fatal-infos'),
    sources: flags.values('--source'),
    baseline: flags.optional('--baseline'),
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
    final String norm = _normRel(s);
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
    for (final String rel in allowed) {
      if (rel.endsWith('.dart') &&
          FileSystemEntity.isFileSync('$project/src/$rel')) {
        return true;
      }
    }
    return false;
  }
  final srcDir = Directory('$project/src');
  final searchRoot = srcDir.existsSync() ? srcDir : Directory(project);
  for (final FileSystemEntity entity in searchRoot.listSync(recursive: true)) {
    if (entity.path.endsWith('.dart') &&
        FileSystemEntity.isFileSync(entity.path)) {
      return true;
    }
  }
  return false;
}

String _normRel(String raw) {
  String rel = raw.replaceAll(r'\', '/');
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
