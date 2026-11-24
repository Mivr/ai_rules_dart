/// The e2e sweep: every e2e workspace of both modules, run through the
/// repository's own spec runner, and one table of the results.
library;

import 'dart:async';
import 'dart:io';

/// How one workspace ended.
enum Outcome {
  /// The runner exited 0.
  passed('PASS'),

  /// The runner exited non-zero, timed out, or the workspace has no spec.
  failed('FAIL'),

  /// The host cannot run it; [SweepResult.note] says why.
  skipped('SKIP'),

  /// A directory under `e2e/` that is not a Bazel workspace.
  helper('HELPER');

  const Outcome(this.label);

  /// The word the table prints.
  final String label;
}

/// One row of the table.
final class SweepResult {
  /// Creates a row.
  const SweepResult({
    required this.module,
    required this.name,
    required this.outcome,
    required this.seconds,
    required this.note,
  });

  /// `rules_dart` or `rules_flutter`.
  final String module;

  /// The directory name under `<module>/e2e/`.
  final String name;

  /// How it ended.
  final Outcome outcome;

  /// Wall time of the run, 0 when it did not run.
  final int seconds;

  /// A skip reason, or the first useful line of a failure's log.
  final String note;
}

/// One directory under `<module>/e2e/`.
final class Workspace {
  /// Creates a workspace.
  const Workspace(this.module, this.name, this.path);

  /// `rules_dart` or `rules_flutter`.
  final String module;

  /// The directory name.
  final String name;

  /// Absolute path.
  final String path;

  /// Whether the directory is a Bazel workspace.
  bool get isWorkspace => File('$path/MODULE.bazel').existsSync();

  /// Whether the workspace carries a spec for the runner.
  bool get hasSpec => File('$path/e2e.yaml').existsSync();

  /// `<module>/<name>`, the key of [hostSkips] and `--only`.
  String get id => '$module/$name';
}

/// Workspaces that cannot run on a Linux x86_64 host with no device, and why.
///
/// The key is `<module>/<name>`. `--include-unrunnable` runs them anyway.
const Map<String, String> hostSkips = {};

/// The modules and where each one's runner is built.
const List<({String module, String runnerTarget})> modules = [
  (module: 'rules_dart', runnerTarget: '//e2e_runner:e2e_runner'),
  (module: 'rules_flutter', runnerTarget: '//tools/e2e_runner:e2e_runner'),
];

/// The workspaces of [module] under [repoRoot], sorted by name.
List<Workspace> discover(String repoRoot, String module) {
  final dir = Directory('$repoRoot/$module/e2e');
  if (!dir.existsSync()) return const [];
  final found = <Workspace>[
    for (final entry in dir.listSync(followLinks: false))
      if (entry is Directory)
        Workspace(
          module,
          entry.uri.pathSegments.reversed.skip(1).first,
          entry.path,
        ),
  ]..sort((a, b) => a.name.compareTo(b.name));
  return found;
}

/// The first line of [log] worth showing in the table: the runner's own
/// complaint, else the first Bazel `ERROR:` line, else the last line.
String failureNote(String log) {
  final lines = log
      .split('\n')
      .map((l) => l.trimRight())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.isEmpty) return 'no output';
  String? pick(bool Function(String) test) {
    for (final line in lines) {
      if (test(line)) return line;
    }
    return null;
  }

  final spec = pick((l) => l.startsWith('spec ') && l.contains('command "'));
  final error = pick((l) => l.contains('ERROR:') || l.startsWith('Error'));
  var note = spec ?? error ?? lines.last;
  final base = RegExp(r'^spec \S+/e2e\.yaml: ');
  note = note.replaceFirst(base, '');
  return note.length > 160 ? '${note.substring(0, 157)}...' : note;
}

/// The table as Markdown, rows in [results]' order, with the counts below it.
String renderTable(List<SweepResult> results) {
  final out = StringBuffer()
    ..writeln('| Workspace | Result | Seconds | Note |')
    ..writeln('|---|---|---:|---|');
  for (final r in results) {
    final note = r.note.replaceAll('|', r'\|');
    out.writeln(
      '| ${r.module}/${r.name} | ${r.outcome.label} | ${r.seconds} | $note |',
    );
  }
  out
    ..writeln()
    ..writeln(renderCounts(results));
  return out.toString();
}

/// One line of counts per outcome.
String renderCounts(List<SweepResult> results) {
  int count(Outcome o) => results.where((r) => r.outcome == o).length;
  return 'Total ${results.length}: '
      '${count(Outcome.passed)} passed, '
      '${count(Outcome.failed)} failed, '
      '${count(Outcome.skipped)} cannot run on this host, '
      '${count(Outcome.helper)} not workspaces.';
}

