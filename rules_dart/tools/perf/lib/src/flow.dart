/// A flow and the one way every flow is measured: state set up untimed, one
/// timed command per run, at least five runs, the load and the other Bazel
/// servers before each run, and workers proven warm where the flow says so.
library;

import 'dart:io';

import 'bazel.dart';
import 'host.dart';
import 'ledger.dart';
import 'proc.dart';
import 'stats.dart';

/// What one timed command measured.
final class Measured {
  /// A figure ([value], in the flow's unit) and what else the run recorded.
  const Measured(
    this.value, {
    this.mnemonics = const {},
    this.extra = const {},
  });

  /// Seconds, or a count for a count flow.
  final double value;

  /// Actions that ran, by mnemonic (from the execution log).
  final Map<String, int> mnemonics;

  /// Other figures of this run.
  final Map<String, Object?> extra;
}

/// Thrown by a flow that this host cannot run; the row says why.
final class NotAvailable implements Exception {
  /// The reason.
  const NotAvailable(this.reason);

  /// Why the flow cannot run here.
  final String reason;

  @override
  String toString() => 'not available here: $reason';
}

/// Everything a flow may use.
final class Ctx {
  /// The harness's settings.
  Ctx({
    required this.repo,
    required this.scratch,
    required this.bazel,
    required this.stockEnv,
    required this.runs,
    required this.noisyLoad,
    this.settle = Duration.zero,
    this.bazelrcLines = const [],
    this.androidBazelrc,
    this.options = const {},
    this.host = const Host(),
    this.commit,
    this.sdk = 'unknown',
  });

  /// The repository root, holding `rules_dart/` and `rules_flutter/`.
  final String repo;

  /// The scratch directory: generated and copied workspaces, logs.
  final String scratch;

  /// The Bazel command (a wrapper is fine).
  final List<String> bazel;

  /// The variables the stock tools' environment sets on top of this
  /// process's (Flutter and Dart on `PATH`, `PUB_CACHE`, Java, Android,
  /// Gradle).
  final Map<String, String> stockEnv;

  /// The value of [name] in the stock tools' environment.
  String? stockVar(String name) => stockEnv[name] ?? Platform.environment[name];

  /// Runs per flow.
  final int runs;

  /// The 1-minute load average above which a run is noisy.
  final double noisyLoad;

  /// How long a run may wait, after its untimed preparation, for the
  /// 1-minute load to fall under [noisyLoad]: the load the harness's own
  /// set-up and preparation leave behind is not noise from other work.
  final Duration settle;

  /// Lines every copied or generated workspace's `.bazelrc.user` gets (a
  /// pub mirror, say).
  final List<String> bazelrcLines;

  /// An rc file Android workspaces import, or null.
  final String? androidBazelrc;

  /// Named settings of single flows (`device`, `adb_port`, `pub_lock`, ...).
  final Map<String, String> options;

  /// The process table.
  final Host host;

  /// The commit measured.
  final String? commit;

  /// The SDK named in rows.
  final String sdk;

  /// The log file of [flowId].
  File log(String flowId) {
    final dir = Directory('$scratch/logs')..createSync(recursive: true);
    return File('${dir.path}/$flowId.log');
  }

  /// Workspaces a flow ran Bazel in, so their servers can be stopped.
  final Set<String> workspaces = {};

  /// A [Bazel] for [workspace] logging to [flowId]'s log.
  Bazel bazelIn(String workspace, String flowId) {
    workspaces.add(workspace);
    return Bazel(bazel, workspace, log: log(flowId), env: stockEnv);
  }

  /// A command run with the stock tools' environment.
  Cmd stock(
    List<String> argv,
    String cwd, {
    Map<String, String> env = const {},
  }) => Cmd(argv, cwd: cwd, env: {...stockEnv, ...env});

  int _salt = DateTime.now().microsecondsSinceEpoch;

  /// A number no earlier run used, for edits and cache-busting flags.
  int fresh() => ++_salt;
}

/// One measurable flow on one side (the rules or the stock tools).
abstract class Flow {
  /// The harness's id: `<group>.<case>.<side>`.
  String get id;

  /// `rules_dart`, `rules_flutter` or `stock`.
  String get tool;

  /// The workspace or corpus project.
  String get corpus;

  /// The flow name in the ledger.
  String get flow;

  /// The state before the timed command (`warm`, `edit_body`, `cold`, ...).
  String get state;

  /// `s`, or `actions` for a count flow.
  String get unit => 's';

  /// Whether persistent workers must stay warm across the runs.
  bool get warm => false;

  /// Labels for selecting flows: `cheap` (seconds; the regression check's
  /// set), `heavy`, `android`, `emulator`, `mirror`, `stock`.
  Set<String> get tags;

  /// The Bazel workspace whose server the flow measures, once set up.
  Bazel? get server => null;

  /// The exact timed command and how the state is set up, for the notes.
  String describe(Ctx c);

  /// Untimed, once before the runs.
  Future<void> setUp(Ctx c) async {}

