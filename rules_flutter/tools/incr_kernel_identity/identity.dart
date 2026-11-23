/// Real-compiler identity check for the incremental kernel worker.
///
/// The design claim in docs/incremental-kernel.md: with
/// `--@rules_flutter//flutter:incremental_kernel`, a warm persistent
/// worker's `.dill` output is byte-for-byte the one-shot output for the same
/// inputs, after a sequence of edits. This library holds the check: the
/// execution-log proof that every compared build ran under its stated
/// strategy, the warmth proof that one worker and one compiler served the
/// whole worker leg, the source edits, and the orchestration that drives the
/// builds, compares the dills, and restores the tree on every exit path.
///
/// The orchestration runs only on Linux: the warmth proof reads the process
/// tree through `/proc`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A user-facing check failure. Thrown, never swallowed: the entry point
/// reports the message and exits non-zero.
class IdentityFailure implements Exception {
  new(this.message);

  final String message;

  @override
  String toString() => 'identity-check: FAIL: $message';
}

/// One source replacement: [oldText] must occur exactly once in the file.
typedef EditStep = ({String oldText, String newText});

/// Applies [steps] to the file at [path]. Throws [IdentityFailure] when any
/// anchor occurs anything but exactly once, so fixture drift fails closed
/// instead of editing the wrong text.
void applyEdits({
  required String path,
  required List<EditStep> steps,
  required String stepName,
}) {
  String src = File(path).readAsStringSync();
  for (final step in steps) {
    if (src.split(step.oldText).length != 2) {
      throw IdentityFailure(
        '$stepName: anchor occurs '
        '${src.split(step.oldText).length - 1} times, want 1: '
        '${step.oldText.substring(0, step.oldText.length > 60 ? 60 : step.oldText.length)}',
      );
    }
    src = src.replaceFirst(step.oldText, step.newText);
  }
  File(path).writeAsStringSync(src);
}

/// Splits concatenated pretty-printed JSON values (the execution log format:
/// one top-level object after another) into their raw texts. Objects nested
/// inside strings never start or end a value.
List<String> splitTopLevelJsonValues(String text) {
  final out = <String>[];
  var depth = 0;
  var inString = false;
  var escape = false;
  var start = -1;
  for (var i = 0; i < text.length; i++) {
    final String c = text[i];
    if (inString) {
      if (escape) {
        escape = false;
      } else if (c == r'\') {
        escape = true;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == '{') {
      if (depth == 0) start = i;
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0 && start >= 0) {
        out.add(text.substring(start, i + 1));
        start = -1;
      }
    }
  }
  return out;
}

/// Whether the execution log proves [step] ran under its stated strategy.
typedef StrategyVerdict = ({bool ok, String detail, int actions});

/// Checks the `--execution_log_json_file` text of one build: it must hold at
/// least one `FlutterKernelCompile` entry, every one with runner
/// [wantRunner] and `cacheHit: false`. Anything else — a cache hit, a
/// fallback to another runner, no entry at all, an unparsable log — is a
/// failed verdict, never a pass.
StrategyVerdict checkStrategy({
  required String logText,
  required String wantRunner,
  required String step,
}) {
  final found = <Map<String, dynamic>>[];
  for (final String raw in splitTopLevelJsonValues(logText)) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return (
        ok: false,
        detail: '$step: execution log is not JSON',
        actions: 0,
      );
    }
    if (decoded is Map<String, dynamic> &&
        decoded['mnemonic'] == 'FlutterKernelCompile') {
      found.add(decoded);
    }
  }
  if (found.isEmpty) {
    return (
      ok: false,
      detail:
          '$step executed no FlutterKernelCompile action '
          '(cache hit or misconfiguration)',
      actions: 0,
    );
  }
  final List<String> bad = [
    for (final entry in found)
      if (entry['runner'] != wantRunner || entry['cacheHit'] != false)
        'runner=${entry['runner']} cacheHit=${entry['cacheHit']}',
  ];
  if (bad.isNotEmpty) {
    return (
      ok: false,
      detail:
          '$step ran ${bad.length} FlutterKernelCompile action(s) '
          'outside its strategy (want runner=$wantRunner, no cache hit): $bad',
      actions: found.length,
    );
  }
  return (
    ok: true,
    detail:
        '$step executed ${found.length} FlutterKernelCompile action(s) '
        'as runner=$wantRunner, no cache hit',
    actions: found.length,
  );
}

