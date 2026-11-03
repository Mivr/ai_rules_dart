// Build-action runner for `dart fix` over a staged project directory.
//
// `dart fix --apply` rewrites sources in place, which an action cannot do: its
// inputs are a read-only sandbox and its outputs must be declared up front. So
// the staged project is copied to a scratch directory and fixed there, and only
// the files the rule declared write-back eligible are emitted. Pure Dart (no
// shell) so the action is portable to Windows.
import 'dart:convert';
import 'dart:io';

import 'package:rules_dart_guard/directive_guard.dart';

import 'analyze_runner_staged_prune.dart';
import 'private_home.dart';
import 'project_lint_options.dart';
import 'staged_project_copy.dart';

/// Recorded for every changed file outside the eligible set. One constant
/// string: the manifest says *that* a fix was discarded, and the rule's
/// excludes are what say why.
const _droppedReason = 'not write-back eligible';

/// Rewritten by this runner (see [repointPackageConfig]), so its difference
/// from the staged original is self-inflicted rather than a discarded fix.
const _packageConfigPath = '.dart_tool/package_config.json';

void main(List<String> args) {
  final parsed = _parseFixArgs(args);

  final staged = _stageFixProject(parsed);

  final result = _runDartFix(parsed.dart, parsed.scratch);

  // Bazel echoes any action output, and this action runs whenever fixes are
  // asked for: its progress chatter is printed only when it fails. What it
  // changed is in the manifest.
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    stdout.write(result.stdout);
    exit(result.exitCode);
  }

  _emitFixes(parsed, staged.writeBack, staged.stripped);
}

/// Parsed `fix_runner` command line.
typedef _FixArgs = ({
  String dart,
  String project,
  String scratch,
  String fixes,
  String manifest,
  String eligible,
});

/// Parses the command line, exiting 64 on an unknown or missing argument.
_FixArgs _parseFixArgs(List<String> args) {
  String? dart;
  String? project;
  String? scratch;
  String? fixes;
  String? manifest;
  String? eligible;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--dart':
        dart = args[++i];
      case '--project':
        project = args[++i];
      case '--scratch':
        scratch = args[++i];
      case '--fixes':
        fixes = args[++i];
      case '--manifest':
        manifest = args[++i];
      case '--eligible':
        eligible = args[++i];
      default:
        stderr.writeln('fix_runner: unknown argument ${args[i]}');
        exit(64);
    }
  }
  if (dart == null ||
      project == null ||
      scratch == null ||
      fixes == null ||
      manifest == null ||
      eligible == null) {
    stderr.writeln(
      'fix_runner: --dart, --project, --scratch, --fixes, '
      '--manifest, and --eligible are all required',
    );
    exit(64);
  }
  return (
    dart: dart,
    project: project,
    scratch: scratch,
    fixes: fixes,
    manifest: manifest,
    eligible: eligible,
  );
}

/// Stages the project into the scratch directory for `dart fix --apply`:
/// prunes orphaned staged files, refuses host-reading directives, clears the
/// scratch directory, copies the tree with a repointed package config, and
/// strips project lint rule keys the stock `dart fix` does not know from the
/// scratch copies. Returns the rule's write-back map and the stripped options
/// paths (self-inflicted differences the manifest must not report as dropped).
({Map<String, String> writeBack, Set<String> stripped}) _stageFixProject(
  _FixArgs parsed,
) {
  final writeBack = _readEligible(parsed.eligible);
  final allowedSrcPaths = pruneOrphanedStagedFiles(parsed.project);

  // No staged source may read the host: a `file:` URI (in any spelling), any
  // other non-`dart:`/`package:` directive URI, a `package:` URI climbing
  // above its package, or a relative URI climbing out of the staged tree
  // would reach an undeclared file through the fixer's working directory.
  // Refuse before fixing, through the one shared staged-source check.
  final violations = findStagedDirectiveViolations(
    projectStagedRoots(parsed.project),
    tool: 'fix_runner',
  );
  if (violations.isNotEmpty) {
    for (final violation in violations) {
      stderr.writeln(violation);
    }
    exit(1);
  }

  final scratchDir = Directory(parsed.scratch);
  if (scratchDir.existsSync()) {
    for (final child in scratchDir.listSync(followLinks: false)) {
      child.deleteSync(recursive: true);
    }
  }
  copyStagedTree(
    parsed.project,
    parsed.scratch,
    projectRoot: parsed.project,
    allowedSrcPaths: allowedSrcPaths,
  );
  repointPackageConfig(parsed.project, parsed.scratch);
  final stripped = stripStagedProjectLintOptions(parsed.scratch);
  return (writeBack: writeBack, stripped: stripped);
}

/// Runs `dart fix --apply` over [scratch] with a hermetic home directory.
ProcessResult _runDartFix(String dart, String scratch) => withPrivateHome(
  'rules_dart_fix_home.',
  (env) => Process.runSync(dart, ['fix', '--apply', scratch], environment: env),
);

