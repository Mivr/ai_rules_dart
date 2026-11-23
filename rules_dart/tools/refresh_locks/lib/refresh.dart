/// Brings the `MODULE.bazel.lock` of each workspace up to date, or checks that
/// it is. All Bazel work goes through [Runner], so tests run without Bazel.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'workspaces.dart';

/// What a command printed (standard output, then standard error) and how it
/// ended.
final class CommandResult {
  const CommandResult(this.exitCode, this.output);
  final int exitCode;
  final String output;
}

/// Runs [command] in [workingDirectory].
typedef Runner = Future<CommandResult> Function(
  List<String> command,
  String workingDirectory,
);

/// The [Runner] that starts real processes.
Future<CommandResult> processRunner(
  List<String> command,
  String workingDirectory,
) async {
  final r = await Process.run(
    command.first,
    command.sublist(1),
    workingDirectory: workingDirectory,
  );
  return CommandResult(r.exitCode, '${r.stdout}${r.stderr}');
}

/// How a workspace ended up.
enum Status {
  /// Refresh: the lockfile is as it was. Check: the lockfile is current.
  current,

  /// Refresh only: the lockfile (or `MODULE.bazel`) changed.
  updated,

  /// The workspace failed on purpose, with the failure it is listed for.
  expected,

  /// Check only: the lockfile is stale or missing.
  stale,

  /// A command failed.
  failed,
}

/// The result for one workspace.
final class Outcome {
  Outcome(this.workspace, this.status, this.elapsed, [this.detail = '']);
  final Workspace workspace;
  final Status status;
  final Duration elapsed;

  /// For `stale` and `failed`: the first error and the command it came from.
  final String detail;

  bool get ok => status != Status.stale && status != Status.failed;
}

/// Settings of a run.
final class Options {
  const Options({
    this.bazel = 'bazel',
    this.jobs = 2,
    this.tidy = true,
    this.shutdown = true,
    this.expunge = false,
    this.retries = 1,
    this.expected = expectedFailures,
  });

  /// The Bazel (or wrapper) executable.
  final String bazel;

  /// Workspaces handled at the same time. Each one holds a Bazel server and
  /// asks the registry, and the pub server for packages it has no facts for.
  final int jobs;

  /// Refresh also runs `mod tidy`, which keeps `MODULE.bazel` canonical.
  final bool tidy;

  /// Stop the workspace's Bazel server when its turn is over.
  final bool shutdown;

  /// Also delete the workspace's output base (`clean --expunge`).
  final bool expunge;

  /// Extra attempts of a failing refresh step: registries and pub.dev fail
  /// now and then.
  final int retries;

  /// Workspaces expected to fail, see [expectedFailures].
  final Map<String, String> expected;
}

/// `.bazelrc.user` files in [workspaces]. They are gitignored and can change
/// the module graph (`--override_module`) or turn the lockfile off, so a lock
/// made through one is not the one CI checks.
List<String> userBazelrcs(List<Workspace> workspaces) => [
  for (final w in workspaces)
    if (File('${w.directory}/.bazelrc.user').existsSync())
      '${w.path}/.bazelrc.user',
];

/// The first `ERROR:` line of [output], else its last non-empty line.
String firstError(String output) {
  final lines = output.split('\n').map((l) => l.trimRight()).toList();
  for (final l in lines) {
    if (l.startsWith('ERROR:')) return l;
  }
  return lines.lastWhere((l) => l.isNotEmpty, orElse: () => '(no output)');
}

/// The module extensions of the lockfile text [lock] with entries for one
/// operating system or CPU (`os:linux,arch:amd64`) instead of the `general`
/// entry. An extension that declares `os_dependent` or `arch_dependent` is
/// recorded once for each system it ran on, so a lockfile made on Linux x64
/// has no entry for macOS or Windows, and Bazel there fails under
/// `--lockfile_mode=error`.
List<String> osKeyedExtensions(String lock) {
  final Object? json;
  try {
    json = jsonDecode(lock);
  } on FormatException {
    return const [];
  }
  final extensions = json is Map ? json['moduleExtensions'] : null;
  if (extensions is! Map) return const [];
  return [
    for (final MapEntry(:key, :value) in extensions.entries)
      if (value is Map && value.keys.any((k) => k != 'general'))
        '$key (${value.keys.where((k) => k != 'general').join('; ')})',
  ];
}

String osKeyedMessage(List<String> osKeyed) =>
    'extensions with per-system entries, which a lockfile made on one '
    'system lacks for the others: ${osKeyed.join(', ')}';

/// Runs a workspace's commands and keeps their output for the log.
final class _Session {
  _Session(this.ws, this.options, this.run);
  final Workspace ws;
  final Options options;
  final Runner run;
  final StringBuffer log = StringBuffer();

  /// Runs `bazel [args]`, retrying a failure up to [Options.retries] times.
  /// [failureIsOk] is a text that marks a failure as expected.
  Future<CommandResult> bazel(
    List<String> args, {
    String? failureIsOk,
    bool retry = true,
  }) async {
    late CommandResult r;
    for (var attempt = 0; attempt <= (retry ? options.retries : 0); attempt++) {
      final command = [options.bazel, ...args];
      log.writeln('\$ ${command.join(' ')}   (in ${ws.path})');
      r = await run(command, ws.directory);
      log.writeln(r.output);
      log.writeln('exit ${r.exitCode}\n');
      if (r.exitCode == 0) return r;
      if (failureIsOk != null && r.output.contains(failureIsOk)) return r;
    }
    return r;
  }
}

