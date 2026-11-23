/// Unit tests for the incremental kernel identity check's pure parts.
library;

import 'dart:io';

import 'package:test/test.dart';

import '../identity.dart';

String _logEntry({required String runner, required bool cacheHit}) =>
    '''
{
  "mnemonic": "FlutterKernelCompile",
  "runner": "$runner",
  "cacheHit": ${cacheHit ? 'true' : 'false'},
  "actions": []
}
''';

/// A fake `/proc/<pid>` subtree: [cmdline] is NUL-separated, [stat] carries
/// [ppid] after the command name in parentheses.
void _fakeProc({
  required String root,
  required int pid,
  required String cmdline,
  required int ppid,
}) {
  final dir = Directory('$root/$pid')..createSync(recursive: true);
  File('${dir.path}/cmdline').writeAsBytesSync([
    ...cmdline.codeUnits,
    0,
  ]);
  File('${dir.path}/stat').writeAsStringSync(
    '$pid (proc$pid) S $ppid 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0',
  );
}

const _workerBase =
    'dart-sdk/bin/dartaotruntime /tmp/wbase/bazel_workers/incr_fkc_worker '
    '--persistent_worker --output_base=/tmp/wbase';

void _fakeTree(String root, {String workerBase = '/tmp/wbase'}) {
  _fakeProc(
    root: root,
    pid: 100,
    cmdline: _workerBase.replaceAll('/tmp/wbase', workerBase),
    ppid: 1,
  );
  _fakeProc(
    root: root,
    pid: 101,
    cmdline: 'frontend_server --server --output_base=$workerBase/dill',
    ppid: 100,
  );
}