final _createdWorkerPattern = RegExp(r'Created .*FlutterKernelCompile worker');

/// How many `FlutterKernelCompile` workers Bazel's `--worker_verbose` output
/// says it created.
int countCreatedWorkers(String verboseLog) =>
    _createdWorkerPattern.allMatches(verboseLog).length;

final _destroyedWorkerPattern = RegExp(
  r'destroying.*flutterkernelcompile|killing.*flutterkernelcompile',
  caseSensitive: false,
);

/// The first `--worker_verbose` line saying a `FlutterKernelCompile` worker
/// was destroyed or killed, or null when the logs hold none.
String? findDestroyedWorker(Iterable<String> verboseLogs) {
  for (final log in verboseLogs) {
    for (final String line in log.split('\n')) {
      if (_destroyedWorkerPattern.hasMatch(line)) return line.trim();
    }
  }
  return null;
}

/// The persistent worker and its compiler child, by PID.
typedef WorkerPids = ({int worker, int compiler});

/// Whether [candidate] holds the same two processes as [baseline].
bool samePids(WorkerPids candidate, WorkerPids baseline) =>
    candidate.worker == baseline.worker &&
    candidate.compiler == baseline.compiler;

/// The NUL-separated command line of [pid] under [procRoot], blanks joined.
String cmdlineOf({required String procRoot, required int pid}) {
  final Uint8List bytes = File('$procRoot/$pid/cmdline').readAsBytesSync();
  return utf8
      .decode(bytes, allowMalformed: true)
      .replaceAll('\x00', ' ')
      .trim();
}

/// The parent PID from `/proc/<pid>/stat`, or null when unparsable. The
/// command name sits in parentheses and may itself hold spaces and
/// parentheses, so the fields are read after the last `)`: state, then ppid.
int? readPpid({required String procRoot, required int pid}) {
  final String stat = File('$procRoot/$pid/stat').readAsStringSync();
  final int close = stat.lastIndexOf(')');
  if (close < 0) return null;
  final List<String> rest = stat
      .substring(close + 1)
      .trim()
      .split(RegExp(r'\s+'));
  if (rest.length < 2) return null;
  return int.tryParse(rest[1]);
}

/// Finds the worker leg's persistent worker and its compiler child through
/// the process tree under [procRoot] (`/proc` in production, a fake tree in
/// tests). The worker is the one process whose command line names both
/// `incr_fkc_worker --persistent_worker` and [outputBase], so a worker from
/// another build on the same host can never match; the compiler is its only
/// child whose command line names `frontend_server`. Returns null whenever
/// the evidence is anything but exactly one of each — a dead worker, a
/// second worker, or a restarted compiler all read as absent, and the caller
/// fails closed.
WorkerPids? findWorkerPids({
  required String outputBase,
  String procRoot = '/proc',
}) {
  final workers = <int>[];
  for (final FileSystemEntity entry in Directory(procRoot).listSync()) {
    final int? pid = int.tryParse(entry.path.split('/').last);
    if (pid == null) continue;
    String cmdline;
    try {
      cmdline = cmdlineOf(procRoot: procRoot, pid: pid);
    } on FileSystemException {
      // The process exited mid-scan; it cannot be the live worker.
      continue;
    }
    if (cmdline.contains('incr_fkc_worker') &&
        cmdline.contains('--persistent_worker') &&
        cmdline.contains(outputBase)) {
      workers.add(pid);
    }
  }
  if (workers.length != 1) return null;
  final compilers = <int>[];
  for (final FileSystemEntity entry in Directory(procRoot).listSync()) {
    final int? pid = int.tryParse(entry.path.split('/').last);
    if (pid == null) continue;
    int? ppid;
    String cmdline;
    try {
      ppid = readPpid(procRoot: procRoot, pid: pid);
      cmdline = cmdlineOf(procRoot: procRoot, pid: pid);
    } on FileSystemException {
      // The process exited mid-scan; it cannot be the live compiler.
      continue;
    }
    if (ppid == workers.single && cmdline.contains('frontend_server')) {
      compilers.add(pid);
    }
  }
  if (compilers.length != 1) return null;
  return (worker: workers.single, compiler: compilers.single);
}