/// What a sweep needs from its caller.
final class SweepConfig {
  /// Creates a config.
  const SweepConfig({
    required this.repoRoot,
    required this.client,
    required this.jobs,
    required this.logDir,
    required this.timeout,
    required this.only,
    required this.includeUnrunnable,
  });

  /// The repository root, holding `rules_dart/` and `rules_flutter/`.
  final String repoRoot;

  /// The Bazel client: `bazel`, or a wrapper such as `rdf-bazel`.
  final String client;

  /// Workspaces running at once.
  final int jobs;

  /// Where each workspace's log goes.
  final String logDir;

  /// The longest one workspace may run.
  final Duration timeout;

  /// When non-empty, only `<module>/<name>` ids matching one of these.
  final List<Pattern> only;

  /// Whether to run [hostSkips] too.
  final bool includeUnrunnable;
}

/// Builds each module's runner with the client and returns its executable.
///
/// Returns null, after printing why, when a build fails.
Future<Map<String, String>?> buildRunners(SweepConfig config) async {
  final runners = <String, String>{};
  for (final m in modules) {
    final cwd = m.module == 'rules_dart'
        ? '${config.repoRoot}/rules_dart/tools'
        : '${config.repoRoot}/rules_flutter';
    final build = await Process.run(config.client, [
      'build',
      m.runnerTarget,
    ], workingDirectory: cwd);
    if (build.exitCode != 0) {
      stderr
        ..writeln('building ${m.runnerTarget} in $cwd failed:')
        ..writeln(build.stderr);
      return null;
    }
    final info = await Process.run(config.client, [
      'info',
      'bazel-bin',
    ], workingDirectory: cwd);
    final binDir = (info.stdout as String).trim();
    final package = m.runnerTarget.substring(2).split(':').first;
    runners[m.module] = '$binDir/$package/e2e_runner';
  }
  return runners;
}

/// Runs every selected workspace and returns the rows in module and name
/// order. [runners] maps a module to its built runner.
Future<List<SweepResult>> runSweep(
  SweepConfig config,
  Map<String, String> runners,
) async {
  final all = <Workspace>[
    for (final m in modules) ...discover(config.repoRoot, m.module),
  ];
  final selected = all.where((w) {
    if (config.only.isEmpty) return true;
    return config.only.any((p) => p.allMatches(w.id).isNotEmpty);
  }).toList();
  Directory(config.logDir).createSync(recursive: true);
  final results = List<SweepResult?>.filled(selected.length, null);
  var next = 0;
  Future<void> worker() async {
    while (next < selected.length) {
      final index = next++;
      results[index] = await _runOne(config, runners, selected[index]);
      stderr.writeln(
        '${results[index]!.outcome.label.padRight(6)} '
        '${selected[index].id} (${results[index]!.seconds}s)',
      );
    }
  }

  await Future.wait([for (var i = 0; i < config.jobs; i++) worker()]);
  return results.cast<SweepResult>();
}

Future<SweepResult> _runOne(
  SweepConfig config,
  Map<String, String> runners,
  Workspace ws,
) async {
  SweepResult row(Outcome o, String note, [int seconds = 0]) => SweepResult(
    module: ws.module,
    name: ws.name,
    outcome: o,
    seconds: seconds,
    note: note,
  );
  if (!ws.isWorkspace) {
    return row(
      Outcome.helper,
      'sources used by other workspaces, no MODULE.bazel',
    );
  }
  final skip = hostSkips[ws.id];
  if (skip != null && !config.includeUnrunnable) {
    return row(Outcome.skipped, skip);
  }
  if (!ws.hasSpec) {
    return row(Outcome.failed, 'no e2e.yaml');
  }
  final started = DateTime.now();
  final logFile = File('${config.logDir}/${ws.module}-${ws.name}.log');
  final process = await Process.start(runners[ws.module]!, [
    '--workspace=${ws.path}',
    '--bazel=${config.client}',
  ]);
  final buffer = StringBuffer();
  final done = Future.wait([
    process.stdout
        .transform(const SystemEncoding().decoder)
        .forEach(buffer.write),
    process.stderr
        .transform(const SystemEncoding().decoder)
        .forEach(buffer.write),
  ]);
  var timedOut = false;
  final timer = Timer(config.timeout, () {
    timedOut = true;
    process.kill(ProcessSignal.sigterm);
  });
  final code = await process.exitCode;
  timer.cancel();
  await done;
  final seconds = DateTime.now().difference(started).inSeconds;
  final log = buffer.toString();
  logFile.writeAsStringSync(log);
  if (timedOut) {
    return row(
      Outcome.failed,
      'timed out after ${config.timeout.inMinutes} min',
      seconds,
    );
  }
  if (code == 0) return row(Outcome.passed, '', seconds);
  return row(Outcome.failed, failureNote(log), seconds);
}
