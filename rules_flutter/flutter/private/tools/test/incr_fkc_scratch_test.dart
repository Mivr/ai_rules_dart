// Tagged `runfiles`: the lifecycle tests drive the built worker binary
// from runfiles data and run the fake compiler on the same Dart VM the test
// itself runs on. A bare `dart test` supplies neither.
// Coverage comes from //flutter/private/tools:incr_fkc_scratch_test.
@Tags(['runfiles'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../incr_fkc_scratch.dart';

/// A fake `frontend_server` speaking the incremental line protocol, written
/// into the harness by [ScratchHarness.writeFakeServer] and run on the test
/// VM. It writes the private dills on every compile, answers the result
/// lines the worker parses, quits on `quit`, and exits — deleting its pid
/// file — on stdin EOF, so a leftover pid file proves a leftover process.
const String _fakeServerSource = r'''
import 'dart:convert';
import 'dart:io';

String? _flag(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

Future<void> _respond(Stdout out, String cwd, String? full, String? inc) {
  const uuid = '11111111-2222-3333-4444-555555555555';
  if (full != null) File(full).writeAsBytesSync(utf8.encode('full-dill'));
  if (inc != null) File(inc).writeAsBytesSync(utf8.encode('inc-dill'));
  out.writeln('result $uuid');
  out.writeln(uuid);
  for (final rel in [
    'lib/main.dart',
    'lib/a.dart',
    'stage/lib/main.dart',
    'stage/lib/a.dart',
    'stage/lib/main.dart',
    'stage/lib/a.dart',
    'pkg_config.json',
    'platform.dill',
  ]) {
    out.writeln('+file://$cwd/$rel');
  }
  out.writeln('$uuid out.dill 0');
  return out.flush();
}

Future<void> main(List<String> args) async {
  final pidFile = _flag(args, '--pid-file')!;
  File(pidFile).writeAsStringSync('$pid');
  final full = _flag(args, '--output-dill');
  final inc = _flag(args, '--output-incremental-dill');
  final cwd = Directory.current.path;
  try {
    var pending = false;
    final lines =
        stdin.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (line.startsWith('compile ')) {
        await _respond(stdout, cwd, full, inc);
      } else if (line.startsWith('recompile ')) {
        pending = true;
      } else if (line == 'kk' && pending) {
        pending = false;
        await _respond(stdout, cwd, full, inc);
      } else if (line == 'reset' || line == 'accept') {
        // Acknowledged with silence, like the real server.
      } else if (line == 'reject') {
        stdout.writeln('rejected');
        stdout.writeln('ok');
        await stdout.flush();
      } else if (line == 'quit') {
        return;
      }
    }
  } finally {
    try {
      File(pidFile).deleteSync();
    } on FileSystemException {
      // Already gone; the test only checks absence.
    }
  }
}
''';

/// A helper that holds a scratch lock exactly the way a live worker does —
/// `openSync` plus `lockSync(FileLock.exclusive)` on the lock file — with no
/// socket involved, then sleeps until killed. The sweep probes in process,
/// and POSIX record locks only conflict between processes, so the owner's
/// lock must be held from a separate process like this one for the sweep to
/// see it as live.
const String _holderSource = r'''
import 'dart:io';
Future<void> main(List<String> args) async {
  final handle = File(args[0]).openSync(mode: FileMode.write);
  handle.lockSync(FileLock.exclusive);
  stdout.writeln('held');
  await stdout.flush();
  await Future<void>.delayed(const Duration(minutes: 10));
}
''';

/// A helper that attempts a shared lock on a path the way the sweep's
/// probe does, prints `held` or `free`, and exits. A shared lock conflicts
/// with a live owner's exclusive lock and succeeds once it is dead.
const String _sharedProbeSource = r'''
import 'dart:io';
Future<void> main(List<String> args) async {
  try {
    final handle = File(args[0]).openSync(mode: FileMode.read);
    handle.lockSync(FileLock.shared);
    stdout.writeln('free');
    await stdout.flush();
    await handle.close();
  } on FileSystemException {
    stdout.writeln('held');
    await stdout.flush();
  }
}
''';

/// A workspace with a manifest, clean sources, and the files the compiler
/// reports reading, used as a worker's cwd.
class ScratchHarness {
  new(this.dir);

  final Directory dir;
  String get cwd => dir.path;

  void write(String rel, String content) {
    File('${dir.path}/$rel')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  void writeManifest() {
    write(
      'manifest.txt',
      [
        'lib/main.dart',
        'lib/a.dart',
        '# staged',
        'stage/lib/main.dart',
        'stage/lib/a.dart',
        '# allowed-reads',
        'pkg_config.json',
        'platform.dill',
        '# filesystem-roots',
        'stage',
        '# output',
        'out/app.dill',
      ].join('\n'),
    );
  }

  void writeCleanSources() {
    write('lib/main.dart', "import 'a.dart';\nvoid main() {}\n");
    write('lib/a.dart', 'int get answer => 42;\n');
    write('stage/lib/main.dart', "import 'a.dart';\nvoid main() {}\n");
    write('stage/lib/a.dart', 'int get answer => 42;\n');
    write('pkg_config.json', '{}\n');
    write('platform.dill', 'platform\n');
  }

  void writeFakeServer() {
    write('fake_fs.dart', _fakeServerSource);
  }

  List<String> argv(String pidFile) => [
    '--declared-inputs',
    'manifest.txt',
    '--',
    Platform.resolvedExecutable,
    '${dir.path}/fake_fs.dart',
    '--pid-file',
    pidFile,
    '--output-dill',
    'out/app.dill',
    '--filesystem-root',
    'stage',
    '--packages',
    'pkg_config.json',
    'package:app/main.dart',
  ];

  List<String> get inputs => [
    'manifest.txt',
    'lib/main.dart',
    'lib/a.dart',
    'stage/lib/main.dart',
    'stage/lib/a.dart',
    'pkg_config.json',
    'platform.dill',
  ];
}

/// Resolves the built worker binary from the `INCR_FKC_WORKER_BIN` env var
/// (an rlocationpath), the way the Mach-O tests resolve their hermetic
/// tools. Throws when it cannot be found: these tests drive the real
/// binary, so a missing binary fails instead of passing vacuously.
String _workerBinary() {
  final String? rel = Platform.environment['INCR_FKC_WORKER_BIN'];
  if (rel != null && rel.isNotEmpty && File(rel).existsSync()) {
    return File(rel).absolute.path;
  }
  final String? runfilesDir =
      Platform.environment['RUNFILES_DIR'] ??
      Platform.environment['TEST_SRCDIR'];
  if (runfilesDir != null && rel != null) {
    for (final candidate in ['$runfilesDir/$rel', '$runfilesDir/_main/$rel']) {
      if (File(candidate).existsSync()) {
        return File(candidate).absolute.path;
      }
    }
  }
  throw StateError(
    'incr_fkc_worker binary not found (INCR_FKC_WORKER_BIN=$rel).',
  );
}

/// A separate process holding a scratch lock the way a live worker does.
/// Only touches its own process: start it, and SIGKILL it when done.
class LockHolder {
  new _(this.process);

  final Process process;

  /// Starts the holder for [lockPath] and waits until it confirms the lock
  /// is taken. Throws when the holder never confirms.
  static Future<LockHolder> start(String script, String lockPath) async {
    final Process proc = await Process.start(Platform.resolvedExecutable, [
      script,
      lockPath,
    ]);
    final StreamIterator<String> lines = StreamIterator(
      proc.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    try {
      final bool confirmed = await lines.moveNext().timeout(
        const Duration(seconds: 60),
      );
      if (!confirmed || lines.current != 'held') {
        throw StateError('the lock holder never confirmed its lock');
      }
    } catch (_) {
      proc.kill(ProcessSignal.sigkill);
      rethrow;
    } finally {
      await lines.cancel();
    }
    return LockHolder._(proc);
  }

  /// SIGKILLs the holder and waits for the death to land, releasing the
  /// kernel lock with the process. Only touches its own process.
  Future<void> kill() async {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
  }
}

/// Writes a helper [source] under [name] next to the test's scratch and
/// returns its path. Helper scripts are files outside the sweep prefix, so
/// the sweep ignores them.
String _writeScript(Directory parent, String name, String source) =>
    (File('${parent.path}/$name')..writeAsStringSync(source)).path;

/// Writes the lock-holder helper next to the test's scratch and returns its
/// path.
String _writeHolderScript(Directory parent) =>
    _writeScript(parent, 'hold_lock.dart', _holderSource);

/// Runs the shared-lock probe helper against [lockPath] and returns its
/// `held` or `free` verdict. Only ever touches the probe's own process.
Future<String> _sharedVerdict(String script, String lockPath) async {
  final Process proc = await Process.start(Platform.resolvedExecutable, [
    script,
    lockPath,
  ]);
  final StreamIterator<String> lines = StreamIterator(
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  final String verdict =
      await lines.moveNext().timeout(const Duration(seconds: 60))
      ? lines.current
      : '';
  await lines.cancel();
  await proc.exitCode.timeout(const Duration(seconds: 60));
  return verdict;
}

/// This process's current child PIDs, unioned over every thread's children
/// listing. For proving a sweep spawns no process: holders spawned before
/// the sweep are already members, and the sweep must add none.
Set<String> _childPids() {
  final out = <String>{};
  for (final FileSystemEntity task in Directory('/proc/self/task').listSync()) {
    final listing = File('${task.path}/children');
    if (!listing.existsSync()) continue;
    out.addAll(
      listing
          .readAsStringSync()
          .trim()
          .split(RegExp(r'\s+'))
          .where((pid) => pid.isNotEmpty),
    );
  }
  return out;
}

/// Whether this process can enumerate its children through /proc.
bool _canListChildren() => Directory('/proc/self/task').existsSync();

/// Writes an unlocked lock file into [dir]: a scratch whose owner is dead.
void _writeDeadLock(Directory dir) {
  File('${dir.path}/$incrFkcLockFileName').writeAsStringSync('');
}

/// The names of this worker's scratch entries under [tmp].
List<String> _scratchNames(Directory tmp) {
  final names = <String>[];
  for (final FileSystemEntity entry in tmp.listSync()) {
    if (entry is! Directory) continue;
    final String name = entry.path.split(Platform.pathSeparator).last;
    if (name.startsWith(incrFkcScratchPrefix)) names.add(name);
  }
  return names..sort();
}

/// Whether any file under [dir] ends with [suffix].
bool _hasFileBelow(Directory dir, String suffix) {
  for (final FileSystemEntity entry in dir.listSync(recursive: true)) {
    if (entry is File && entry.path.endsWith(suffix)) return true;
  }
  return false;
}

/// Waits up to [limit] for [path] to disappear (used for fake pid files:
/// absence proves the process is gone). Polls; never throws.
Future<bool> _waitGone(String path, Duration limit) async {
  final DateTime end = DateTime.now().add(limit);
  while (DateTime.now().isBefore(end)) {
    if (!File(path).existsSync()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return !File(path).existsSync();
}

/// One driven worker process: the built binary on the persistent protocol.
class DrivenWorker {
  new _(this.process, this._lines);

  final Process process;
  final StreamIterator<String> _lines;

  /// Starts the worker with [tmp] as its TMPDIR and [cwd] as its cwd.
  static Future<DrivenWorker> start(
    String binary,
    List<String> argv,
    String cwd,
    String tmp,
  ) async {
    final Process proc = await Process.start(
      binary,
      ['--persistent_worker', ...argv],
      workingDirectory: cwd,
      environment: {...Platform.environment, 'TMPDIR': tmp},
    );
    return DrivenWorker._(
      proc,
      StreamIterator(
        proc.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
    );
  }

  /// Serves one request and returns the decoded reply.
  Future<Map<String, dynamic>> serve(
    List<String> argv,
    List<String> inputs,
    int requestId,
  ) async {
    process.stdin.writeln(
      jsonEncode({
        'requestId': requestId,
        'arguments': argv,
        'inputs': [
          for (final i in inputs) {'path': i},
        ],
      }),
    );
    await process.stdin.flush();
    final bool hasReply = await _lines.moveNext().timeout(
      const Duration(seconds: 60),
    );
    if (!hasReply) {
      throw StateError('worker stdout closed before its reply.');
    }
    return jsonDecode(_lines.current) as Map<String, dynamic>;
  }

  /// Kills the worker the way Bazel or the OOM killer would, and waits for
  /// the death to land. Only ever touches this worker's own process.
  Future<void> sigkill() async {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await _lines.cancel();
  }

  /// Closes stdin (EOF) and waits up to [limit] for the exit.
  Future<int> eofAndWait(Duration limit) async {
    await process.stdin.close();
    try {
      return await process.exitCode.timeout(limit);
    } finally {
      await _lines.cancel();
    }
  }
}

void main() {
  group('sweepWorkerScratch', () {
    late Directory parent;

    setUp(() {
      parent = Directory.systemTemp.createTempSync('incr_sweep_test_');
      addTearDown(() => parent.deleteSync(recursive: true));
    });

    test('reclaims a dead worker scratch', () async {
      final dead = Directory('${parent.path}/incr_fkc_dead0001')..createSync();
      _writeDeadLock(dead);
      File('${dead.path}/full.dill').writeAsBytesSync([1, 2, 3]);
      await sweepWorkerScratch(parent, exemptName: 'incr_fkc_mine');
      expect(dead.existsSync(), isFalse);
    });

    test('keeps a live scratch held by a separate process', () async {
      final live = Directory('${parent.path}/incr_fkc_live0001')..createSync();
      final lockPath = '${live.path}/$incrFkcLockFileName';
      File(lockPath).writeAsStringSync('');
      File('${live.path}/keep.txt').writeAsStringSync('keep');
      final LockHolder holder = await LockHolder.start(
        _writeHolderScript(parent),
        lockPath,
      );
      addTearDown(holder.kill);
      // A dead sibling next to it proves the sweep really ran.
      final dead = Directory('${parent.path}/incr_fkc_dead0002')..createSync();
      _writeDeadLock(dead);
      await sweepWorkerScratch(parent, exemptName: 'incr_fkc_mine');
      expect(File('${live.path}/keep.txt').readAsStringSync(), 'keep');
      expect(dead.existsSync(), isFalse);
    });

    test('reclaims the scratch of a SIGKILLed lock holder', () async {
      final dead = Directory('${parent.path}/incr_fkc_sigkill')..createSync();
      final lockPath = '${dead.path}/$incrFkcLockFileName';
      File(lockPath).writeAsStringSync('');
      File('${dead.path}/full.dill').writeAsBytesSync([1]);
      final LockHolder holder = await LockHolder.start(
        _writeHolderScript(parent),
        lockPath,
      );
      // SIGKILL drops the kernel lock with the process: no graceful word.
      holder.process.kill(ProcessSignal.sigkill);
      await holder.process.exitCode.timeout(const Duration(seconds: 30));
      await sweepWorkerScratch(parent, exemptName: 'incr_fkc_mine');
      expect(dead.existsSync(), isFalse);
    });

    test('keeps a sibling holding only a temporary claim', () async {
      final young = Directory('${parent.path}/incr_fkc_young')..createSync();
      final claimPath = '${young.path}/$incrFkcClaimFileName';
      File(claimPath).writeAsStringSync('');
      File('${young.path}/keep.txt').writeAsStringSync('keep');
      // A newborn mid-claim: the claim file is locked, but `lock` is not
      // published yet, so the sweep must keep the directory.
      final LockHolder holder = await LockHolder.start(
        _writeHolderScript(parent),
        claimPath,
      );
      addTearDown(holder.kill);
      await sweepWorkerScratch(parent, exemptName: 'incr_fkc_mine');
      expect(File('${young.path}/keep.txt').readAsStringSync(), 'keep');
      expect(
        File('${young.path}/$incrFkcLockFileName').existsSync(),
        isFalse,
      );
    });

    test('a kept lock is untouched by the sweep', () async {
      final live = Directory('${parent.path}/incr_fkc_kept0001')..createSync();
      final lockPath = '${live.path}/$incrFkcLockFileName';
      File(lockPath).writeAsStringSync('owner');
      final LockHolder holder = await LockHolder.start(
        _writeHolderScript(parent),
        lockPath,
      );
      addTearDown(holder.kill);
      final FileStat before = File(lockPath).statSync();
      final Uint8List bytes = File(lockPath).readAsBytesSync();
      await sweepWorkerScratch(parent, exemptName: 'incr_fkc_mine');
      final FileStat after = File(lockPath).statSync();
      // Read-only probing leaves bytes, size and mtime identical.
      expect(File(lockPath).readAsBytesSync(), bytes);
      expect(after.size, before.size);
      expect(after.modified, before.modified);
    });

    test('a sweep creates no file where the lock is missing', () async {
      final bare = Directory('${parent.path}/incr_fkc_bare')..createSync();
      File('${bare.path}/keep.txt').writeAsStringSync('keep');
      Set<String> names(Directory dir) => {
        for (final e in dir.listSync())
          e.path.split(Platform.pathSeparator).last,
      };
      final Set<String> before = names(bare);
      await sweepWorkerScratch(parent, exemptName: 'incr_fkc_mine');
      // A creating open would publish a lock file here; the read-only
      // probe must leave the directory exactly as it found it.
      expect(names(bare), before);
      expect(
        File('${bare.path}/$incrFkcLockFileName').existsSync(),
        isFalse,
      );
    });

    test('a claimed lock refuses a shared lock from another process', () async {
      final dir = Directory('${parent.path}/incr_fkc_owned')..createSync();
      final ScratchLock lock = await lockWorkerScratch(dir);
      final lockFile = File('${dir.path}/$incrFkcLockFileName');
      // The claim is published atomically: `lock` exists, locked, with no
      // temporary claim left behind.
      expect(lockFile.existsSync(), isTrue);
      expect(
        File('${dir.path}/$incrFkcClaimFileName').existsSync(),
        isFalse,
      );
      final String probe = _writeScript(
        parent,
        'shared_probe.dart',
        _sharedProbeSource,
      );
      expect(await _sharedVerdict(probe, lockFile.path), 'held');
      await lock.close();
      expect(await _sharedVerdict(probe, lockFile.path), 'free');
    });

    test(
      'a sweep over live siblings spawns no process and stays quick',
      () async {
        if (!_canListChildren()) {
          markTestSkipped('this test needs /proc');
        }
        const holders = 4;
        final killers = <Future<void> Function()>[];
        for (var i = 0; i < holders; i++) {
          final dir = Directory('${parent.path}/incr_fkc_live$i')..createSync();
          final lockPath = '${dir.path}/$incrFkcLockFileName';
          File(lockPath).writeAsStringSync('');
          File('${dir.path}/keep.txt').writeAsStringSync('keep');
          killers.add(
            (await LockHolder.start(
              _writeHolderScript(parent),
              lockPath,
            )).kill,
          );
        }
        addTearDown(() async {
          for (final kill in killers) {
            await kill();
          }
        });
        // The holders are children already; the in-process sweep must add
        // none, and lock attempts that fail at once stay far under a
        // process-spawn budget.
        final Set<String> before = _childPids();
        final watch = Stopwatch()..start();
        await sweepWorkerScratch(parent, exemptName: 'incr_fkc_mine');
        watch.stop();
        expect(_childPids(), before);
        expect(
          watch.elapsed,
          lessThan(const Duration(seconds: 5)),
          reason: 'the sweep took ${watch.elapsed} over $holders live siblings',
        );
        for (var i = 0; i < holders; i++) {
          expect(
            File('${parent.path}/incr_fkc_live$i/keep.txt').existsSync(),
            isTrue,
          );
        }
      },
    );

    test('spares the exempt entry even when it looks dead', () async {
      final own = Directory('${parent.path}/incr_fkc_mine')..createSync();
      _writeDeadLock(own);
      await sweepWorkerScratch(parent, exemptName: 'incr_fkc_mine');
      expect(own.existsSync(), isTrue);
    });

    test('spares foreign entries and lock-less scratch', () async {
      final foreign = Directory('${parent.path}/other_stuff')..createSync();
      File('${foreign.path}/keep.txt').writeAsStringSync('keep');
      // A newborn owner has a visible directory but has not claimed its
      // lock yet; a foreign entry may also match the prefix. Neither may
      // be deleted, so lock-less directories are always kept.
      final noClaim = Directory('${parent.path}/incr_fkc_noclaim')
        ..createSync();
      File('${noClaim.path}/full.dill').writeAsBytesSync([9]);
      final loose = File('${parent.path}/incr_fkc_loose')
        ..writeAsStringSync('x');
      final garbage = Directory('${parent.path}/incr_fkc_garbage')
        ..createSync();
      File('${garbage.path}/notes.txt').writeAsStringSync('not a lock');
      await sweepWorkerScratch(parent, exemptName: 'incr_fkc_mine');
      expect(File('${foreign.path}/keep.txt').readAsStringSync(), 'keep');
      expect(File('${noClaim.path}/full.dill').existsSync(), isTrue);
      expect(loose.readAsStringSync(), 'x');
      expect(File('${garbage.path}/notes.txt').existsSync(), isTrue);
    });

    test('keeps a scratch whose lock file cannot be opened', () async {
      // A directory at the lock path cannot be opened as a file, standing
      // in for an unopenable lock file; claiming there must degrade
      // gracefully instead of throwing.
      final stuck = Directory('${parent.path}/incr_fkc_unopenable')
        ..createSync();
      Directory('${stuck.path}/$incrFkcLockFileName').createSync();
      await (await lockWorkerScratch(stuck)).close();
      // A permission-less lock file with no owner behind it cannot be
      // opened for reading either — unless this runs as root, where
      // permissions prove nothing.
      final noperm = Directory('${parent.path}/incr_fkc_noperm')..createSync();
      final nopermLock = File('${noperm.path}/$incrFkcLockFileName')
        ..writeAsStringSync('');
      var unopenable = false;
      if (!Platform.isWindows) {
        addTearDown(() => Process.run('chmod', ['u+rw', nopermLock.path]));
        final ProcessResult chmod = await Process.run('chmod', [
          '000',
          nopermLock.path,
        ]);
        if (chmod.exitCode == 0) {
          try {
            File(nopermLock.path).openSync(mode: FileMode.read).closeSync();
          } on FileSystemException {
            unopenable = true;
          }
        }
      }
      await sweepWorkerScratch(parent, exemptName: 'incr_fkc_mine');
      expect(stuck.existsSync(), isTrue);
      if (unopenable) {
        expect(noperm.existsSync(), isTrue);
        expect(
          File('${noperm.path}/$incrFkcLockFileName').existsSync(),
          isTrue,
        );
      }
    });

    test('an unremovable entry does not fail the sweep', () async {
      if (Platform.isWindows) {
        markTestSkipped('this test needs POSIX permissions');
      }
      final stuck = Directory('${parent.path}/incr_fkc_stuck001')..createSync();
      _writeDeadLock(stuck);
      final inner = Directory('${stuck.path}/key')..createSync();
      File('${inner.path}/full.dill').writeAsBytesSync([1]);
      final ProcessResult chmod = await Process.run('chmod', [
        'a-w',
        inner.path,
      ]);
      if (chmod.exitCode != 0) {
        markTestSkipped('chmod is unavailable');
      }
      addTearDown(() async {
        await Process.run('chmod', ['u+w', inner.path]);
      });
      final control = File('${parent.path}/control.txt')
        ..writeAsStringSync('c');
      await sweepWorkerScratch(parent, exemptName: 'incr_fkc_mine');
      expect(control.readAsStringSync(), 'c');
    });

    test('a missing temp directory skips the sweep', () async {
      final control = File('${parent.path}/control.txt')
        ..writeAsStringSync('c');
      await sweepWorkerScratch(
        Directory('${parent.path}/no-such-dir'),
        exemptName: 'incr_fkc_mine',
      );
      expect(control.readAsStringSync(), 'c');
    });

    test('a claimed then released lock reads as dead', () async {
      final dir = Directory('${parent.path}/incr_fkc_claimed')..createSync();
      final ScratchLock lock = await lockWorkerScratch(dir);
      expect(File('${dir.path}/$incrFkcLockFileName').existsSync(), isTrue);
      await lock.close();
      await sweepWorkerScratch(parent, exemptName: 'incr_fkc_mine');
      expect(dir.existsSync(), isFalse);
    });
  });

  group('worker lifecycle against the built binary', () {
    late Directory top;
    late Directory tmp;
    late ScratchHarness h;
    final List<DrivenWorker> workers = [];

    Future<DrivenWorker> spawn(String pidFile) {
      return DrivenWorker.start(
        _workerBinary(),
        h.argv(pidFile),
        h.cwd,
        tmp.path,
      ).then((w) {
        workers.add(w);
        return w;
      });
    }

    setUp(() {
      top = Directory.systemTemp.createTempSync('incr_life_test_');
      addTearDown(() => top.deleteSync(recursive: true));
      tmp = Directory('${top.path}/tmp')..createSync();
      h = ScratchHarness(Directory('${top.path}/h')..createSync());
      h.writeManifest();
      h.writeCleanSources();
      h.writeFakeServer();
      workers.clear();
    });

    tearDown(() async {
      for (final w in workers) {
        try {
          w.process.kill(ProcessSignal.sigkill);
        } on ProcessException {
          // Already gone; its pipes close the fake down.
        }
        try {
          await w.process.exitCode.timeout(const Duration(seconds: 20));
        } on TimeoutException {
          // Never observed; the test below already failed if so.
        }
      }
    });

    test(
      "a SIGKILLed worker's scratch is reclaimed by the next worker",
      () async {
        final DrivenWorker w1 = await spawn('${h.cwd}/w1.pid');
        Map<String, dynamic> reply = await w1.serve(
          h.argv('${h.cwd}/w1.pid'),
          h.inputs,
          1,
        );
        expect(reply['exitCode'], 0, reason: reply['output']);
        final List<String> before = _scratchNames(tmp);
        expect(before, hasLength(1));
        expect(
          _hasFileBelow(Directory('${tmp.path}/${before.single}'), 'full.dill'),
          isTrue,
        );
        await w1.sigkill();
        expect(
          await _waitGone('${h.cwd}/w1.pid', const Duration(seconds: 20)),
          isTrue,
        );
        final DrivenWorker w2 = await spawn('${h.cwd}/w2.pid');
        reply = await w2.serve(h.argv('${h.cwd}/w2.pid'), h.inputs, 2);
        expect(reply['exitCode'], 0, reason: reply['output']);
        final List<String> after = _scratchNames(tmp);
        expect(after, hasLength(1));
        expect(after.single, isNot(before.single));
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      "a live worker's scratch survives while a dead one's is reclaimed",
      () async {
        final DrivenWorker w1 = await spawn('${h.cwd}/w1.pid');
        Map<String, dynamic> reply = await w1.serve(
          h.argv('${h.cwd}/w1.pid'),
          h.inputs,
          1,
        );
        expect(reply['exitCode'], 0, reason: reply['output']);
        final String w1dir = _scratchNames(tmp).single;
        final DrivenWorker w3 = await spawn('${h.cwd}/w3.pid');
        reply = await w3.serve(h.argv('${h.cwd}/w3.pid'), h.inputs, 1);
        expect(reply['exitCode'], 0, reason: reply['output']);
        final String w3dir = _scratchNames(tmp).firstWhere((n) => n != w1dir);
        await w3.sigkill();
        expect(
          await _waitGone('${h.cwd}/w3.pid', const Duration(seconds: 20)),
          isTrue,
        );
        final DrivenWorker w2 = await spawn('${h.cwd}/w2.pid');
        reply = await w2.serve(h.argv('${h.cwd}/w2.pid'), h.inputs, 2);
        expect(reply['exitCode'], 0, reason: reply['output']);
        final List<String> after = _scratchNames(tmp);
        expect(after, contains(w1dir));
        expect(after, isNot(contains(w3dir)));
        reply = await w1.serve(h.argv('${h.cwd}/w1.pid'), h.inputs, 9);
        expect(reply['exitCode'], 0, reason: reply['output']);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'an unremovable entry does not stop a worker',
      () async {
        final stuck = Directory('${tmp.path}/incr_fkc_stuck777')..createSync();
        addTearDown(() async {
          if (!Platform.isWindows) {
            await Process.run('chmod', ['-R', 'u+w', stuck.path]);
          }
        });
        // Unlocked: the starting worker's probe reports dead, the delete
        // fails, and the start still succeeds.
        _writeDeadLock(stuck);
        final inner = Directory('${stuck.path}/key')..createSync();
        File('${inner.path}/full.dill').writeAsBytesSync([1]);
        if (!Platform.isWindows) {
          await Process.run('chmod', ['a-w', inner.path]);
        }
        final DrivenWorker w = await spawn('${h.cwd}/w.pid');
        final Map<String, dynamic> reply = await w.serve(
          h.argv('${h.cwd}/w.pid'),
          h.inputs,
          1,
        );
        expect(reply['exitCode'], 0, reason: reply['output']);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'a lock-less orphan survives a worker start',
      () async {
        // No lock file: a newborn that has not claimed yet, or a foreign
        // entry. The starting worker keeps it and still serves.
        final orphan = Directory('${tmp.path}/incr_fkc_orphan999')
          ..createSync();
        File('${orphan.path}/full.dill').writeAsBytesSync([1, 2, 3]);
        final DrivenWorker w = await spawn('${h.cwd}/w.pid');
        final Map<String, dynamic> reply = await w.serve(
          h.argv('${h.cwd}/w.pid'),
          h.inputs,
          1,
        );
        expect(reply['exitCode'], 0, reason: reply['output']);
        expect(File('${orphan.path}/full.dill').existsSync(), isTrue);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'foreign temp entries survive a worker start',
      () async {
        final foreign = Directory('${tmp.path}/other_stuff')..createSync();
        File('${foreign.path}/keep.txt').writeAsStringSync('keep');
        final loose = File('${tmp.path}/incr_fkc_loose')
          ..writeAsStringSync('x');
        final DrivenWorker w = await spawn('${h.cwd}/w.pid');
        final Map<String, dynamic> reply = await w.serve(
          h.argv('${h.cwd}/w.pid'),
          h.inputs,
          1,
        );
        expect(reply['exitCode'], 0, reason: reply['output']);
        expect(File('${foreign.path}/keep.txt').readAsStringSync(), 'keep');
        expect(loose.readAsStringSync(), 'x');
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'a served worker exits promptly on stdin EOF',
      () async {
        final DrivenWorker w = await spawn('${h.cwd}/w.pid');
        final Map<String, dynamic> reply = await w.serve(
          h.argv('${h.cwd}/w.pid'),
          h.inputs,
          1,
        );
        expect(reply['exitCode'], 0, reason: reply['output']);
        final watch = Stopwatch()..start();
        final int code = await w.eofAndWait(const Duration(seconds: 20));
        watch.stop();
        expect(code, 0);
        expect(
          watch.elapsed,
          lessThan(const Duration(seconds: 15)),
          reason: 'the worker took ${watch.elapsed} to exit after stdin EOF',
        );
        expect(
          await _waitGone('${h.cwd}/w.pid', const Duration(seconds: 10)),
          isTrue,
          reason: 'a frontend_server process was left running',
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