/// Whether two byte lists hold the same bytes.
bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The sha256 hex digest of the file at [path], via `sha256sum`.
Future<String> sha256OfFile(String path) async {
  final ProcessResult result = await Process.run('sha256sum', [path]);
  if (result.exitCode != 0) {
    throw IdentityFailure('sha256sum $path failed: ${result.stderr}');
  }
  return (result.stdout as String).split(' ').first;
}

/// One build's resolved invocation. Groups what travels together so helpers
/// take a single spec instead of a long parameter list.
typedef BuildSpec = ({
  String step,
  String outputBase,
  String linkPrefix,
  List<String> strategyFlags,
  bool workerVerbose,
  String wantRunner,
  String disk,
  String logName,
});

/// Copies the two fixture sources into [dir] as `main.dart.bak` and
/// `common_widgets.bak`.
void backupSources({
  required String mainPath,
  required String commonPath,
  required String dir,
}) {
  File(mainPath).copySync('$dir/main.dart.bak');
  File(commonPath).copySync('$dir/common_widgets.bak');
}

/// Restores the two fixture sources from [dir]'s backups. A missing backup
/// restores nothing, so cleanup before any backup still succeeds.
void restoreSources({
  required String mainPath,
  required String commonPath,
  required String dir,
}) {
  _restoreOne(mainPath, '$dir/main.dart.bak');
  _restoreOne(commonPath, '$dir/common_widgets.bak');
}

void _restoreOne(String path, String backup) {
  if (File(backup).existsSync()) File(backup).copySync(path);
}

/// First edit: both app libraries; `common_widgets.dart` gains an import and
/// uses it.
final List<EditStep> s1CommonSteps = [
  (
    oldText: "import 'package:flutter/material.dart';",
    newText:
        "import 'package:flutter/foundation.dart';\n"
        "import 'package:flutter/material.dart';",
  ),
  (
    oldText: 'const AppTitle({required this.text, super.key});',
    newText: 'const AppTitle({required this.text, this.tooltip, super.key});',
  ),
  (
    oldText: "  /// The string this widget renders.\n  final String text;",
    newText:
        "  /// The string this widget renders.\n  final String text;\n"
        '\n  /// An optional tooltip shown on long press.\n  final String? tooltip;',
  ),
  (
    oldText:
        '    return Text(\n'
        '      text,\n'
        '      style: Theme.of(context).textTheme.headlineMedium,\n'
        '    );',
    newText:
        "    final label = tooltip ?? (kDebugMode ? 'debug' : 'release');\n"
        '    return Tooltip(\n'
        '      message: label,\n'
        '      child: Text(\n'
        '        text,\n'
        '        style: Theme.of(context).textTheme.headlineMedium,\n'
        '      ),\n'
        '    );',
  ),
];

/// First edit, `main.dart` half: use the new parameter.
final List<EditStep> s1MainSteps = [
  (
    oldText: "AppTitle(text: '\$_counter'),",
    newText: "AppTitle(text: '\$_counter', tooltip: 'counter'),",
  ),
];

/// Second edit: both app libraries again (a label and a text style).
final List<EditStep> s2MainSteps = [
  (
    oldText:
        "Text('count: \$_counter', key: const ValueKey('agent_test_label')),",
    newText:
        "Text('total: \$_counter', key: const ValueKey('agent_test_label')),",
  ),
];

/// Second edit, `common_widgets.dart` half.
final List<EditStep> s2CommonSteps = [
  (
    oldText: 'style: Theme.of(context).textTheme.headlineMedium,',
    newText: 'style: Theme.of(context).textTheme.headlineLarge,',
  ),
];

