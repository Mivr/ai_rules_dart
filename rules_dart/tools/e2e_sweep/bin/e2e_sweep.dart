/// Runs every e2e workspace of both modules and prints the result table.
///
///     cd rules_dart/tools
///     bazel run //e2e_sweep:e2e_sweep -- --client=/work/rdf/bin/rdf-bazel
///
/// Flags (all optional):
///   --client=<path>         Bazel client for the runners and the workspaces
///                           (default `bazel`).
///   --jobs=<n>              Workspaces at once (default 2).
///   --only=<regex>          Only `<module>/<name>` ids matching it; repeatable.
///   --logs=<dir>            Where each workspace's log goes
///                           (default `$TMPDIR/e2e_sweep_logs`).
///   --report=<file>         Also write the table to this file.
///   --timeout-minutes=<n>   Longest one workspace may run (default 60).
///   --include-unrunnable    Run the workspaces the host cannot run, too.
///
/// Each workspace runs through its module's `e2e_runner` (`mivr-e2e-spec/1`),
/// which stages a copy under its own output base and removes it afterwards.
/// Exits 1 when any workspace failed.
library;

import 'dart:io';

import 'package:e2e_sweep/sweep.dart';

String? _value(List<String> args, String name) {
  final prefix = '--$name=';
  for (final arg in args) {
    if (arg.startsWith(prefix)) return arg.substring(prefix.length);
  }
  return null;
}

Future<void> main(List<String> args) async {
  final callerDir =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
      Directory.current.path;
  var repoRoot = Directory(callerDir).absolute.path;
  while (!Directory('$repoRoot/rules_dart/e2e').existsSync()) {
    final parent = Directory(repoRoot).parent.path;
    if (parent == repoRoot) {
      stderr.writeln('e2e_sweep: run it inside the repository checkout');
      exit(2);
    }
    repoRoot = parent;
  }
  final client = _value(args, 'client') ?? 'bazel';
  final logs =
      _value(args, 'logs') ?? '${Directory.systemTemp.path}/e2e_sweep_logs';
  final config = SweepConfig(
    repoRoot: repoRoot,
    client: client,
    jobs: int.tryParse(_value(args, 'jobs') ?? '') ?? 2,
    logDir: Directory(logs).absolute.path,
    timeout: Duration(
      minutes: int.tryParse(_value(args, 'timeout-minutes') ?? '') ?? 60,
    ),
    only: [
      for (final arg in args)
        if (arg.startsWith('--only=')) RegExp(arg.substring('--only='.length)),
    ],
    includeUnrunnable: args.contains('--include-unrunnable'),
  );
  final started = DateTime.now();
  final runners = await buildRunners(config);
  if (runners == null) exit(2);
  final results = await runSweep(config, runners);
  final table = renderTable(results);
  stdout.write(table);
  final elapsed = DateTime.now().difference(started);
  stdout.writeln(
    'Took ${elapsed.inMinutes} min ${elapsed.inSeconds % 60} s; logs in ${config.logDir}.',
  );
  final report = _value(args, 'report');
  if (report != null) File(report).writeAsStringSync(table);
  exit(results.any((r) => r.outcome == Outcome.failed) ? 1 : 0);
}
