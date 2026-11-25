import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:perf/src/bazel.dart';
import 'package:perf/src/flow.dart';
import 'package:perf/src/flows/catalogue.dart';
import 'package:perf/src/flows/common.dart';
import 'package:perf/src/host.dart';
import 'package:perf/src/proc.dart';
import 'package:perf/src/workspace.dart';
import 'package:test/test.dart';

/// A flow whose runs take the values it is given; it can grow the
/// KILLED_UNKNOWN count of a fake server log, or fail a run.
final class _Fake extends Flow {
  _Fake(
    this.values, {
    this.killAt,
    this.failAt,
    this.warm = false,
    this.unavailable,
    this.exceedAt,
  });

  final List<double> values;
  final int? killAt;
  final int? failAt;
  final String? unavailable;
  final int? exceedAt;
  @override
  final bool warm;
  final calls = <String>[];
  String? log;

  @override
  String get id => 'fake.flow.rules';
  @override
  String get tool => 'rules_dart';
  @override
  String get corpus => 'c';
  @override
  String get flow => 'f';
  @override
  String get state => 's';
  @override
  Set<String> get tags => const {'cheap'};
  @override
  String describe(Ctx c) => 'fake';

  @override
  Future<void> setUp(Ctx c) async {
    calls.add('setUp');
    if (unavailable != null) throw NotAvailable(unavailable!);
  }

  @override
  Future<void> prepare(Ctx c, int run) async => calls.add('prepare $run');

  @override
  Future<Measured> measure(Ctx c, int run) async {
    calls.add('measure $run');
    if (run == failAt) throw StateError('boom');
    if (run == exceedAt) {
      // A child that leaves a grandchild holding the output pipes: only a
      // kill of the whole tree lets the call return before the sleeps end.
      await runCmd(
        Cmd(['sh', '-c', 'sleep 60 & sleep 60; wait'], cwd: '/'),
        timeout: const Duration(milliseconds: 300),
      );
    }
    if (run == killAt || killAt == -1) {
      File(log!).writeAsStringSync('KILLED_UNKNOWN\n', mode: FileMode.append);
    }
    return Measured(values[run], mnemonics: {'DartKernel': run});
  }

  @override
  Future<void> tearDown(Ctx c) async => calls.add('tearDown');
}

Ctx _ctx(String proc, {double noisy = 8, Duration settle = Duration.zero}) =>
    Ctx(
      repo: '/repo',
      scratch: Directory.systemTemp.createTempSync('scratch').path,
      bazel: const ['bazel'],
      stockEnv: const {},
      runs: 5,
      noisyLoad: noisy,
      settle: settle,
      host: Host(procRoot: proc),
    );

