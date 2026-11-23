/// The analysis phase on generated graphs, stock `dart analyze` on their
/// twins, and the actions a target registers per source file.
library;

import 'dart:convert';
import 'dart:io';

import '../bazel.dart';
import '../flow.dart';
import '../generate.dart';
import '../proc.dart';
import '../server_heap.dart';
import 'common.dart';

/// The aspect flags of the analyze and format checks.
const aspectFlags = [
  '--aspects=@rules_dart//dart:analyze.bzl%dart_analyze',
  '--output_groups=+dart_analyze,+dart_format',
];

/// Makes (once) the Bazel workspace of [s] under the scratch directory.
Future<String> graphWorkspace(Ctx c, GraphSpec s) async {
  final dir = '${c.scratch}/gen/${s.name}';
  final stamp = File('$dir/.bench-generated');
  if (!stamp.existsSync()) {
    rmrf(dir);
    final hub = s.flutter || s.packageTest;
    writeBazelGraph(
      s,
      dir,
      c.repo,
      lock: !hub
          ? null
          : s.flutter
          ? '${c.repo}/rules_flutter/e2e/linux_example/pubspec.lock'
          : '${c.repo}/rules_dart/tools/e2e_runner/pubspec.lock',
      seedLockfile: !hub
          ? null
          : s.flutter
          ? '${c.repo}/rules_flutter/e2e/linux_example/MODULE.bazel.lock'
          : '${c.repo}/rules_dart/tools/MODULE.bazel.lock',
    );
    stamp.writeAsStringSync(s.name);
  }
  File('$dir/.bazelrc.user')
      .writeAsStringSync('${c.bazelrcLines.join('\n')}\n');
  return dir;
}

/// Makes (once) the stock twin of [s] and runs `pub get --offline` in it.
Future<String> twinWorkspace(Ctx c, GraphSpec s) async {
  final dir = '${c.scratch}/gen/${s.name}-twin';
  final stamp = File('$dir/.bench-generated');
  if (!stamp.existsSync()) {
    rmrf(dir);
    writeStockTwin(
      s,
      dir,
      lock: s.flutter
          ? null
          : s.packageTest
          ? '${c.repo}/rules_dart/tools/e2e_runner/pubspec.lock'
          : null,
    );
    await must(
      c.stock([s.flutter ? 'flutter' : 'dart', 'pub', 'get', '--offline'], dir),
      log: c.log('generate'),
    );
    stamp.writeAsStringSync(s.name);
  }
  return dir;
}

/// The analysis phase of `bazel build --nobuild //...` on a generated graph,
/// with the packages loaded and the analysis cache dropped by a new
/// `--define` value each run.
final class AnalysisFlow extends Flow {
  /// Analysis of [spec], with the analyze and format aspects when [aspects].
  AnalysisFlow(this.spec, {required this.aspects, Set<String>? tags})
    : tags = tags ?? const {'heavy'};

  /// The graph.
  final GraphSpec spec;

  /// Whether the aspects are on.
  final bool aspects;

  @override
  final Set<String> tags;

  @override
  String get id =>
      'analysis.${spec.shape.name}${spec.libraries}.${aspects ? 'aspects' : 'rules'}';

  @override
  String get tool => 'rules_dart';

  @override
  String get corpus => 'gen-${spec.name}';

  @override
  String get flow => aspects ? 'analysis_aspects' : 'analysis';

  @override
  String get state => 'loaded';

  Bazel? _b;
  String? _profile;

  @override
  Bazel? get server => _b;

  List<String> get _args => ['build', '--nobuild', if (aspects) ...aspectFlags];

  @override
  String describe(Ctx c) =>
      'bazel ${_args.join(' ')} --define=bench_salt=<new> //... '
      '(${spec.layers} layers x ${spec.width} libraries, each importing 3 of the layer below); '
      'set-up: the same command once (packages loaded); a new --define value each run drops the analysis cache; '
      'time: the profile phase "Load and analyze dependencies" (Bazel elapsed and server heap in extra)';

  @override
  Future<void> setUp(Ctx c) async {
    final b = _b = c.bazelIn(await graphWorkspace(c, spec), id);
    // Twice: the first loads the packages, the second leaves the server as
    // every later run finds it.
    await b.must([..._args, '--define=bench_salt=setup1', '//...']);
    await b.must([..._args, '--define=bench_salt=setup2', '//...']);
  }