  /// Untimed, before each run.
  Future<void> prepare(Ctx c, int run) async {}

  /// The one timed command of a run.
  Future<Measured> measure(Ctx c, int run);

  /// Untimed, once after the runs, also after a failure: restores edits.
  Future<void> tearDown(Ctx c) async {}
}

/// Runs of a warm flow that may lose their workers (and be discarded)
/// before the flow fails.
const maxDiscarded = 2;

/// Measures [flow] [Ctx.runs] times and returns its row.
Future<Row> measureFlow(Flow flow, Ctx c, {void Function(String)? say}) async {
  final runs = <double>[];
  final loads = <double>[];
  final servers = <int>[];
  var mnemonics = <String, int>{};
  final extras = <Map<String, Object?>>[];
  Map<String, Object?>? workers;
  var status = 'ok';
  final notes = StringBuffer(flow.describe(c));
  try {
    await flow.setUp(c);
    final ob = await flow.server?.outputBase();
    final killedBefore = ob == null ? null : killedUnknown(ob);
    var killed = killedBefore;
    var workersBefore = 0;
    var workersLost = 0;
    var discarded = 0;
    for (var i = 0; runs.length < c.runs; i++) {
      await flow.prepare(c, i);
      final settleBy = DateTime.now().add(c.settle);
      while ((c.host.load1() ?? 0) > c.noisyLoad &&
          DateTime.now().isBefore(settleBy)) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      final load = c.host.load1() ?? -1;
      loads.add(load);
      servers.add(c.host.otherBazelServers(ob));
      final spid = ob == null ? null : serverPid(ob);
      final before = spid == null ? <int>{} : c.host.workers(spid);
      if (i == 0) workersBefore = before.length;
      final m = await flow.measure(c, i);
      final after = spid == null ? <int>{} : c.host.workers(spid);
      if (i > 0) workersLost += before.difference(after).length;
      if (flow.warm && ob != null) {
        final now = killedUnknown(ob);
        if (now > killed!) {
          // The workers did not stay warm: this run fails and is not kept.
          final why =
              'run ${i + 1} discarded: KILLED_UNKNOWN in the server log grew '
              'from $killed to $now (${m.value.toStringAsFixed(3)} ${flow.unit})';
          say?.call('  $why');
          notes.write('; $why');
          killed = now;
          loads.removeLast();
          servers.removeLast();
          if (++discarded > maxDiscarded) {
            throw StateError(
              'more than $maxDiscarded runs lost their warm workers',
            );
          }
          continue;
        }
      }
      runs.add(round3(m.value));
      mnemonics = m.mnemonics;
      extras.add(m.extra);
      say?.call(
        '  run ${runs.length}/${c.runs}: ${m.value.toStringAsFixed(3)} ${flow.unit}'
        ' (load $load, ${servers.last} other Bazel servers)',
      );
    }
    if (flow.warm && ob != null) {
      workers = {
        'killed_unknown': [killedBefore, killed],
        'runs_discarded': discarded,
        'workers_at_first_run': workersBefore,
        'workers_lost': workersLost,
      };
    }
  } on NotAvailable catch (e) {
    status = 'not_available';
    notes.write('; NOT AVAILABLE HERE: ${e.reason}');
  } on Exceeded catch (e) {
    status = 'exceeded';
    notes.write('; EXCEEDED after ${runs.length} runs: $e');
    say?.call('  EXCEEDED: $e');
  } on Object catch (e) {
    status = 'failed';
    notes.write('; FAILED after ${runs.length} runs: $e');
    say?.call('  FAILED: $e');
  } finally {
    try {
      await flow.tearDown(c);
    } on Object catch (e) {
      notes.write('; tear-down failed: $e');
    }
  }
  if (status == 'ok' && runs.length < c.runs) status = 'failed';
  final noisy = loads.any((l) => l > c.noisyLoad);
  if (loads.isNotEmpty) {
    final lo = loads.reduce((a, b) => a < b ? a : b);
    final hi = loads.reduce((a, b) => a > b ? a : b);
    notes.write('; load1 $lo-$hi');
    if (noisy) notes.write(' (noisy: above ${c.noisyLoad})');
  }
  return Row(
    date: nowIso(),
    tool: flow.tool,
    sdk: c.sdk,
    corpus: flow.corpus,
    flow: flow.flow,
    state: flow.state,
    id: flow.id,
    unit: flow.unit,
    runs: runs,
    notes: notes.toString(),
    load1: loads,
    bazelServers: servers,
    noisy: noisy,
    status: status,
    mnemonics: mnemonics,
    workers: workers,
    extra: _mergeExtras(extras),
    commit: flow.tool == 'stock' ? null : c.commit,
  );
}

/// Per-run figures as lists, single values as they are.
Map<String, Object?> _mergeExtras(List<Map<String, Object?>> extras) {
  final keys = {for (final e in extras) ...e.keys};
  return {
    for (final k in keys) k: [for (final e in extras) e[k]],
  };
}