void main() {
  group('splitTopLevelJsonValues', () {
    test('splits concatenated pretty objects, ignoring braces in strings', () {
      final text = '{"a": 1, "s": "}{"}\n{"b": {"c": 2}}';
      final List<String> parts = splitTopLevelJsonValues(text);
      expect(parts, hasLength(2));
      expect(parts[0], contains('"a": 1'));
      expect(parts[1], contains('"c": 2'));
    });

    test('empty text holds no values', () {
      expect(splitTopLevelJsonValues(''), isEmpty);
    });
  });

  group('checkStrategy', () {
    test('a matching entry passes', () {
      final StrategyVerdict verdict = checkStrategy(
        logText: '${_logEntry(runner: 'worker', cacheHit: false)}\n',
        wantRunner: 'worker',
        step: 'worker-s0',
      );
      expect(verdict.ok, isTrue);
      expect(verdict.actions, 1);
    });

    test('the wrong runner fails', () {
      final StrategyVerdict verdict = checkStrategy(
        logText: _logEntry(runner: 'local', cacheHit: false),
        wantRunner: 'worker',
        step: 'worker-s0',
      );
      expect(verdict.ok, isFalse);
      expect(verdict.detail, contains('worker-s0'));
    });

    test('a cache hit fails', () {
      final StrategyVerdict verdict = checkStrategy(
        logText: _logEntry(runner: 'worker', cacheHit: true),
        wantRunner: 'worker',
        step: 'worker-s0',
      );
      expect(verdict.ok, isFalse);
    });

    test('no entry fails closed', () {
      final StrategyVerdict verdict = checkStrategy(
        logText: '{"mnemonic": "DartCompile", "runner": "worker"}\n',
        wantRunner: 'worker',
        step: 'worker-s0',
      );
      expect(verdict.ok, isFalse);
      expect(verdict.actions, 0);
    });

    test('an unparsable log fails closed', () {
      final StrategyVerdict verdict = checkStrategy(
        logText: '{not json',
        wantRunner: 'worker',
        step: 'worker-s0',
      );
      expect(verdict.ok, isFalse);
    });
  });

  group('warmth evidence', () {
    test('created workers are counted', () {
      expect(countCreatedWorkers('no workers here\n'), 0);
      expect(
        countCreatedWorkers('2026-01-01 Created FlutterKernelCompile worker\n'),
        1,
      );
      expect(
        countCreatedWorkers(
          'Created x FlutterKernelCompile worker\n'
          'Created y FlutterKernelCompile worker\n',
        ),
        2,
      );
    });

    test('a destroyed worker line is found, calm logs read null', () {
      expect(findDestroyedWorker(['all calm\n']), isNull);
      expect(
        findDestroyedWorker([
          'all calm\n',
          'destroying idle FlutterKernelCompile worker\n',
        ]),
        contains('FlutterKernelCompile'),
      );
    });

    test('PID stability compares both processes', () {
      const ({int compiler, int worker}) base = (worker: 100, compiler: 101);
      expect(samePids((worker: 100, compiler: 101), base), isTrue);
      expect(samePids((worker: 999, compiler: 101), base), isFalse);
      expect(samePids((worker: 100, compiler: 999), base), isFalse);
    });
  });

  group('findWorkerPids', () {
    late Directory proc;
    setUp(() => proc = Directory.systemTemp.createTempSync('fake_proc_'));
    tearDown(() => proc.deleteSync(recursive: true));

    test('finds the worker scoped to its output base and its compiler', () {
      _fakeTree(proc.path);
      expect(
        findWorkerPids(outputBase: '/tmp/wbase', procRoot: proc.path),
        (worker: 100, compiler: 101),
      );
    });

    test('a worker from another output base never matches', () {
      _fakeTree(proc.path, workerBase: '/tmp/other');
      expect(
        findWorkerPids(outputBase: '/tmp/wbase', procRoot: proc.path),
        isNull,
      );
    });

    test('two workers read as absent', () {
      _fakeTree(proc.path);
      _fakeProc(root: proc.path, pid: 200, cmdline: _workerBase, ppid: 1);
      expect(
        findWorkerPids(outputBase: '/tmp/wbase', procRoot: proc.path),
        isNull,
      );
    });

    test('a worker without its compiler reads as absent', () {
      _fakeProc(root: proc.path, pid: 100, cmdline: _workerBase, ppid: 1);
      _fakeProc(
        root: proc.path,
        pid: 101,
        cmdline: 'frontend_server --server',
        ppid: 999,
      );
      expect(
        findWorkerPids(outputBase: '/tmp/wbase', procRoot: proc.path),
        isNull,
      );
    });

    test('an empty process tree reads as absent', () {
      expect(
        findWorkerPids(outputBase: '/tmp/wbase', procRoot: proc.path),
        isNull,
      );
    });
  });

  group('source edits', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('identity_edits_');
      File('${dir.path}/a.dart').writeAsStringSync('int x = 1;\nint y = 2;\n');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('a single anchor is replaced', () {
      applyEdits(
        path: '${dir.path}/a.dart',
        steps: [(oldText: 'int x = 1;', newText: 'int x = 42;')],
        stepName: 's1',
      );
      expect(File('${dir.path}/a.dart').readAsStringSync(), contains('x = 42'));
    });

    test('a missing anchor throws', () {
      expect(
        () => applyEdits(
          path: '${dir.path}/a.dart',
          steps: [(oldText: 'int missing = 0;', newText: 'int z = 3;')],
          stepName: 's1',
        ),
        throwsA(isA<IdentityFailure>()),
      );
    });

    test('a doubled anchor throws instead of editing the wrong text', () {
      File('${dir.path}/a.dart').writeAsStringSync('int x = 1;\nint x = 1;\n');
      expect(
        () => applyEdits(
          path: '${dir.path}/a.dart',
          steps: [(oldText: 'int x = 1;', newText: 'int x = 42;')],
          stepName: 's1',
        ),
        throwsA(isA<IdentityFailure>()),
      );
    });

    test('backup and restore round-trip both sources', () {
      // Production filenames: the dotted `common_widgets.dart` stem once
      // drifted between backup and restore, silently skipping its restore.
      final main = File('${dir.path}/main.dart')
        ..writeAsStringSync('main v1\n');
      final common = File('${dir.path}/common_widgets.dart')
        ..writeAsStringSync('common v1\n');
      backupSources(
        mainPath: main.path,
        commonPath: common.path,
        dir: dir.path,
      );
      main.writeAsStringSync('main v2\n');
      common.writeAsStringSync('common v2\n');
      restoreSources(
        mainPath: main.path,
        commonPath: common.path,
        dir: dir.path,
      );
      expect(main.readAsStringSync(), 'main v1\n');
      expect(common.readAsStringSync(), 'common v1\n');
    });

    test('restore after editing both sources recovers exact bytes', () {
      // Pins the s3 revert: both edited files must come back byte-for-byte,
      // so a warm recompile over the reverted inputs repeats s0 exactly.
      const mainOrig = '// main original\nvoid main() {}\n';
      const commonOrig = '// common original\nclass C {}\n';
      final main = File('${dir.path}/main.dart')..writeAsStringSync(mainOrig);
      final common = File('${dir.path}/common_widgets.dart')
        ..writeAsStringSync(commonOrig);
      backupSources(
        mainPath: main.path,
        commonPath: common.path,
        dir: dir.path,
      );
      main.writeAsStringSync('// main edited $mainOrig');
      common.writeAsStringSync('// common edited $commonOrig');
      restoreSources(
        mainPath: main.path,
        commonPath: common.path,
        dir: dir.path,
      );
      expect(main.readAsBytesSync(), mainOrig.codeUnits);
      expect(common.readAsBytesSync(), commonOrig.codeUnits);
    });

    test('restore with no backup leaves the file alone', () {
      final main = File('${dir.path}/main.dart')
        ..writeAsStringSync('main v1\n');
      restoreSources(
        mainPath: main.path,
        commonPath: '${dir.path}/common.dart',
        dir: dir.path,
      );
      expect(main.readAsStringSync(), 'main v1\n');
    });
  });

  group('locateDill', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('identity_dill_');
      Directory('${dir.path}/wlink-bin').createSync();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('a regular file resolves to itself', () {
      final dill = File('${dir.path}/wlink-bin/hello_world.dill')
        ..writeAsStringSync('dill');
      expect(
        locateDill(workDir: dir.path, linkPrefix: 'wlink-'),
        dill.resolveSymbolicLinksSync(),
      );
    });

    test('a symlink resolves to its target', () {
      final target = File('${dir.path}/real.dill')..writeAsStringSync('dill');
      Link(
        '${dir.path}/wlink-bin/hello_world.dill',
      ).createSync(target.path);
      expect(
        locateDill(workDir: dir.path, linkPrefix: 'wlink-'),
        target.resolveSymbolicLinksSync(),
      );
    });

    test('a missing entry throws', () {
      expect(
        () => locateDill(workDir: dir.path, linkPrefix: 'wlink-'),
        throwsA(isA<IdentityFailure>()),
      );
    });
  });

  group('bytes and digests', () {
    test('bytesEqual compares lengths and contents', () {
      expect(bytesEqual([1, 2], [1, 2]), isTrue);
      expect(bytesEqual([1, 2], [1, 2, 3]), isFalse);
      expect(bytesEqual([1, 2], [1, 3]), isFalse);
    });

    test('sha256OfFile matches sha256sum on known inputs', () async {
      final Directory dir = Directory.systemTemp.createTempSync(
        'identity_sha_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/in.txt')..writeAsStringSync('identity\n');
      expect(
        await sha256OfFile(file.path),
        '560ee359cf3259353f1bc53e0c8add2aec9ec79cf533cbb5385423e42a34822a',
      );
    });
  });

  group('edit sequences', () {
    test('every step list holds at least one step', () {
      expect(s1CommonSteps, isNotEmpty);
      expect(s1MainSteps, isNotEmpty);
      expect(s2MainSteps, isNotEmpty);
      expect(s2CommonSteps, isNotEmpty);
    });
  });
}