/// The Bazel binary driving the inner builds: [override] (`$BAZEL`) when set,
/// else `bazel` on PATH. Under `bazel run` the PATH `bazel` is Bazel's own
/// binary, so a caller whose Bazel is a wrapper sets `BAZEL` to that wrapper
/// (on the KVM host that is `BAZEL=/usr/local/bin/bazel`).
String resolveBazel({String? override}) =>
    (override != null && override.isNotEmpty) ? override : 'bazel';

/// Resolves the built `hello_world.dill` under [linkPrefix] in [workDir] to its
/// real path under the output base. The `bazel-bin` entry may be a symlink or
/// a regular file (Bazel hardlinks some outputs), so existence is checked
/// without following the final component; a missing entry throws
/// [IdentityFailure]. (`Link.existsSync` alone would miss a regular file.)
String locateDill({required String workDir, required String linkPrefix}) {
  final path = '$workDir/${linkPrefix}bin/hello_world.dill';
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    throw IdentityFailure('no $path (build produced no dill?)');
  }
  return File(path).resolveSymbolicLinksSync();
}

/// One run of the identity check: two fresh output bases, the edit sequence,
/// the comparisons, and the cleanup. Create with [IdentityRun.new], drive
/// with [run]; [run] restores the edited sources, shuts down both Bazel
/// servers and deletes the scratch directory on every exit path.
class IdentityRun {
  new({required this.bazel, required this.repoRoot})
    : work = Directory.systemTemp.createTempSync('incr_identity_'),
      _cleaned = false;

  /// The Bazel binary driving the inner builds (see [resolveBazel]).
  final String bazel;

  /// The checkout root (from `BUILD_WORKSPACE_DIRECTORY`).
  final String repoRoot;

  /// Scratch holding the output bases, disk caches, logs and backups.
  final Directory work;

  bool _cleaned;
  WorkerPids? _warm;
  final List<String> _workerLogs = [];
  StreamSubscription<ProcessSignal>? _sigint;
  StreamSubscription<ProcessSignal>? _sigterm;

  String get _ws => '$repoRoot/e2e/hello_world';
  String get _target => '//:hello_world';
  String get _flag => '--@rules_flutter//flutter:incremental_kernel';
  String get _wbase => '${work.path}/wbase';
  String get _obase => '${work.path}/obase';
  String get _main => '$_ws/lib/main.dart';
  String get _common => '$_ws/lib/common_widgets.dart';

  /// Drives the whole check: worker leg, one-shot leg, comparisons, warmth
  /// proof. Returns the process exit code (0 when every comparison holds).
  Future<int> run() async {
    try {
      _watchSignals();
      // The class delegates to the tested backupSources/restoreSources pair
      // so the backup filenames cannot drift between backup and restore.
      backupSources(mainPath: _main, commonPath: _common, dir: work.path);
      await _workerS0();
      await _oneshotS0();
      await _workerS1();
      await _oneshotS1();
      await _workerS2();
      await _oneshotS2();
      await _workerS3();
      _verifyWarmthTotals();
    } finally {
      await _cleanup();
    }
    return 0;
  }

