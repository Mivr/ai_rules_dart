/// What [NativeLibsWatch] answers, which is the only thing standing between a
/// rebuilt native library and an increment injected over machine code that cannot
/// serve it.
import 'dart:io';

import 'package:flutter_bazel_dev_tool/native_libs_watch.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('nlw_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File file(String name, List<int> bytes) =>
      File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  test('current while the build writes the same bytes', () async {
    final File lib = file('liba.dylib', [1, 2, 3]);
    final NativeLibsWatch watch = await NativeLibsWatch.of({
      lib.path: const [],
    });

    expect(await watch.verdict(), isA<NativeLibsCurrent>());
    // A rebuild that re-ran the native action and produced identical bytes —
    // measured in this repo: editing `a * b` to `a * b + 0` advances the output's
    // mtime, and a `-c dbg` compile can still emit the same image. Reporting it
    // would withhold a reload that was perfectly safe.
    lib.writeAsBytesSync([1, 2, 3]);
    expect(await watch.verdict(), isA<NativeLibsCurrent>());
  });

  test('a library bazel did not rewrite is never read', () async {
    // The fast path, pinned by defeating it. A `stat` costs 33µs and hashing a
    // 20MB debug library costs 126ms (both measured), so a command reads only
    // the files whose stamp moved or whose stamp cannot prove the bytes
    // unchanged. Here the bytes change while the stamp is put back exactly as
    // it was: the watch answers current without reading, which is the
    // documented limit of the prefilter and the reason it is safe — bazel
    // advances an output's mtime whenever it re-runs the action that writes it,
    // so the case constructed here is one no build produces.
    //
    // The file's mtime is set into the past, past the racy window, before the
    // baseline is read: only then does a matching stamp prove the bytes
    // unchanged. A file written in the baseline's own tick stays on the read
    // path instead (see the same-tick group below).
    final File lib = file('liba.dylib', [1, 2, 3]);
    final DateTime past = DateTime.now().subtract(const Duration(seconds: 10));
    lib.setLastModifiedSync(past);
    final FileStat stamp = lib.statSync();
    final NativeLibsWatch watch = await NativeLibsWatch.of({
      lib.path: const [],
    });

    lib.writeAsBytesSync([9, 9, 9]);
    lib.setLastModifiedSync(stamp.modified);
    expect(await watch.verdict(), isA<NativeLibsCurrent>());

    // And once the mtime moves the way a real rebuild moves it, the content is
    // read and the change is reported.
    lib.setLastModifiedSync(stamp.modified.add(const Duration(seconds: 1)));
    expect(await watch.verdict(), isA<NativeLibsUnverifiable>());
  });

  group('a same-size rewrite in the baseline tick', () {
    // What a coarse filesystem clock leaves: the rewrite lands in the same tick
    // the baseline was read in, so size and mtime come back exactly as they
    // were and the stamp matches. The watch must read the content anyway —
    // the file's mtime is not older than its last read by more than the window
    // — and report the changed bytes.
    test('of a library is reported', () async {
      final File lib = file('liba.dylib', [1, 2, 3]);
      final FileStat stamp = lib.statSync();
      final NativeLibsWatch watch = await NativeLibsWatch.of({
        lib.path: const [],
      });

      lib.writeAsBytesSync([4, 5, 6]);
      lib.setLastModifiedSync(stamp.modified);
      expect(await watch.verdict(), isA<NativeLibsUnverifiable>());
    });

    test('of a contract is reported', () async {
      final File bridge = file('libbridge.dylib', [1]);
      final File contract = file('codegen.ir', [10, 11]);
      final FileStat stamp = contract.statSync();
      final NativeLibsWatch watch = await NativeLibsWatch.of({
        bridge.path: [contract.path],
      });

      contract.writeAsBytesSync([12, 13]);
      contract.setLastModifiedSync(stamp.modified);
      expect(await watch.verdict(), isA<NativeBindingsMoved>());
    });

    test('of a source is reported', () async {
      final File lib = file('libbridge.dylib', [1]);
      final File contract = file('bridge.h', [10]);
      final File source = file('bridge.c', [20, 21]);
      final FileStat stamp = source.statSync();
      final NativeLibsWatch watch = await NativeLibsWatch.of(
        {
          lib.path: [contract.path],
        },
        sources: {
          lib.path: [source.path],
        },
      );

      source.writeAsBytesSync([22, 23]);
      source.setLastModifiedSync(stamp.modified);
      expect(await watch.verdict(), isA<NativeCodeStale>());
    });
  });

  test('a confirming read beyond the window returns to stat-only', () async {
    final File lib = file('liba.dylib', [1, 2, 3]);
    final FileStat stamp = lib.statSync();
    final NativeLibsWatch watch = await NativeLibsWatch.of({
      lib.path: const [],
    });

    // The baseline tick is racy, so this verdict reads the content and
    // confirms it unchanged — and stays on the read path, since the file was
    // written moments ago.
    expect(await watch.verdict(), isA<NativeLibsCurrent>());

    // The only sleep in this file: the clock must advance past the window so
    // the next confirming read finds the file's mtime older than its own read
    // by more than the window.
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(await watch.verdict(), isA<NativeLibsCurrent>());

    // Now the watch is back on the stat-only path: changed bytes under a
    // matching stamp go unread, the way files written before the window always
    // have. A verdict that still read would report the change below.
    lib.writeAsBytesSync([4, 5, 6]);
    lib.setLastModifiedSync(stamp.modified);
    expect(await watch.verdict(), isA<NativeLibsCurrent>());
  });

  group('a library with no declared contract', () {
    test(
      'withholds, because nothing says whether its bindings moved',
      () async {
        final File lib = file('libsqlite3.dylib', [1]);
        final NativeLibsWatch watch = await NativeLibsWatch.of({
          lib.path: const [],
        });

        lib.writeAsBytesSync([2]);
        expect(
          await watch.verdict(),
          isA<NativeLibsUnverifiable>().having((v) => v.libs, 'libs', [
            lib.path,
          ]),
        );
      },
    );

    test('withholds even beside a library whose contract held', () async {
      // Unknown beats known-safe: one library nothing describes is enough to
      // make the whole increment unsafe, however many of its neighbours declared
      // a contract.
      final File bridge = file('libbridge.dylib', [1]);
      final File contract = file('codegen.ir', [10]);
      final File other = file('libother.dylib', [2]);
      final NativeLibsWatch watch = await NativeLibsWatch.of({
        bridge.path: [contract.path],
        other.path: const [],
      });

      bridge.writeAsBytesSync([3]);
      other.writeAsBytesSync([4]);
      expect(
        await watch.verdict(),
        isA<NativeLibsUnverifiable>().having((v) => v.libs, 'libs', [
          other.path,
        ]),
      );
    });
  });

  group('a library with a declared contract', () {
    test('delivers when only its code moved', () async {
      final File bridge = file('libbridge.dylib', [1, 2, 3]);
      final File contract = file('codegen.ir', [10, 11]);
      final NativeLibsWatch watch = await NativeLibsWatch.of({
        bridge.path: [contract.path],
      });

      // The body-only edit: the library is rebuilt, the interface it was
      // generated from is byte-identical, so the bindings about to be injected
      // are ones the loaded image can still serve.
      bridge.writeAsBytesSync([1, 2, 4]);
      expect(
        await watch.verdict(),
        isA<NativeCodeStale>().having((v) => v.libs, 'libs', [bridge.path]),
      );
    });

    test('withholds when the contract moved with it', () async {
      final File bridge = file('libbridge.dylib', [1]);
      final File contract = file('codegen.ir', [10]);
      final NativeLibsWatch watch = await NativeLibsWatch.of({
        bridge.path: [contract.path],
      });

      bridge.writeAsBytesSync([2]);
      contract.writeAsBytesSync([11]);
      final NativeLibsVerdict verdict = await watch.verdict();
      expect(
        verdict,
        isA<NativeBindingsMoved>()
            .having((v) => v.libs, 'libs', [bridge.path])
            .having((v) => v.contracts, 'contracts', [contract.path]),
      );
    });

    test('withholds on a contract that moved without its library', () async {
      // Not a shape one build produces — the interface and the library come from
      // the same source — so the answer is the safe one rather than a special
      // case. Naming the library rather than only the contract is what makes the
      // reply about something the reader recognises.
      final File bridge = file('libbridge.dylib', [1]);
      final File contract = file('codegen.ir', [10]);
      final NativeLibsWatch watch = await NativeLibsWatch.of({
        bridge.path: [contract.path],
      });

      contract.writeAsBytesSync([11]);
      expect(
        await watch.verdict(),
        isA<NativeBindingsMoved>().having((v) => v.libs, 'libs', [bridge.path]),
      );
    });
  });

  test('keeps saying so until the process is replaced', () async {
    final File lib = file('liba.dylib', [1]);
    final NativeLibsWatch watch = await NativeLibsWatch.of({
      lib.path: const [],
    });
    lib.writeAsBytesSync([2]);

    expect(await watch.verdict(), isA<NativeLibsUnverifiable>());
    // Asked again with nothing changed in between: the app is still running the
    // old image, so the answer is still the same. A watch that advanced its
    // baseline on merely *reporting* a change would let the next reload inject
    // over stale machine code — the build has moved on, the process has not.
    expect(await watch.verdict(), isA<NativeLibsUnverifiable>());
  });

  test('a relaunch is what clears it', () async {
    final File bridge = file('libbridge.dylib', [1]);
    final File contract = file('codegen.ir', [10]);
    final NativeLibsWatch watch = await NativeLibsWatch.of({
      bridge.path: [contract.path],
    });
    bridge.writeAsBytesSync([2]);
    contract.writeAsBytesSync([11]);
    expect(await watch.verdict(), isA<NativeBindingsMoved>());

    // The process was replaced, so it launched with the files on disk now.
    await watch.markLive();
    expect(await watch.verdict(), isA<NativeLibsCurrent>());

    // And the next change is caught against the new baseline, not the old one.
    bridge.writeAsBytesSync([3]);
    expect(await watch.verdict(), isA<NativeCodeStale>());
  });

  group('an app whose reload runs no build', () {
    // The silent shape this closes: nothing rebuilds the library between
    // reloads, so comparing libraries alone answered "current" to a native
    // edit and the increment went in over the machine code the app launched
    // with.
    test('reports the libraries when a native source moved', () async {
      final File lib = file('libbridge.dylib', [1]);
      final File contract = file('bridge.h', [10]);
      final File source = file('bridge.c', [20]);
      final NativeLibsWatch watch = await NativeLibsWatch.of(
        {
          lib.path: [contract.path],
        },
        sources: {
          lib.path: [source.path],
        },
      );

      expect(await watch.verdict(), isA<NativeLibsCurrent>());
      source.writeAsBytesSync([21]);
      expect(
        await watch.verdict(),
        isA<NativeCodeStale>().having((v) => v.libs, 'libs', [lib.path]),
        reason: 'the library is not rebuilt, so only its source can say this',
      );
      // And keeps saying it: only a new process, or a patch, changes what the
      // app is running.
      expect(await watch.verdict(), isA<NativeCodeStale>());

      await watch.markLive();
      expect(await watch.verdict(), isA<NativeLibsCurrent>());
    });

    test('a source rewritten with the same bytes is not a change', () async {
      final File lib = file('libbridge.dylib', [1]);
      final File source = file('bridge.c', [20]);
      final NativeLibsWatch watch = await NativeLibsWatch.of(
        {
          lib.path: const [],
        },
        sources: {
          lib.path: [source.path],
        },
      );

      source.writeAsBytesSync([20]);
      expect(await watch.verdict(), isA<NativeLibsCurrent>());
    });

    test('answers for the library whose source moved, and no other', () async {
      final File patched = file('libbridge.dylib', [1]);
      final File other = file('libother.dylib', [2]);
      final File bridgeSource = file('bridge.c', [20]);
      final File otherSource = file('other.c', [30]);
      final NativeLibsWatch watch = await NativeLibsWatch.of(
        {
          patched.path: const [],
          other.path: const [],
        },
        sources: {
          patched.path: [bridgeSource.path],
          other.path: [otherSource.path],
        },
      );

      bridgeSource.writeAsBytesSync([21]);
      expect(
        await watch.verdict(),
        isA<NativeLibsUnverifiable>().having((v) => v.libs, 'libs', [
          patched.path,
        ]),
        reason: 'an edit to one library says nothing about the other',
      );

      // A patch delivered that library's code, so its source goes live with it:
      // the app runs what the source says now.
      await watch.markPatched({'libbridge.dylib'});
      expect(await watch.verdict(), isA<NativeLibsCurrent>());
    });
  });

  test(
    'a native hot patch clears the library it delivered, and only that',
    () async {
      final File bridge = file('libbridge.dylib', [1]);
      final File other = file('libother.dylib', [5]);
      final File contract = file('codegen.ir', [10]);
      final NativeLibsWatch watch = await NativeLibsWatch.of({
        bridge.path: [contract.path],
        other.path: [contract.path],
      });
      bridge.writeAsBytesSync([2]);
      other.writeAsBytesSync([6]);

      // A patch put libbridge's new code into the running process; libother
      // still runs what it launched with.
      await watch.markPatched({'libbridge.dylib'});
      expect(
        await watch.verdict(),
        isA<NativeCodeStale>().having((v) => v.libs, 'libs', [other.path]),
      );
    },
  );

  test('a native hot patch clears the contract it was asked about', () async {
    final File bridge = file('libbridge.dylib', [1]);
    final File contract = file('codegen.ir', [10]);
    final NativeLibsWatch watch = await NativeLibsWatch.of({
      bridge.path: [contract.path],
    });
    // The shape a bridged function being added makes: the library moved and so
    // did what its bindings are generated from. The pipeline asks the patch
    // builder about exactly this, and only calls markPatched once the builder
    // has said it served it.
    bridge.writeAsBytesSync([2]);
    contract.writeAsBytesSync([11]);
    expect(await watch.verdict(), isA<NativeBindingsMoved>());

    await watch.markPatched({'libbridge.dylib'});
    // Not still `NativeBindingsMoved`: the next reload reads the same moved
    // contract bytes, and withholding over an image that caught up an edit ago
    // would take the rest of the run with it.
    expect(await watch.verdict(), isA<NativeLibsCurrent>());
  });

  test('a declared file the build never wrote is loud', () async {
    final File lib = file('liba.dylib', [1]);
    final NativeLibsWatch watch = await NativeLibsWatch.of({
      lib.path: const [],
    });
    lib.deleteSync();
    // Not "current", which would let an increment land on stale machine code,
    // and not "moved", which would blame the app's source for a broken build.
    // The build declared this path and did not write it.
    await expectLater(watch.verdict(), throwsA(isA<FileSystemException>()));
  });
}
