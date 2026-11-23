/// Refreshes, or checks, the `MODULE.bazel.lock` of every Bazel workspace of
/// the repository: both modules, `rules_dart/tools`, `rules_dart/dev` and every
/// e2e workspace.
///
///     cd rules_dart/tools
///     bazel run //refresh_locks -- [options] [workspace ...]
///
/// See `--help`.
library;

import 'dart:io';

import 'package:refresh_locks/refresh.dart';
import 'package:refresh_locks/workspaces.dart';

const _usage = '''
Refreshes the MODULE.bazel.lock of every Bazel workspace of the repository.

  bazel run //refresh_locks -- [options] [workspace ...]

A workspace is a path from the repository root (`rules_dart/e2e/smoke`), also
as a prefix (`rules_flutter/e2e`). With none, every workspace.

Options
  --check          Write nothing. Fail, listing them, when a lockfile is
                   missing or stale: `mod deps --lockfile_mode=error` in each.
  --list           Print the workspaces and the ones skipped, and stop.
  --jobs=N         Workspaces handled at once (default 2). Each runs a Bazel
                   server and asks the registry and pub.dev.
  --bazel=PATH     The Bazel executable (default: \$BAZEL, else `bazel`).
  --no-tidy        Skip `mod tidy`, which only keeps MODULE.bazel canonical.
  --keep-servers   Leave each workspace's Bazel server running.
  --expunge        Delete each workspace's output base when done (disk).
  --retries=N      Extra attempts of a failing step (default 1).
  --log-dir=DIR    Where the commands' output goes (default: a temp directory).
  --root=DIR       The repository root (default: found from the current
                   directory or \$BUILD_WORKSPACE_DIRECTORY).
  --allow-bazelrc-user
                   Run although a workspace has a .bazelrc.user.

Exit status: 0 when every lockfile is current (or was refreshed), 1 otherwise.
''';

Future<void> main(List<String> args) async {
  var check = false;
  var list = false;
  var tidy = true;
  var shutdown = true;
  var expunge = false;
  var allowUser = false;
  var jobs = 2;
  var retries = 1;
  String? root;
  String? logDir;
  var bazel = Platform.environment['BAZEL'] ?? 'bazel';
  final filters = <String>[];

  for (final a in args) {
    String value(String name) => a.substring(name.length + 1);
    if (a == '--help' || a == '-h') {
      stdout.write(_usage);
      return;
    } else if (a == '--check') {
      check = true;
    } else if (a == '--list') {
      list = true;
    } else if (a == '--no-tidy') {
      tidy = false;
    } else if (a == '--keep-servers') {
      shutdown = false;
    } else if (a == '--expunge') {
      expunge = true;
    } else if (a == '--allow-bazelrc-user') {
      allowUser = true;
    } else if (a.startsWith('--jobs=')) {
      jobs = int.tryParse(value('--jobs')) ?? -1;
    } else if (a.startsWith('--retries=')) {
      retries = int.tryParse(value('--retries')) ?? -1;
    } else if (a.startsWith('--bazel=')) {
      bazel = value('--bazel');
    } else if (a.startsWith('--root=')) {
      root = value('--root');
    } else if (a.startsWith('--log-dir=')) {
      logDir = value('--log-dir');
    } else if (a.startsWith('-')) {
      stderr.writeln('Unknown option $a\n$_usage');
      exit(2);
    } else {
      filters.add(a);
    }
  }
  if (jobs < 1 || retries < 0) {
    stderr.writeln('--jobs must be at least 1 and --retries at least 0.');
    exit(2);
  }

  // Under `bazel run` the working directory is the runfiles tree; the
  // directory the user ran it from is in BUILD_WORKSPACE_DIRECTORY.
  root ??= findRepositoryRoot(
    Platform.environment['BUILD_WORKING_DIRECTORY'] ??
        Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
        Directory.current.path,
  );
  if (root == null) {
    stderr.writeln(
      'Not inside the repository (no rules_dart/ and '
      'rules_flutter/ above here). Pass --root=DIR.',
    );
    exit(2);
  }

  final all = findWorkspaces(root);
  final selected = selectWorkspaces(all, filters);
  if (list) {
    for (final w in selected) {
      stdout.writeln(w.path);
    }
    stdout.writeln('\n${selected.length} workspaces; skipped:');
    skippedWorkspaces.forEach((p, why) => stdout.writeln('  $p: $why'));
    return;
  }
  if (selected.isEmpty) {
    stderr.writeln('No workspace matches ${filters.join(' ')}.');
    exit(2);
  }
  final user = userBazelrcs(selected);
  if (user.isNotEmpty && !allowUser) {
    stderr.writeln(
      'A .bazelrc.user can override modules or turn the lockfile '
      'off, so the lock made through it is not the one CI checks. Move '
      'these aside, or pass --allow-bazelrc-user:\n  ${user.join('\n  ')}',
    );
    exit(2);
  }

  final dir = Directory(
    logDir ?? Directory.systemTemp.createTempSync('refresh_locks_').path,
  )..createSync(recursive: true);
  final options = Options(
    bazel: bazel,
    jobs: jobs,
    tidy: tidy,
    shutdown: shutdown,
    expunge: expunge,
    retries: retries,
  );
  stdout.writeln(
    '${check ? 'Checking' : 'Refreshing'} ${selected.length} '
    'workspaces, $jobs at a time, with `$bazel`. Logs: ${dir.path}',
  );

  final started = DateTime.now();
  final outcomes = await runPool<Workspace, Outcome>(
    selected,
    jobs,
    (w) async {
      final log = StringBuffer();
      final outcome = check
          ? await checkWorkspace(w, options, processRunner, log)
          : await refreshWorkspace(w, options, processRunner, log);
      File('${dir.path}/${w.path.replaceAll('/', '__')}.log')
          .writeAsStringSync(log.toString());
      return outcome;
    },
    onDone: (o, done) {
      final secs = (o.elapsed.inMilliseconds / 1000).toStringAsFixed(1);
      final detail = o.detail.isEmpty ? '' : '  ${o.detail}';
      stdout.writeln(
        '[${'$done'.padLeft('${selected.length}'.length)}/'
        '${selected.length}] ${o.status.name.padRight(8)} '
        '${o.workspace.path} (${secs}s)$detail',
      );
    },
  );

  int count(Status s) => outcomes.where((o) => o.status == s).length;
  final minutes = DateTime.now().difference(started).inSeconds / 60;
  stdout.writeln(
    '\n${outcomes.length} workspaces in '
    '${minutes.toStringAsFixed(1)} min: ${count(Status.current)} current, '
    '${count(Status.updated)} updated, ${count(Status.expected)} failed as '
    'expected, ${count(Status.stale)} stale, ${count(Status.failed)} failed.',
  );
  final bad = outcomes.where((o) => !o.ok).toList();
  if (bad.isNotEmpty) {
    stdout.writeln(
      check
          ? '\nStale lockfiles; refresh them with `bazel run //refresh_locks`:'
          : '\nFailed:',
    );
    for (final o in bad) {
      stdout.writeln('  ${o.workspace.path}: ${o.detail}');
    }
    exit(1);
  }
}
