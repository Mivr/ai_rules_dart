/// Ledger rows: one JSON object per measured (tool, corpus, flow, state).
library;

import 'dart:convert';
import 'dart:io';

import 'proc.dart';

/// One row of `perf.jsonl`. The fields are described in the ledger's
/// README; [extra] holds the flow's own figures.
final class Row {
  /// A row; [runs] empty means the flow did not produce a number.
  Row({
    required this.date,
    required this.tool,
    required this.sdk,
    required this.corpus,
    required this.flow,
    required this.state,
    required this.id,
    required this.unit,
    required this.runs,
    required this.notes,
    this.load1 = const [],
    this.bazelServers = const [],
    this.noisy = false,
    this.status = 'ok',
    this.mnemonics = const {},
    this.workers,
    this.extra = const {},
    this.commit,
  });

  /// Reads a row written by [toJson]; rows of other writers keep what
  /// they have.
  factory Row.fromJson(Map<String, Object?> j) => Row(
    date: j['date'] as String? ?? '',
    tool: j['tool'] as String? ?? '',
    sdk: j['sdk'] as String? ?? '',
    corpus: j['corpus'] as String? ?? '',
    flow: j['flow'] as String? ?? '',
    state: j['state'] as String? ?? '',
    id:
        j['id'] as String? ??
        '${j['tool']}/${j['corpus']}/${j['flow']}/${j['state']}',
    unit: j['unit'] as String? ?? 's',
    runs: [
      for (final r in (j['runs'] as List? ?? const [])) (r as num).toDouble(),
    ],
    notes: j['notes'] as String? ?? '',
    load1: [
      for (final r in (j['load1'] as List? ?? const [])) (r as num).toDouble(),
    ],
    bazelServers: [
      for (final r in (j['bazel_servers'] as List? ?? const [])) r as int,
    ],
    noisy: j['noisy'] as bool? ?? false,
    status: j['status'] as String? ?? (j['wall_s'] == null ? 'failed' : 'ok'),
    mnemonics: {
      for (final e in ((j['mnemonics'] as Map?) ?? const {}).entries)
        e.key as String: e.value as int,
    },
    workers: (j['workers'] as Map?)?.cast<String, Object?>(),
    extra: ((j['extra'] as Map?) ?? const {}).cast<String, Object?>(),
    commit: j['commit'] as String?,
  );

  /// ISO-8601 local time the row was written.
  final String date;

  /// `stock`, `rules_dart` or `rules_flutter`.
  final String tool;

  /// The SDK the flow ran with.
  final String sdk;

  /// The workspace or corpus project.
  final String corpus;

  /// The flow name.
  final String flow;

  /// The state before the timed command.
  final String state;

  /// The harness's flow id (`<group>.<case>.<side>`).
  final String id;

  /// What [runs] count: `s` (seconds) or `actions` (a count).
  final String unit;

  /// Every run's figure, in order.
  final List<double> runs;

  /// The exact command, the state set-up, and anything else a reader needs.
  final String notes;

  /// The 1-minute load average before each run.
  final List<double> load1;

  /// Other Bazel servers running before each run.
  final List<int> bazelServers;

  /// Whether a run was taken above the load threshold. A noisy row is never
  /// a baseline.
  final bool noisy;

  /// `ok`, `failed` or `not_available` (with the reason in [notes]).
  final String status;

  /// Actions that ran, by mnemonic, in the last run (from the execution
  /// log), or the actions registered, by mnemonic, for a count flow.
  final Map<String, int> mnemonics;

  /// Persistent-worker evidence for a warm flow: killed-worker lines in the
  /// server log before the first and after the last run, workers kept.
  final Map<String, Object?>? workers;

  /// The flow's own figures (analysis phase seconds, peak memory, ...).
  final Map<String, Object?> extra;

  /// The repository commit measured, for the rules.
  final String? commit;

  /// The median of [runs], or null.
  double? get median {
    if (runs.isEmpty) return null;
    final s = [...runs]..sort();
    final m = s.length ~/ 2;
    final v = s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
    return (v * 1000).roundToDouble() / 1000;
  }

  /// The row as one ledger line.
  Map<String, Object?> toJson() {
    final s = [...runs]..sort();
    return {
      'date': date,
      'tool': tool,
      'sdk': sdk,
      'corpus': corpus,
      'flow': flow,
      'state': state,
      'id': id,
      'unit': unit,
      'wall_s': unit == 's' ? median : null,
      if (unit != 's') 'value': median,
      'runs': runs,
      'range': s.isEmpty ? null : [s.first, s.last],
      'load1': load1,
      'bazel_servers': bazelServers,
      'noisy': noisy,
      'status': status,
      if (mnemonics.isNotEmpty) 'mnemonics': mnemonics,
      if (workers != null) 'workers': workers,
      if (extra.isNotEmpty) 'extra': extra,
      if (commit != null) 'commit': commit,
      'harness': 'rules_dart/tools/perf',
      'notes': notes,
    };
  }
}

/// Reads rows from a JSON-lines file; lines that are not objects are skipped.
List<Row> readRows(String path) => [
  for (final line in File(path).readAsLinesSync())
    if (line.trim().startsWith('{'))
      Row.fromJson(jsonDecode(line) as Map<String, Object?>),
];

/// Appends [rows] to [path] (creating it).
void appendRows(String path, List<Row> rows) {
  File(path).writeAsStringSync(
    rows.map((r) => '${jsonEncode(r.toJson())}\n').join(),
    mode: FileMode.append,
    flush: true,
  );
}

/// Appends [rows] to the shared ledger at [ledger] while holding [lockFile]
/// with `flock`, the lock every writer of the ledger takes.
Future<void> appendToLedger(
  String ledger,
  String lockFile,
  List<Row> rows,
  String scratch,
) async {
  final tmp = File('$scratch/ledger-append-$pid.jsonl');
  tmp.writeAsStringSync(rows.map((r) => '${jsonEncode(r.toJson())}\n').join());
  await must(
    Cmd([
      'flock',
      lockFile,
      'sh',
      '-c',
      r'cat "$0" >> "$1"',
      tmp.path,
      ledger,
    ], cwd: scratch),
  );
  tmp.deleteSync();
}

/// The local time now as ISO-8601 with its offset.
String nowIso() {
  final t = DateTime.now();
  final off = t.timeZoneOffset;
  String two(int n) => n.toString().padLeft(2, '0');
  final sign = off.isNegative ? '-' : '+';
  return '${t.year}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}:${two(t.second)}'
      '$sign${two(off.inHours.abs())}:${two(off.inMinutes.abs() % 60)}';
}