String? _bytes(String path) {
  final f = File(path);
  return f.existsSync() ? f.readAsStringSync() : null;
}

/// Refreshes the lockfile of [ws]: `mod tidy --lockfile_mode=refresh` (unless
/// [Options.tidy] is off) refreshes the registry hashes and keeps
/// `MODULE.bazel` canonical, then `mod deps --lockfile_mode=update`
/// evaluates every module extension of the graph, not only those its targets
/// reach, and `mod deps --lockfile_mode=error` proves the result. [log]
/// receives the output of every command.
Future<Outcome> refreshWorkspace(
  Workspace ws,
  Options options,
  Runner run,
  StringSink log,
) async {
  final started = DateTime.now();
  final s = _Session(ws, options, run);
  final expected = options.expected[ws.path];
  final lockBefore = _bytes(ws.lockfile);
  final moduleBefore = _bytes('${ws.directory}/MODULE.bazel');
  bool expectedFailure(CommandResult r) =>
      expected != null && r.output.contains(expected);

  // The first failing step, or null.
  String? failure;
  var failedOnPurpose = false;
  if (options.tidy) {
    final r = await s.bazel([
      'mod',
      'tidy',
      '--lockfile_mode=refresh',
    ], failureIsOk: expected);
    if (r.exitCode != 0 && !expectedFailure(r)) {
      failure = 'mod tidy: ${firstError(r.output)}';
    }
  }
  if (failure == null) {
    final r = await s.bazel([
      'mod',
      'deps',
      '--lockfile_mode=update',
    ], failureIsOk: expected);
    if (r.exitCode != 0 && !expectedFailure(r)) {
      failure = 'mod deps: ${firstError(r.output)}';
    } else if (r.exitCode != 0) {
      failedOnPurpose = true;
    } else {
      // A second pass in `error` mode is cheap and proves the lockfile
      // stands alone: no extension, registry file or fact missing from it.
      final v = await s.bazel([
        'mod',
        'deps',
        '--lockfile_mode=error',
      ], retry: false);
      if (v.exitCode != 0) {
        failure = 'mod deps --lockfile_mode=error: ${firstError(v.output)}';
      }
    }
  }
  if (options.expunge) {
    await s.bazel(['clean', '--expunge'], retry: false);
  } else if (options.shutdown) {
    await s.bazel(['shutdown'], retry: false);
  }
  log.write(s.log);

  final elapsed = DateTime.now().difference(started);
  if (failure != null) return Outcome(ws, Status.failed, elapsed, failure);
  if (failedOnPurpose) return Outcome(ws, Status.expected, elapsed, expected!);
  final lock = _bytes(ws.lockfile);
  final osKeyed = osKeyedExtensions(lock ?? '');
  if (osKeyed.isNotEmpty) {
    return Outcome(ws, Status.failed, elapsed, osKeyedMessage(osKeyed));
  }
  final changed =
      lock != lockBefore ||
      _bytes('${ws.directory}/MODULE.bazel') != moduleBefore;
  return Outcome(ws, changed ? Status.updated : Status.current, elapsed);
}

/// Checks the lockfile of [ws] without writing it: a missing file is stale,
/// otherwise `mod deps --lockfile_mode=error` must pass.
Future<Outcome> checkWorkspace(
  Workspace ws,
  Options options,
  Runner run,
  StringSink log,
) async {
  final started = DateTime.now();
  Duration elapsed() => DateTime.now().difference(started);
  if (!File(ws.lockfile).existsSync()) {
    return Outcome(ws, Status.stale, elapsed(), 'no MODULE.bazel.lock');
  }
  final s = _Session(ws, options, run);
  final expected = options.expected[ws.path];
  final r = await s.bazel([
    'mod',
    'deps',
    '--lockfile_mode=error',
  ], retry: false);
  if (options.shutdown) await s.bazel(['shutdown'], retry: false);
  log.write(s.log);
  if (r.exitCode == 0) {
    final osKeyed = osKeyedExtensions(_bytes(ws.lockfile) ?? '');
    return osKeyed.isEmpty
        ? Outcome(ws, Status.current, elapsed())
        : Outcome(ws, Status.stale, elapsed(), osKeyedMessage(osKeyed));
  }
  if (expected != null && r.output.contains(expected)) {
    return Outcome(ws, Status.expected, elapsed(), expected);
  }
  return Outcome(ws, Status.stale, elapsed(), firstError(r.output));
}

/// Runs [work] on every item of [items], at most [jobs] at a time, and
/// returns the results in the order of [items]. [onDone] is called as each
/// one finishes.
Future<List<R>> runPool<T, R>(
  List<T> items,
  int jobs,
  Future<R> Function(T) work, {
  void Function(R result, int done)? onDone,
}) async {
  final results = List<R?>.filled(items.length, null);
  var next = 0;
  var done = 0;
  Future<void> worker() async {
    while (next < items.length) {
      final i = next++;
      results[i] = await work(items[i]);
      onDone?.call(results[i] as R, ++done);
    }
  }

  await Future.wait([
    for (
      var i = 0;
      i < (jobs < 1 ? 1 : jobs).clamp(1, items.length == 0 ? 1 : items.length);
      i++
    )
      worker(),
  ]);
  return [for (final r in results) r as R];
}
