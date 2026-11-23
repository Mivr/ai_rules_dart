/// The dev loop on the Android emulator: `flutter_dev run` (Bazel builds,
/// the stock tool runs) against stock `flutter run`, both in `--machine`
/// mode: start to `app.started`, hot reload after an edit, hot restart.
library;

import 'dart:io';

import '../daemon.dart';
import '../flow.dart';
import '../proc.dart';
import '../workspace.dart';
import 'common.dart';
import 'device.dart';

/// The workspace both sides run: a stock app with a plugin, a workspace
/// package and generated l10n.
const devLoopWorkspace = 'rules_flutter/e2e/stock_dev_loop';

/// The APK target flutter_dev builds (the x86_64 APK the emulator runs).
const devLoopTarget = '//:app_x64';

/// The file a reload edits and the line the edit goes after.
const devLoopEdit = EditSpec(
  'lib/main.dart',
  EditKind.body,
  anchor: '  void _incrementCounter() {',
);

/// One dev-loop step for one tool.
final class DevLoopFlow extends Flow {
  /// [step] is `start`, `reload` or `restart`; [stock] picks the tool.
  DevLoopFlow(this.step, {required this.stock});

  /// The step.
  final String step;

  /// Stock `flutter run` (true) or `flutter_dev run` (false).
  final bool stock;

  @override
  String get id => 'devloop.$step.${stock ? 'stock' : 'flutter_dev'}';

  @override
  String get tool => stock ? 'stock' : 'rules_flutter';

  @override
  String get corpus => 'stock_dev_loop';

  @override
  String get flow => 'dev_loop';

  @override
  String get state => step;

  @override
  Set<String> get tags => const {'emulator', 'android'};

  late String _ws;
  late List<String> _argv;
  late Emulator _emu;
  MachineSession? _session;
  final _edits = Edits();

  @override
  String describe(Ctx c) =>
      '${stock ? 'flutter run' : 'flutter_dev run --bazel-target=$devLoopTarget'} -d <emulator> --machine; '
      '${switch (step) {
        'start' => 'one untimed start first (builds and installs); time: process start to the app.started event (flutter_dev holds it back until its automatic hot restart is done); a new session each run',
        'reload' => 'one session; before each run ${devLoopEdit.describe}; time: the app.restart request (fullRestart false) to its response',
        _ => 'one session; time: the app.restart request (fullRestart true) to its response',
      }}';

  @override
  Future<void> setUp(Ctx c) async {
    _emu = await emulator(c);
    if (stock) {
      _ws = '${c.scratch}/stock/stock_dev_loop';
      if (!File('$_ws/.bench-copied').existsSync()) {
        copyTree('${c.repo}/$devLoopWorkspace', _ws);
        File('$_ws/.bench-copied').writeAsStringSync('');
      }
      await must(
        c.stock(['flutter', 'pub', 'get', '--offline'], _ws),
        log: c.log(id),
      );
      // The project has no l10n.yaml, so stock `flutter run` does not
      // generate the localizations main.dart imports.
      await must(c.stock(['flutter', 'gen-l10n'], _ws), log: c.log(id));
      _argv = ['flutter', 'run', '-d', _emu.serial, '--machine'];
    } else {
      _ws = e2eCopy(
        c.repo,
        c.scratch,
        devLoopWorkspace,
        rcLines: [
          ...c.bazelrcLines,
          if (c.androidBazelrc != null) 'import ${c.androidBazelrc}',
        ],
      );
      final script = '${c.scratch}/flutter_dev.sh';
      await c.bazelIn(_ws, id).must([
        'run',
        '--script_path=$script',
        '@rules_flutter//tools/flutter_dev',
      ]);
      _argv = [
        script,
        'run',
        '--bazel-target=$devLoopTarget',
        '--bazel=${c.bazel.first}',
        '-d',
        _emu.serial,
        '--machine',
      ];
    }
    await uninstallApp(c, _emu, c.log(id));
    _session = await _start(c);
    await _session!.event('app.started');
    if (step == 'start') {
      // The first start builds and installs the app; the timed starts find
      // it built.
      await _session!.stop();
      _session = null;
    }
  }

  Future<MachineSession> _start(Ctx c) =>
      MachineSession.start(_argv, _ws, _emu.env, log: c.log(id));

  @override
  Future<void> prepare(Ctx c, int run) async {
    if (step == 'reload') _edits.apply(_ws, devLoopEdit, c.fresh());
  }

  @override
  Future<Measured> measure(Ctx c, int run) async {
    final watch = Stopwatch()..start();
    if (step == 'start') {
      final s = await _start(c);
      try {
        await s.event('app.started');
        watch.stop();
      } finally {
        await s.stop();
      }
    } else {
      await _session!.restart(full: step == 'restart');
      watch.stop();
    }
    return Measured(watch.elapsedMicroseconds / 1e6);
  }

  @override
  Future<void> tearDown(Ctx c) async {
    await _session?.stop();
    _session = null;
    _edits.restore();
  }
}
