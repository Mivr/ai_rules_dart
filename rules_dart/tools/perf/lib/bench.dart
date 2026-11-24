/// The bench harness: measures the flows of the plan's target table for the
/// rules and for the stock tools, writes ledger rows, checks a run against
/// baseline rows, and writes the table.
///
/// ```
/// cd rules_dart/tools
/// bazel run //perf:bench -- list
/// bazel run //perf:bench -- run --flows=dart.body.small.rules --scratch=/tmp/bench
/// bazel run //perf:bench -- run --flows=all --scratch=... --out=rows.jsonl
/// bazel run //perf:bench -- check --flows=tag:cheap --baseline=rows.jsonl --scratch=...
/// bazel run //perf:bench -- agree --a=pass1.jsonl --b=pass2.jsonl
/// bazel run //perf:bench -- table --rows=rows.jsonl --out=table.md
/// bazel run //perf:bench -- generate --libraries=2000 --shape=deep --out=DIR [--twin=DIR]
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'src/check.dart';
import 'src/flow.dart';
import 'src/flows/catalogue.dart';
import 'src/flows/device.dart';
import 'src/generate.dart';
import 'src/ledger.dart';
import 'src/proc.dart';
import 'src/stats.dart';
import 'src/table.dart';

export 'src/check.dart';
export 'src/flow.dart';
export 'src/ledger.dart';
export 'src/stats.dart';

const _usage = '''
usage: bench <command> [options]

commands:
  list      the flows, with their tags
  run       measure flows and write rows
  check     measure flows and compare them with baseline rows (exit 1 on a regression)
  agree     compare two passes of the same flows, --a=FILE --b=FILE or
            --rows=FILE (exit 1 when one disagrees)
  table     write the plan's table from rows
  generate  write a generated graph workspace (and its stock twin)

flow selection (--flows=): comma-separated flow ids, id prefixes ending in
".", "tag:<tag>", or "all"; an item starting with "-" removes what it
matches ("analysis.,-tag:stock").

run and check options:
  --scratch=DIR          workspaces, copies and logs (required)
  --repo=DIR             the repository with rules_dart/ and rules_flutter/
                         (default: two levels above the tools workspace)
  --bazel=CMD            the Bazel command, words split on spaces (default: bazel)
  --stock-env=FILE       a shell file whose exports make the stock tools'
                         environment (default: this process's environment)
  --runs=N               runs per flow, at least 5 for a baseline (default 5)
  --command-limit=MIN    the longest one command (set-up or timed) may run;
                         a flow that exceeds it is recorded as exceeded
                         (default 45)
  --passes=N             measure each flow N times back to back (default 1);
                         `agree --rows=FILE` compares the first two
  --noisy-load=X         1-minute load above which a run is noisy (default:
                         a quarter of the processors)
  --android-bazelrc=FILE an rc file Android workspaces import
  --bazelrc-line=LINE    a line for every scratch workspace's .bazelrc.user
                         (a pub mirror); repeatable
  --option=KEY=VALUE     a setting of single flows: pub_lock, avd,
                         emulator_port, adb_port, system_image, corpus
  --keep-servers         leave the Bazel servers of the scratch workspaces
                         running (they are shut down at the end otherwise)
  --out=FILE             append the rows here
  --ledger=FILE          also append the rows to this ledger, holding
  --ledger-lock=FILE     this lock with flock
check options:
  --baseline=FILE        rows to compare with
  --margin=X             allowed slowdown as a fraction (default 0.25)
  --floor=S              and in seconds (default 0.05)
''';

/// Runs the harness with [args]; returns the exit code.
Future<int> bench(List<String> args) async {
  if (args.isEmpty || args.first == '-h' || args.first == '--help') {
    stdout.write(_usage);
    return args.isEmpty ? 2 : 0;
  }
  final opts = _Opts(args.skip(1).toList());
  try {
    switch (args.first) {
      case 'list':
        for (final f in catalogue()) {
          stdout.writeln('${f.id.padRight(40)} ${f.tags.join(',')}');
        }
        return 0;
      case 'run':
        final rows = await _measure(opts);
        return rows.every((r) => r.status != 'failed') ? 0 : 1;
      case 'check':
        return await _check(opts);
      case 'agree':
        return _agree(opts);
      case 'table':
        final rows = [
          for (final p in opts.required('rows').split(',')) ...readRows(p),
        ];
        final md = planTable(rows);
        final out = opts['out'];
        if (out == null) {
          stdout.write(md);
        } else {
          File(out).writeAsStringSync(md);
        }
        return 0;
      case 'generate':
        return _generate(opts);
      default:
        stderr.write(_usage);
        return 2;
    }
  } on UsageError catch (e) {
    stderr.writeln('bench: ${e.message}');
    return 2;
  }
}

/// A missing or bad option.
final class UsageError implements Exception {
  /// The problem.
  const UsageError(this.message);

  /// What is wrong.
  final String message;
}