  /// Runs one build, proves it executed under its stated strategy from its
  /// execution log, and returns Bazel's verbose output.
  Future<String> _runBuild(BuildSpec spec) async {
    final stopwatch = Stopwatch()..start();
    final execlog = '${work.path}/${spec.logName}.json';
    final ProcessResult result = await Process.run(bazel, [
      '--output_base=${spec.outputBase}',
      'build',
      _target,
      '-c',
      'dbg',
      _flag,
      ...spec.strategyFlags,
      '--disk_cache=${spec.disk}',
      '--noremote_accept_cached',
      '--noremote_upload_local_results',
      '--execution_log_json_file=$execlog',
      '--execution_log_sort=false',
      '--symlink_prefix=${work.path}/${spec.linkPrefix}',
      if (spec.workerVerbose) '--worker_verbose',
    ], workingDirectory: _ws);
    stopwatch.stop();
    final verbose = '${result.stdout}${result.stderr}';
    File('${work.path}/${spec.logName}.log').writeAsStringSync(verbose);
    print(
      'identity-check: build ${spec.step}: '
      'rc=${result.exitCode} (${stopwatch.elapsed.inSeconds}s)',
    );
    if (result.exitCode != 0) {
      // The scratch log is deleted on cleanup, so the failure cause travels
      // in the output like the old shell check's `tail -n 30`.
      final List<String> lines = verbose.split('\n');
      final String tail = lines
          .skip(lines.length > 30 ? lines.length - 30 : 0)
          .join('\n');
      stderr.writeln('identity-check: build ${spec.step} log tail:\n$tail');
      throw IdentityFailure(
        'build ${spec.step} failed (rc=${result.exitCode})',
      );
    }
    final StrategyVerdict verdict = checkStrategy(
      logText: File(execlog).readAsStringSync(),
      wantRunner: spec.wantRunner,
      step: spec.step,
    );
    print('identity-check: ${verdict.detail}');
    if (!verdict.ok) throw IdentityFailure(verdict.detail);
    return verbose;
  }

  /// The `hello_world.dill` built under [linkPrefix], resolved to its real
  /// path under the output base.
  String _locateDill({required String linkPrefix}) =>
      locateDill(workDir: work.path, linkPrefix: linkPrefix);

  void _saveDill({required String built, required String name}) {
    File(built).copySync('${work.path}/$name');
  }

  /// Records the warm worker on the first call; afterwards requires the same
  /// two PIDs, so a second worker or a restarted compiler fails.
  void _checkWarm({required String step}) {
    final WorkerPids? pids = findWorkerPids(outputBase: _wbase);
    if (pids == null) {
      throw IdentityFailure('$step: no single warm worker with one compiler');
    }
    print(
      'identity-check: $step warm worker pid=${pids.worker} '
      'compiler pid=${pids.compiler}',
    );
    final WorkerPids? warm = _warm;
    if (warm == null) {
      _warm = pids;
    } else if (!samePids(pids, warm)) {
      throw IdentityFailure(
        '$step left the warm path '
        '(worker ${warm.worker}->${pids.worker}, '
        'compiler ${warm.compiler}->${pids.compiler})',
      );
    }
  }

  /// Compares two saved dills byte-for-byte, naming the step and both
  /// digests on any difference.
  Future<void> _compareDills({
    required String step,
    required String workerDill,
    required String oneshotDill,
  }) async {
    final Uint8List a = File('${work.path}/$workerDill').readAsBytesSync();
    final Uint8List b = File('${work.path}/$oneshotDill').readAsBytesSync();
    if (!bytesEqual(a, b)) {
      throw IdentityFailure(
        '$step differs: worker sha256=${await sha256OfFile('${work.path}/$workerDill')} '
        'one-shot sha256=${await sha256OfFile('${work.path}/$oneshotDill')}',
      );
    }
    final String digest = await sha256OfFile('${work.path}/$workerDill');
    print('identity-check: $step identical (sha256=$digest)');
  }

  Future<void> _workerS0() async {
    print('identity-check: worker leg (strategy=worker, one instance)');
    final String verbose = await _runBuild((
      step: 'worker-s0',
      outputBase: _wbase,
      linkPrefix: 'wlink-',
      strategyFlags: [
        '--strategy=FlutterKernelCompile=worker',
        '--worker_max_instances=FlutterKernelCompile=1',
      ],
      workerVerbose: true,
      wantRunner: 'worker',
      disk: '${work.path}/wdisk',
      logName: 'w0',
    ));
    _workerLogs.add(verbose);
    if (countCreatedWorkers(verbose) != 1) {
      throw IdentityFailure('worker-s0 created no (or several) workers');
    }
    _saveDill(
      built: _locateDill(linkPrefix: 'wlink-'),
      name: 'hw0.dill',
    );
    _checkWarm(step: 'worker-s0');
  }