  @override
  Future<Measured> measure(Ctx c, int run) async {
    final profile = _profile = '${c.scratch}/logs/$id.profile.json.gz';
    final d = await _b!.run([
      ..._args,
      '--define=bench_salt=${c.fresh()}',
      '--profile=$profile',
      '//...',
    ]);
    if (!d.ok) throw StateError('run ${run + 1} failed: ${d.tail()}');
    final phases = phaseSeconds(profileEvents(profile));
    final analysis = phases['Load and analyze dependencies'];
    final counts = analyzedCounts(d.stderr);
    final heap = parseServerHeap(
      (await _b!.must(['info', ...serverHeapInfoKeys])).stdout,
    );
    return Measured(
      analysis ?? elapsedSeconds(d.stderr) ?? d.seconds,
      extra: {
        'elapsed_s': elapsedSeconds(d.stderr),
        'targets_configured': counts?.configured,
        'aspect_applications': counts?.aspects,
        'heap_used_after_gc_mb': heap.usedAfterGcBytes >> 20,
      },
    );
  }

  @override
  Future<void> tearDown(Ctx c) async {
    if (_profile != null) rmrf(_profile!);
  }
}

/// Stock `dart analyze` on the twin of a generated graph, with an empty
/// analysis-driver cache (a private `HOME` emptied before each run).
StockFlow stockAnalyze(GraphSpec s) => StockFlow(
  id: 'analysis.${s.shape.name}${s.libraries}.stock',
  corpus: 'gen-${s.name}-twin',
  flow: 'analyze',
  state: 'cold',
  tags: const {'heavy', 'stock'},
  workspace: (c) => twinWorkspace(c, s),
  argv: const ['dart', 'analyze'],
  warmUp: false,
  env: const {'HOME': '{scratch}/stock-home'},
  prepareSteps: const [
    ['rm', '-rf', '{scratch}/stock-home/.dartServer'],
  ],
);

/// Actions registered per source file: `aquery` of a target over 10 and
/// over 20 source files, with the aspects, and the difference over 10.
final class PerSourceFlow extends Flow {
  /// The probe for a library ([test] false) or a test.
  PerSourceFlow({required this.test});

  /// Whether the probe is the test (its whole closure) or the library.
  final bool test;

  @override
  String get id => 'actions_per_source.${test ? 'test' : 'library'}.rules';

  @override
  String get tool => 'rules_dart';

  @override
  String get corpus => 'gen-per-source';

  @override
  String get flow => 'actions_per_source';

  @override
  String get state => test ? 'dart_test' : 'dart_library';

  @override
  String get unit => 'actions';

  @override
  Set<String> get tags => const {'cheap'};

  Bazel? _b;

  @override
  Bazel? get server => _b;

  String _expr(int n) => test ? 'deps(//:t${n}_test)' : '//src$n';

  @override
  String describe(Ctx c) =>
      'bazel aquery --output=jsonproto ${aspectFlags.join(' ')} "${_expr(20)}" minus the same for "${_expr(10)}", '
      'divided by 10 (the extra source files); by mnemonic in "mnemonics"';

  @override
  Future<void> setUp(Ctx c) async {
    final dir = '${c.scratch}/gen/per-source';
    if (!File('$dir/.bench-generated').existsSync()) {
      rmrf(dir);
      writePerSourceProbe(dir, c.repo);
      File('$dir/.bench-generated').writeAsStringSync('per-source');
    }
    File('$dir/.bazelrc.user')
        .writeAsStringSync('${c.bazelrcLines.join('\n')}\n');
    _b = c.bazelIn(dir, id);
  }

  Future<Map<String, int>> _count(String expr) async {
    final d = await _b!.must([
      'aquery',
      '--output=jsonproto',
      ...aspectFlags,
      expr,
    ]);
    final doc = jsonDecode(d.stdout) as Map<String, Object?>;
    final counts = <String, int>{};
    for (final a in (doc['actions'] as List? ?? const [])) {
      final m = (a as Map)['mnemonic'] as String? ?? '?';
      counts[m] = (counts[m] ?? 0) + 1;
    }
    return counts;
  }

  @override
  Future<Measured> measure(Ctx c, int run) async {
    final a10 = await _count(_expr(10));
    final a20 = await _count(_expr(20));
    int sum(Map<String, int> m) => m.values.fold(0, (a, b) => a + b);
    final delta = <String, int>{
      for (final k in {...a10.keys, ...a20.keys})
        if ((a20[k] ?? 0) != (a10[k] ?? 0)) k: (a20[k] ?? 0) - (a10[k] ?? 0),
    };
    return Measured(
      (sum(a20) - sum(a10)) / 10,
      mnemonics: delta,
      extra: {'actions_10': sum(a10), 'actions_20': sum(a20)},
    );
  }
}