final class _Opts {
  _Opts(List<String> args) {
    for (final a in args) {
      if (!a.startsWith('--')) throw UsageError('unexpected argument $a');
      final eq = a.indexOf('=');
      final k = eq < 0 ? a.substring(2) : a.substring(2, eq);
      final v = eq < 0 ? 'true' : a.substring(eq + 1);
      (_m[k] ??= []).add(v);
    }
  }

  final _m = <String, List<String>>{};

  String? operator [](String k) => _m[k]?.last;

  List<String> all(String k) => _m[k] ?? const [];

  String required(String k) =>
      this[k] ?? (throw UsageError('--$k is required'));
}

/// The flows [spec] selects from [flows]: comma-separated items, each an
/// id, an id prefix ending in ".", `tag:<tag>` or `all`; an item starting
/// with `-` removes what it matches.
List<Flow> selectFlows(List<Flow> flows, String spec) {
  final out = <Flow>[];
  for (final item
      in spec.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty)) {
    final remove = item.startsWith('-');
    final part = remove ? item.substring(1) : item;
    final hit = switch (part) {
      // A flow tagged on_request runs only when named or selected by tag:
      // the full-parallelism clean build, above the program's job limit.
      'all' => flows.where((f) => !f.tags.contains('on_request')),
      _ when part.startsWith('tag:') => flows.where(
        (f) => f.tags.contains(part.substring(4)),
      ),
      _ when part.endsWith('.') => flows.where((f) => f.id.startsWith(part)),
      _ => flows.where((f) => f.id == part),
    }.toList();
    if (hit.isEmpty)
      throw UsageError('no flow matches "$part" (see `bench list`)');
    if (remove) {
      out.removeWhere(hit.contains);
      continue;
    }
    for (final f in hit) {
      if (!out.contains(f)) out.add(f);
    }
  }
  return out;
}

/// `flutter-<version>+dart-<version>` of the stock tools, or `dart-<version>`
/// without Flutter, or `unknown`.
Future<String> _sdk(Map<String, String> env) async {
  try {
    final f = await runCmd(
      Cmd(['flutter', '--version', '--machine'], cwd: '/', env: env),
    );
    if (f.ok) {
      final j = jsonDecode(f.stdout.substring(f.stdout.indexOf('{')));
      return 'flutter-${j['frameworkVersion']}+dart-${(j['dartSdkVersion'] as String).split(' ').first}';
    }
  } on Object {
    // No Flutter on PATH.
  }
  try {
    final d = await runCmd(Cmd(['dart', '--version'], cwd: '/', env: env));
    final m = RegExp(r'version: (\S+)').firstMatch(d.stdout + d.stderr);
    if (m != null) return 'dart-${m.group(1)}';
  } on Object {
    // No Dart on PATH.
  }
  return 'unknown';
}

Future<Ctx> _ctx(_Opts o) async {
  final stockEnv = await _stockEnv(o['stock-env']);
  final scratch = o.required('scratch');
  Directory(scratch).createSync(recursive: true);
  final ws = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  final repo =
      o['repo'] ??
      (ws == null ? null : Directory('$ws/../..').resolveSymbolicLinksSync());
  if (repo == null)
    throw const UsageError('--repo is required outside `bazel run`');
  final runs = int.tryParse(o['runs'] ?? '5');
  if (runs == null || runs < 1)
    throw const UsageError('--runs must be at least 1');
  final limit = int.tryParse(o['command-limit'] ?? '45');
  if (limit == null || limit < 1)
    throw const UsageError('--command-limit must be at least 1 minute');
  commandLimit = Duration(minutes: limit);
  final options = <String, String>{};
  for (final kv in o.all('option')) {
    final eq = kv.indexOf('=');
    if (eq < 1) throw UsageError('--option=$kv is not KEY=VALUE');
    options[kv.substring(0, eq)] = kv.substring(eq + 1);
  }
  final commit = await runCmd(
    Cmd(['git', 'rev-parse', '--short=12', 'HEAD'], cwd: repo),
  );
  return Ctx(
    repo: repo,
    scratch: Directory(scratch).absolute.path,
    bazel: (o['bazel'] ?? 'bazel')
        .split(' ')
        .where((s) => s.isNotEmpty)
        .toList(),
    stockEnv: stockEnv,
    sdk: await _sdk(stockEnv),
    runs: runs,
    noisyLoad:
        double.tryParse(o['noisy-load'] ?? '') ??
        Platform.numberOfProcessors / 4,
    bazelrcLines: o.all('bazelrc-line'),
    androidBazelrc: o['android-bazelrc'],
    options: options,
    commit: commit.ok ? commit.stdout.trim() : null,
  );
}

/// The variables that sourcing [file] in a shell sets or changes, on top of
/// this process's environment; none without a file. Only these are passed
/// and logged, so a log never holds the inherited environment.
Future<Map<String, String>> _stockEnv(String? file) async {
  if (file == null) return const {};
  final d = await must(
    Cmd(['bash', '-c', r'. "$0" >/dev/null && env -0', file], cwd: '/'),
  );
  return {
      for (final kv in d.stdout.split('\u0000'))
        if (kv.contains('=') &&
            Platform.environment[kv.substring(0, kv.indexOf('='))] !=
                kv.substring(kv.indexOf('=') + 1))
          kv.substring(0, kv.indexOf('=')): kv.substring(kv.indexOf('=') + 1),
    }
    ..remove('_')
    ..remove('SHLVL')
    ..remove('PWD')
    ..remove('OLDPWD');
}