  Future<void> _oneshotS0() async {
    print('identity-check: one-shot leg (strategy=local)');
    await _runBuild((
      step: 'oneshot-s0',
      outputBase: _obase,
      linkPrefix: 'olink-',
      strategyFlags: ['--strategy=FlutterKernelCompile=local'],
      workerVerbose: false,
      wantRunner: 'local',
      disk: '${work.path}/odisk',
      logName: 'o0',
    ));
    _saveDill(
      built: _locateDill(linkPrefix: 'olink-'),
      name: 'ho0.dill',
    );
    await _compareDills(
      step: 's0 worker-vs-oneshot',
      workerDill: 'hw0.dill',
      oneshotDill: 'ho0.dill',
    );
  }

  Future<void> _workerS1() async {
    print('identity-check: edit s1 (both libraries, new import)');
    applyEdits(path: _common, steps: s1CommonSteps, stepName: 's1');
    applyEdits(path: _main, steps: s1MainSteps, stepName: 's1');
    _workerLogs.add(
      await _runBuild((
        step: 'worker-s1',
        outputBase: _wbase,
        linkPrefix: 'wlink-',
        strategyFlags: [
          '--strategy=FlutterKernelCompile=worker',
          '--worker_max_instances=FlutterKernelCompile=1',
        ],
        workerVerbose: true,
        wantRunner: 'worker',
        disk: '${work.path}/wdisk',
        logName: 'w1',
      )),
    );
    _saveDill(
      built: _locateDill(linkPrefix: 'wlink-'),
      name: 'hw1.dill',
    );
    _checkWarm(step: 'worker-s1');
    _requireChanged(name: 'hw1.dill', other: 'hw0.dill', edit: 's1');
  }

  Future<void> _oneshotS1() async {
    await _runBuild((
      step: 'oneshot-s1',
      outputBase: _obase,
      linkPrefix: 'olink-',
      strategyFlags: ['--strategy=FlutterKernelCompile=local'],
      workerVerbose: false,
      wantRunner: 'local',
      disk: '${work.path}/odisk',
      logName: 'o1',
    ));
    _saveDill(
      built: _locateDill(linkPrefix: 'olink-'),
      name: 'ho1.dill',
    );
    await _compareDills(
      step: 's1 worker-vs-oneshot',
      workerDill: 'hw1.dill',
      oneshotDill: 'ho1.dill',
    );
  }

  Future<void> _workerS2() async {
    print('identity-check: edit s2 (both libraries)');
    applyEdits(path: _main, steps: s2MainSteps, stepName: 's2');
    applyEdits(path: _common, steps: s2CommonSteps, stepName: 's2');
    _workerLogs.add(
      await _runBuild((
        step: 'worker-s2',
        outputBase: _wbase,
        linkPrefix: 'wlink-',
        strategyFlags: [
          '--strategy=FlutterKernelCompile=worker',
          '--worker_max_instances=FlutterKernelCompile=1',
        ],
        workerVerbose: true,
        wantRunner: 'worker',
        disk: '${work.path}/wdisk',
        logName: 'w2',
      )),
    );
    _saveDill(
      built: _locateDill(linkPrefix: 'wlink-'),
      name: 'hw2.dill',
    );
    _checkWarm(step: 'worker-s2');
    _requireChanged(name: 'hw2.dill', other: 'hw1.dill', edit: 's2');
  }

  Future<void> _oneshotS2() async {
    await _runBuild((
      step: 'oneshot-s2',
      outputBase: _obase,
      linkPrefix: 'olink-',
      strategyFlags: ['--strategy=FlutterKernelCompile=local'],
      workerVerbose: false,
      wantRunner: 'local',
      disk: '${work.path}/odisk',
      logName: 'o2',
    ));
    _saveDill(
      built: _locateDill(linkPrefix: 'olink-'),
      name: 'ho2.dill',
    );
    await _compareDills(
      step: 's2 worker-vs-oneshot',
      workerDill: 'hw2.dill',
      oneshotDill: 'ho2.dill',
    );
  }