void main() {
  group('adding a dependency', () {
    const before = """
packages:
  collection:
    dependency: transitive
    version: "1.19.1"
  flutter:
    dependency: "direct main"
""";
    const after = """
packages:
  collection:
    dependency: transitive
    version: "1.19.1"
  device_info_plus:
    dependency: "direct main"
    version: "13.3.0"
  flutter:
    dependency: "direct main"
  win32:
    dependency: transitive
    version: "6.0.0"
""";

    test('the packages a lock adds', () {
      expect(addedPackages(before, after), {'device_info_plus', 'win32'});
      expect(addedPackages(after, before), isEmpty);
    });

    test('what may run: the app, the added packages and their Android libraries', () {
      final added = {'device_info_plus', 'win32'};
      for (final owner in [
        '//:counter',
        '@@//:app_r',
        '@@ai_rules_flutter++flutter+deps__win32//:win32',
        '@@ai_rules_flutter++flutter+deps__device_info_plus//:device_info_plus',
        '@@ai_rules_flutter++android_model+android_model//:p_device_info_plus__debug_dex_m24d',
      ]) {
        expect(ownedByAdded(owner, added), isTrue, reason: owner);
      }
      for (final owner in [
        '@@ai_rules_flutter++flutter+deps__win32_registry//:win32_registry',
        '@@ai_rules_flutter++flutter+deps__jni//:_dartjni_cc',
        '@@ai_rules_flutter++android_model+android_model//:p_url_launcher_android__debug',
        '@@ai_rules_flutter++android_model+android_model//:android_jar_android-34',
        '@@ai_rules_dart+//dart/private/tools:compile_wrapper',
        '?',
      ]) {
        expect(ownedByAdded(owner, added), isFalse, reason: owner);
      }
    });

    test(
      'an execution log by owner, and the actions of untouched packages',
      () {
        final log = [
          {'mnemonic': 'DartKernel', 'targetLabel': '//:counter'},
          {
            'mnemonic': 'DartKernel',
            'targetLabel': '//:counter',
            'cacheHit': true,
          },
          {
            'mnemonic': 'RdfDex',
            'targetLabel':
                '@@m+android_model//:p_url_launcher_android__debug_dex',
          },
          {
            'mnemonic': 'RdfDex',
            'targetLabel':
                '@@m+android_model//:p_url_launcher_android__debug_dex',
          },
          {'mnemonic': 'DartKernel', 'targetLabel': '@@f+deps__win32//:win32'},
        ].map(jsonEncode).join('\n');
        final executed = executedByOwner(log);
        expect(executed, {
          (owner: '//:counter', mnemonic: 'DartKernel'): 1,
          (
            owner: '@@m+android_model//:p_url_launcher_android__debug_dex',
            mnemonic: 'RdfDex',
          ): 2,
          (owner: '@@f+deps__win32//:win32', mnemonic: 'DartKernel'): 1,
        });
        expect(untouchedReruns(executed, {'win32'}), [
          '@@m+android_model//:p_url_launcher_android__debug_dex RdfDex x2',
        ]);
        expect(
          untouchedReruns(executed, {'win32', 'url_launcher_android'}),
          isEmpty,
        );
      },
    );
  });

  late Directory proc;
  setUp(() {
    proc = Directory.systemTemp.createTempSync('proc');
    File('${proc.path}/loadavg').writeAsStringSync('3.5 1 1 1/1 1\n');
  });
  tearDown(() => proc.deleteSync(recursive: true));

  test(
    'five runs, each prepared untimed, with the load and the median',
    () async {
      final f = _Fake([0.5, 0.1, 0.3, 0.2, 0.4]);
      final row = await measureFlow(f, _ctx(proc.path));
      expect(row.status, 'ok');
      expect(row.runs, [0.5, 0.1, 0.3, 0.2, 0.4]);
      expect(row.median, 0.3);
      expect(row.load1, List.filled(5, 3.5));
      expect(row.bazelServers, List.filled(5, 0));
      expect(row.noisy, isFalse);
      expect(row.mnemonics, {'DartKernel': 4});
      expect(f.calls, [
        'setUp',
        for (var i = 0; i < 5; i++) ...['prepare $i', 'measure $i'],
        'tearDown',
      ]);
    },
  );

  test('a run waits for the load its own preparation left to settle', () async {
    // The load is above the threshold until a second after the start.
    Timer(const Duration(milliseconds: 1200), () {
      File('${proc.path}/loadavg').writeAsStringSync('1.0 1 1 1/1 1\n');
    });
    final row = await measureFlow(
      _Fake([1, 1, 1, 1, 1]),
      _ctx(proc.path, noisy: 2, settle: const Duration(seconds: 10)),
    );
    expect(row.noisy, isFalse);
    expect(row.load1, everyElement(1.0));
  });

  test('a run above the load threshold makes the row noisy', () async {
    final row = await measureFlow(
      _Fake([1, 1, 1, 1, 1]),
      _ctx(proc.path, noisy: 2),
    );
    expect(row.noisy, isTrue);
    expect(row.notes, contains('noisy'));
  });

  test('a failed run fails the row and still tears down', () async {
    final f = _Fake([1, 1, 1, 1, 1], failAt: 2);
    final row = await measureFlow(f, _ctx(proc.path));
    expect(row.status, 'failed');
    expect(row.notes, contains('boom'));
    expect(f.calls.last, 'tearDown');
  });

  test(
    'a command over its limit is killed with its tree, and the row '
    'says the flow exceeded it',
    () async {
      final f = _Fake([1, 1, 1, 1, 1], exceedAt: 1);
      final watch = Stopwatch()..start();
      final row = await measureFlow(f, _ctx(proc.path));
      expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
      expect(row.status, 'exceeded');
      expect(row.notes, contains('exceeded 0 minutes'));
      expect(f.calls.last, 'tearDown');
    },
    // The harness runs where `/proc` and POSIX process groups are: the fake
    // flow's command is `sh -c 'sleep & sleep'`, and killing a Windows
    // process does not kill the grandchildren holding its pipes.
    skip: Platform.isWindows ? 'the harness is POSIX' : null,
  );

  test('a flow this host cannot run says so', () async {
    final row = await measureFlow(
      _Fake([], unavailable: 'no Mac'),
      _ctx(proc.path),
    );
    expect(row.status, 'not_available');
    expect(row.notes, contains('no Mac'));
  });

  test(
    'a run that loses its warm workers is discarded; too many fail the flow',
    () async {
      final ob = Directory.systemTemp.createTempSync('ob');
      addTearDown(() => ob.deleteSync(recursive: true));
      final log = '${ob.path}/java.log.h.u.log.java.1';
      File(log).writeAsStringSync('start\n');
      final once = _WithServer(
        ob.path,
        [1, 2, 3, 9, 4, 5],
        killAt: 3,
        warm: true,
      )..log = log;
      final row = await measureFlow(once, _ctx(proc.path));
      expect(row.status, 'ok');
      expect(row.runs, [1, 2, 3, 4, 5]);
      expect(row.notes, contains('run 4 discarded: KILLED_UNKNOWN'));
      expect(row.workers?['killed_unknown'], [0, 1]);
      expect(row.workers?['runs_discarded'], 1);

      File(log).writeAsStringSync('start\n');
      final always = _WithServer(
        ob.path,
        List.filled(9, 1),
        killAt: -1,
        warm: true,
      )..log = log;
      final bad = await measureFlow(always, _ctx(proc.path));
      expect(bad.status, 'failed');
      expect(bad.notes, contains('lost their warm workers'));
    },
  );

  test('edits go in with a new number and come out again', () {
    final dir = Directory.systemTemp.createTempSync('edit');
    addTearDown(() => dir.deleteSync(recursive: true));
    Directory('${dir.path}/lib/v-1.2').createSync(recursive: true);
    final file = File('${dir.path}/lib/v-1.2/a.dart')
      ..writeAsStringSync('int f(int x) {\n  return x;\n}\n');
    final edits = Edits();
    const body = EditSpec(
      'lib/v-*/a.dart',
      EditKind.body,
      anchor: 'int f(int x) {',
    );
    edits.apply(dir.path, body, 7);
    edits.apply(dir.path, body, 8);
    expect(
      file.readAsStringSync(),
      'int f(int x) {\n${dartBodyLine(8)}\n  return x;\n}\n',
    );
    edits.apply(dir.path, const EditSpec('lib/v-1.2/a.dart', EditKind.api), 9);
    expect(file.readAsStringSync(), endsWith('${dartApiDecl(9)}\n'));
    edits.restore();
    expect(file.readAsStringSync(), 'int f(int x) {\n  return x;\n}\n');
  });

  test('a copied workspace points the rules at the repository', () {
    final dir = Directory.systemTemp.createTempSync('copy');
    addTearDown(() => dir.deleteSync(recursive: true));
    final src = Directory('${dir.path}/repo/rules_flutter/e2e/app')
      ..createSync(recursive: true);
    File('${src.path}/MODULE.bazel')
        .writeAsStringSync('module(name = "app")\n');
    Directory('${src.path}/.dart_tool').createSync();
    Link('${src.path}/bazel-bin').createSync('/nonexistent');
    final ws = e2eCopy(
      '${dir.path}/repo',
      '${dir.path}/scratch',
      'rules_flutter/e2e/app',
      rcLines: ['import /x.bazelrc'],
    );
    expect(File('$ws/MODULE.bazel').existsSync(), isTrue);
    expect(Directory('$ws/.dart_tool').existsSync(), isFalse);
    expect(
      FileSystemEntity.typeSync('$ws/bazel-bin', followLinks: false),
      FileSystemEntityType.notFound,
    );
    final rc = File('$ws/.bazelrc.user').readAsStringSync();
    expect(
      rc,
      contains(
        '--override_module=ai_rules_flutter=${dir.path}/repo/rules_flutter',
      ),
    );
    expect(rc, contains('import /x.bazelrc'));
    expect(
      File('$ws/.bazelrc').readAsStringSync(),
      contains('try-import %workspace%/.bazelrc.user'),
    );
  });
}

final class _WithServer extends _Fake {
  _WithServer(this.ob, super.values, {super.killAt, super.warm});
  final String ob;
  @override
  Bazel get server => Bazel(const ['false'], '/', outputBase: ob);
}