/// Copies each changed write-back-eligible file into the fixes directory and
/// writes the manifest of fixed and dropped files. Stripped options files are
/// never dropped: their difference from the staged originals is self-inflicted.
void _emitFixes(
  _FixArgs parsed,
  Map<String, String> writeBack,
  Set<String> stripped,
) {
  // Declared outputs must exist even when nothing was fixed.
  final fixesDir = Directory(parsed.fixes);
  if (fixesDir.existsSync()) {
    for (final child in fixesDir.listSync(followLinks: false)) {
      child.deleteSync(recursive: true);
    }
  }
  fixesDir.createSync(recursive: true);

  final fixed = <Map<String, String>>[];
  writeBack.forEach((staged, workspace) {
    if (!_differs('${parsed.project}/$staged', '${parsed.scratch}/$staged')) {
      return;
    }
    copyStagedFile('${parsed.scratch}/$staged', '${parsed.fixes}/$workspace');
    fixed.add({'staged': staged, 'workspace': workspace});
  });

  final dropped = _scanDropped(
    parsed.project,
    parsed.scratch,
    writeBack.keys.toSet(),
    stripped,
  );

  // Bazel actions must be reproducible; directory listings are not ordered.
  fixed.sort((a, b) => a['staged']!.compareTo(b['staged']!));
  dropped.sort((a, b) => a['staged']!.compareTo(b['staged']!));

  const encoder = JsonEncoder.withIndent('  ');
  File(parsed.manifest).writeAsStringSync(
    '${encoder.convert({'fixed': fixed, 'dropped': dropped})}\n',
  );
}

/// Removes any orphaned symlinks or unlisted files under `<project>/src/` when
/// `.dart_tool/src_manifest.txt` is present, and under sibling `<name>.extpkgs/`
/// when `.dart_tool/extpkgs_manifest.txt` is present. Returns the set of allowed
/// `src/<rel>` paths relative to [project] (or `null` when no manifest is
/// present). Never prunes without a manifest.
Set<String>? pruneOrphanedStagedFiles(String project) => pruneStagedSrcTree(
  project,
  spelling: (
    manifestSrcEntry: (line) => 'src/${_relative('', line)}',
    manifestExtEntry: (line) => _relative('', line),
    // `fix_runner` keys its `src/` allow-list project-relative
    // (`src/<rel>`), so `src/` entities are spelled below [project], not
    // below the offered root. Sibling `.extpkgs` entities stay
    // `.extpkgs`-relative.
    relativeSrcPath: (_root, path) => _relative(project, path),
    relativeExtPath: _relative,
  ),
);

/// Reads the rule's `<staged-relative>\t<workspace-relative>` write-back list.
Map<String, String> _readEligible(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('fix_runner: --eligible file not found: $path');
    exit(64);
  }
  final entries = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final fields = line.split('\t');
    if (fields.length != 2 || fields[0].isEmpty || fields[1].isEmpty) {
      stderr.writeln('fix_runner: malformed --eligible entry: $line');
      exit(64);
    }
    entries[fields[0]] = fields[1];
  }
  return entries;
}

/// Lists every changed file that no one asked to have written back.
///
/// Belt and braces: the rule excludes generated and read-only sources from the
/// fixed project, so this should always come back empty. A non-empty list means
/// the fixer reached something upstream meant to keep out of its way, and the
/// manifest is where that shows up rather than being silently discarded.
List<Map<String, String>> _scanDropped(
  String project,
  String scratch,
  Set<String> eligible,
  Set<String> stripped,
) {
  final dropped = <Map<String, String>>[];
  final tree = Directory(scratch).listSync(recursive: true, followLinks: false);
  for (final entity in tree) {
    if (entity is! File) continue;
    final staged = _relative(scratch, entity.path);
    if (staged == _packageConfigPath ||
        eligible.contains(staged) ||
        stripped.contains(staged)) {
      continue;
    }
    if (_differs('$project/$staged', entity.path)) {
      dropped.add({'staged': staged, 'reason': _droppedReason});
    }
  }
  return dropped;
}

/// The part of [path] below [root], in the `/`-separated form the eligible
/// list and the manifest use.
String _relative(String root, String path) {
  var rel = path.substring(root.length).replaceAll(r'\', '/');
  while (rel.startsWith('/')) {
    rel = rel.substring(1);
  }
  return rel;
}

/// Whether the two paths hold different bytes. Two missing files match.
bool _differs(String original, String candidate) {
  final a = File(original);
  final b = File(candidate);
  final aExists = a.existsSync();
  if (aExists != b.existsSync()) return true;
  if (!aExists) return false;
  final aBytes = a.readAsBytesSync();
  final bBytes = b.readAsBytesSync();
  if (aBytes.length != bBytes.length) return true;
  for (var i = 0; i < aBytes.length; i++) {
    if (aBytes[i] != bBytes[i]) return true;
  }
  return false;
}