  Future<void> _workerS3() async {
    print('identity-check: revert to the original sources');
    restoreSources(mainPath: _main, commonPath: _common, dir: work.path);
    // The reverted inputs repeat s0 exactly, so without this the compile
    // would be an action-cache hit and the warm path would go untested.
    File(_locateDill(linkPrefix: 'wlink-')).deleteSync();
    _workerLogs.add(
      await _runBuild((
        step: 'worker-s3-reverted',
        outputBase: _wbase,
        linkPrefix: 'wlink-',
        strategyFlags: [
          '--strategy=FlutterKernelCompile=worker',
          '--worker_max_instances=FlutterKernelCompile=1',
        ],
        workerVerbose: true,
        wantRunner: 'worker',
        disk: '${work.path}/w3disk',
        logName: 'w3',
      )),
    );
    _saveDill(
      built: _locateDill(linkPrefix: 'wlink-'),
      name: 'hw3.dill',
    );
    _checkWarm(step: 'worker-s3-reverted');
    await _compareDills(
      step: 's3-reverted worker-vs-oneshot-s0',
      workerDill: 'hw3.dill',
      oneshotDill: 'ho0.dill',
    );
  }

  /// Guards against vacuous edits: an edit that changed no bytes would pass
  /// every comparison without testing anything.
  void _requireChanged({
    required String name,
    required String other,
    required String edit,
  }) {
    final Uint8List a = File('${work.path}/$name').readAsBytesSync();
    final Uint8List b = File('${work.path}/$other').readAsBytesSync();
    if (bytesEqual(a, b)) throw IdentityFailure('edit $edit changed no bytes');
  }

  void _verifyWarmthTotals() {
    print('identity-check: warmth evidence across the worker leg');
    var created = 0;
    for (final String log in _workerLogs) {
      created += countCreatedWorkers(log);
    }
    if (created != 1) {
      throw IdentityFailure(
        'created $created FlutterKernelCompile workers, want 1',
      );
    }
    final String? destroyed = findDestroyedWorker(_workerLogs);
    if (destroyed != null) {
      throw IdentityFailure(
        'a FlutterKernelCompile worker was destroyed mid-leg: $destroyed',
      );
    }
    final WorkerPids? warm = _warm;
    print(
      'identity-check: one worker (pid=${warm?.worker}), '
      'one compiler (pid=${warm?.compiler}), all four builds warm',
    );
  }

  void _watchSignals() {
    // SIGTERM is 15, SIGINT is 2: the conventional 128-plus-signum statuses.
    // A platform without these signals keeps only the normal exit paths;
    // those still clean up through [run]'s finally.
    try {
      _sigterm = ProcessSignal.sigterm.watch().listen((_) async {
        await _cleanup();
        exit(143);
      });
      _sigint = ProcessSignal.sigint.watch().listen((_) async {
        await _cleanup();
        exit(130);
      });
    } on UnsupportedError {
      // No watchable signals here; nothing to install.
    }
  }

  /// Restores the sources, shuts down both Bazel servers and deletes the
  /// scratch directory. Runs once, on every exit path. A failed server
  /// shutdown is reported but cannot fail the check: the exit code already
  /// reports the compile result.
  Future<void> _cleanup() async {
    if (_cleaned) return;
    _cleaned = true;
    await _sigint?.cancel();
    await _sigterm?.cancel();
    try {
      restoreSources(mainPath: _main, commonPath: _common, dir: work.path);
    } on FileSystemException catch (e) {
      stderr.writeln('identity-check: warning: restore failed ($e).');
    }
    for (final String base in [_wbase, _obase]) {
      final ProcessResult result = await Process.run(
        bazel,
        ['--output_base=$base', 'shutdown'],
        // Same workspace as the builds: under `bazel run` the tool's own
        // directory is the runfiles tree, which only adds a benign
        // startup-option mismatch to the shutdown.
        workingDirectory: _ws,
      );
      if (result.exitCode != 0) {
        stderr.writeln(
          'identity-check: warning: shutdown of $base failed '
          '(${result.stderr}).',
        );
      }
    }
    try {
      work.deleteSync(recursive: true);
    } on FileSystemException catch (e) {
      stderr.writeln('identity-check: warning: scratch delete failed ($e).');
    }
  }
}