Future<List<Row>> _measure(_Opts o) async {
  final c = await _ctx(o);
  final flows = selectFlows(catalogue(), o.required('flows'));
  final passes = int.tryParse(o['passes'] ?? '1') ?? 1;
  final rows = <Row>[];
  try {
    for (final f in [
      for (final f in flows)
        for (var p = 0; p < passes; p++) f,
    ]) {
      stdout.writeln('${f.id}: ${f.describe(c)}');
      final row = await measureFlow(f, c, say: stdout.writeln);
      rows.add(row);
      stdout.writeln(
        '${f.id}: ${row.status}${row.median == null ? '' : ', median ${row.median} ${row.unit}, '
                  'range ${row.runs.reduce((a, b) => a < b ? a : b)}-${row.runs.reduce((a, b) => a > b ? a : b)}'}'
        '${row.noisy ? ' (noisy)' : ''}',
      );
      final out = o['out'];
      if (out != null) appendRows(out, [row]);
      final ledger = o['ledger'];
      if (ledger != null) {
        await appendToLedger(ledger, o.required('ledger-lock'), [
          row,
        ], c.scratch);
      }
    }
  } finally {
    await stopEmulator(c);
    if (o['keep-servers'] == null) {
      for (final ws in c.workspaces) {
        await runCmd(Cmd([...c.bazel, 'shutdown'], cwd: ws, env: c.stockEnv));
      }
    }
  }
  return rows;
}

Future<int> _check(_Opts o) async {
  final baseline = readRows(o.required('baseline'));
  final rows = await _measure(o);
  final verdicts = compareRows(
    rows,
    baseline,
    margin: double.parse(o['margin'] ?? '0.25'),
    floor: double.parse(o['floor'] ?? '0.05'),
  );
  for (final v in verdicts) {
    stdout.writeln('${v.pass ? 'PASS' : 'FAIL'} ${v.id}: ${v.summary}');
    for (final f in v.failures) {
      stdout.writeln('     $f');
    }
  }
  return verdicts.every((v) => v.pass) ? 0 : 1;
}

int _agree(_Opts o) {
  final Map<String, Row> a;
  final Map<String, Row> b;
  final both = o['rows'];
  if (both != null) {
    // One file with two passes of each flow: the first row of an id
    // against the second.
    a = {};
    b = {};
    for (final r in readRows(both)) {
      if (!a.containsKey(r.id)) {
        a[r.id] = r;
      } else {
        b.putIfAbsent(r.id, () => r);
      }
    }
  } else {
    a = {for (final r in readRows(o.required('a'))) r.id: r};
    b = {for (final r in readRows(o.required('b'))) r.id: r};
  }
  var ok = true;
  for (final id in a.keys) {
    final x = a[id]!;
    final y = b[id];
    if (y == null || x.runs.isEmpty || y.runs.isEmpty) {
      stdout.writeln('SKIP $id: not in both runs with numbers');
      continue;
    }
    final sx = Summary(x.runs);
    final sy = Summary(y.runs);
    final good = agree(sx, sy);
    ok &= good;
    stdout.writeln(
      '${good ? 'AGREE' : 'DIFFER'} $id: ${sx.median} (${sx.min}-${sx.max}) and '
      '${sy.median} (${sy.min}-${sy.max})${x.noisy || y.noisy ? ' (noisy)' : ''}',
    );
  }
  return ok ? 0 : 1;
}

int _generate(_Opts o) {
  final n = int.parse(o['libraries'] ?? '2000');
  final shape = Shape.values.byName(o['shape'] ?? 'deep');
  final lines = int.tryParse(o['lines'] ?? '');
  final s = GraphSpec(
    libraries: n,
    shape: shape,
    flutter: o['flutter'] == 'true',
    packageTest: o['package-test'] == 'true',
    methods: lines == null ? 0 : GraphSpec.methodsFor(lines, n),
  );
  final ws = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  final repo =
      o['repo'] ??
      (ws == null ? null : Directory('$ws/../..').resolveSymbolicLinksSync());
  if (repo == null)
    throw const UsageError('--repo is required outside `bazel run`');
  final hub = s.flutter || s.packageTest;
  writeBazelGraph(
    s,
    o.required('out'),
    repo,
    lock: !hub
        ? null
        : s.flutter
        ? '$repo/rules_flutter/e2e/linux_example/pubspec.lock'
        : '$repo/rules_dart/tools/e2e_runner/pubspec.lock',
  );
  final twin = o['twin'];
  if (twin != null) writeStockTwin(s, twin);
  stdout.writeln('wrote ${s.name}: ${s.layers} layers x ${s.width} libraries');
  return 0;
}
