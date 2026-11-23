// Tagged `runfiles`: the worker imports `kernel_filter.dart`, which imports
// `package:rules_dart_guard`, supplied via the `@rules_dart//dart/guard`
// dep its `dart_test` declares. A bare `dart test` resolves only this
// package's pubspec, where that import does not exist.
// Coverage comes from //flutter/private/tools:incr_fkc_worker_test.
@Tags(['runfiles'])
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../incr_fkc_server.dart';
import '../incr_fkc_worker.dart';
import '../kernel_filter.dart';
import '../sha256.dart';
import 'incr_fkc_test_support.dart';

/// A session factory whose every server plays [script] and is recorded in
/// [sessions].
SessionFactory scripted(
  List<FakeSession> sessions,
  List<CompileResult> script,
) => (fs, full, inc, cwd, {devIncremental = false}) async {
  final s = FakeSession(
    fullDill: full,
    dillBytes: utf8.encode('dill-bytes'),
    script: script,
  );
  sessions.add(s);
  return s;
};

/// A compile result with [errors] and the compiler's [depLines].
CompileResult compiled(List<String> depLines, {int errors = 0}) => (
  errors: errors,
  diagnostics: errors == 0 ? const [] : ['boom'],
  depLines: depLines,
);

/// Asserts [r] failed with exit code 1 and its output contains [text].
void expectRefused(IncrResult r, String text) {
  expect(r.exitCode, 1);
  expect(r.output, contains(text));
}

/// Asserts [r] succeeded, showing its output otherwise, and returns it.
IncrResult expectOk(IncrResult r) {
  expect(r.exitCode, 0, reason: r.output);
  return r;
}

/// Writes [content] to `lib/[name]` and its staged twin.
void writeBoth(Harness h, String name, String content) {
  h.write('lib/$name', content);
  h.write('stage/lib/$name', content);
}

void main() {
  group('configurationKey', () {
    List<String> fs(String out) => [
      'vm',
      '--output-dill',
      out,
      '--enable-asserts',
      'entry.dart',
    ];

    test('ignores the output path but nothing else', () {
      expect(
        configurationKey(fs('a.dill'), sha256Hex),
        configurationKey(fs('b.dill'), sha256Hex),
      );
      expect(
        configurationKey(fs('a.dill'), sha256Hex),
        isNot(configurationKey([...fs('a.dill'), '--x'], sha256Hex)),
      );
    });
  });

  group('incrementalFlagIndex', () {
    test('inserts after the snapshot, or after the script without one', () {
      expect(
        incrementalFlagIndex(['vm', '--x=1', 'fs.snapshot', '--y', 'e.dart']),
        2,
      );
      expect(
        incrementalFlagIndex(['vm', 'script.dart', '--y', 'e.dart']),
        1,
      );
    });
  });

  group('kernelMountContract', () {
    // Goal G pins the mount order (the stage, then the exec root, then the
    // filesystem_roots): a path under the stage maps through the stage even
    // with the exec root mounted.
    test('the stage wins over the exec root for a staged path', () {
      expect(
        uriOfStaged('gen.stage/gen/foo.dart', ['gen.stage', '.', 'sdk-root']),
        'org-dartlang-app:///gen/foo.dart',
      );
      expect(mountsExecRoot(['gen.stage', '.', 'sdk-root']), isTrue);
    });
  });

  group('foldDepLines', () {
    test('additions join and removals leave the cumulative set', () {
      final current = <String>{};
      foldDepLines(current, ['+file:///a.dart', '+file:///b.dart']);
      expect(current, {'file:///a.dart', 'file:///b.dart'});
      foldDepLines(current, ['-file:///a.dart', '+file:///c.dart']);
      expect(current, {'file:///b.dart', 'file:///c.dart'});
    });
  });

  group('GuardCache', () {
    // Records each scan's subset; a file's verdict is one error per `bad`
    // marker in [text] and, for `needs:<path>` text, one error when that path
    // is not in the declared set — the declared-set dependence of the guard.
    late List<List<String>> scans;
    late Map<String, String> text;

    GuardCache newCache() {
      scans = [];
      return GuardCache(
        scan: (subset, declared, roots) {
          scans.add(List.of(subset));
          return {
            for (final s in subset)
              s: [
                if (text[s]!.startsWith('needs:') &&
                    !declared.contains(text[s]!.substring(6)))
                  'e:$s',
                if (text[s]!.contains('bad')) 'bad:$s:${roots.join(',')}',
              ],
          };
        },
      );
    }

    Map<String, String?> digests() => {
      for (final e in text.entries) e.key: 'h-${e.value}',
    };

    List<String> run(GuardCache c, [List<String> roots = const ['r']]) =>
        c.check(text.keys.toList(), roots, digests());

    setUp(() => text = {'a': 'ok', 'b': 'ok', 'c': 'ok'});

    test('reuses the cached result while nothing changed', () {
      final GuardCache cache = newCache();
      expect(run(cache), isEmpty);
      expect(run(cache), isEmpty);
      expect(scans, hasLength(1));
    });

    test('a warm edit rescans only the changed source', () {
      final GuardCache cache = newCache();
      run(cache);
      text['b'] = 'bad';
      expect(run(cache), ['bad:b:r']);
      expect(scans.last, ['b']);
      text['d'] = 'ok';
      run(cache);
      expect(
        scans.last.toSet(),
        {'a', 'b', 'c', 'd'},
        reason: 'a new source changes the declared set',
      );
      text['d'] = 'bad';
      run(cache);
      expect(scans.last, ['d']);
    });

    test('a cold scan seeds the verdicts the first warm edit reuses', () {
      final GuardCache cache = newCache();
      text['a'] = 'bad';
      expect(run(cache), ['bad:a:r']);
      expect(scans.single.toSet(), {'a', 'b', 'c'});
      text['c'] = 'ok2';
      expect(run(cache), ['bad:a:r']);
      expect(scans, hasLength(2));
      expect(scans.last, ['c']);
    });

    test("errors come back in a full scan's order", () {
      text = {'z': 'bad', 'a': 'bad', 'm': 'bad'};
      final GuardCache cache = newCache();
      expect(run(cache), ['bad:a:r', 'bad:m:r', 'bad:z:r']);
      text['m'] = 'bad2';
      expect(run(cache), ['bad:a:r', 'bad:m:r', 'bad:z:r']);
    });

    test('a changed declared set rescans everything, both ways', () {
      text = {'a': 'needs:b', 'b': 'ok'};
      final GuardCache cache = newCache();
      expect(run(cache), isEmpty);
      text.remove('b');
      expect(run(cache), ['e:a']);
      expect(scans.last, ['a']);
      text['b'] = 'ok';
      expect(run(cache), isEmpty);
      expect(scans.last.toSet(), {'a', 'b'});
    });

    test('a source turning missing or present changes the declared set', () {
      text = {'a': 'needs:b', 'b': 'ok'};
      final GuardCache cache = newCache();
      run(cache);
      final Map<String, String?> hashes = digests()..['b'] = null;
      expect(cache.check(['a', 'b'], ['r'], hashes), ['e:a']);
      expect(cache.check(['a', 'b'], ['r'], digests()), isEmpty);
    });

    test('changed roots rescan every source', () {
      final GuardCache cache = newCache();
      run(cache);
      expect(scans, hasLength(1));
      run(cache, ['other']);
      expect(scans, hasLength(2));
      expect(scans.last.toSet(), {'a', 'b', 'c'});
    });

    test('a digest changed back is never served a stale verdict', () {
      text = {'a': 'needs:b', 'b': 'ok'};
      final GuardCache cache = newCache();
      run(cache);
      text.remove('b');
      run(cache);
      text['b'] = 'ok2';
      run(cache);
      expect(scans, hasLength(3));
      text['b'] = 'ok';
      expect(run(cache), isEmpty);
      text.remove('b');
      expect(run(cache), ['e:a']);
    });

    test('a cache that never rescans a changed source is caught', () {
      // The same warm-edit scenario against the real cache and a mutant that
      // returns its first result forever: the scenario's expectation holds
      // for the first and fails for the second.
      List<String> warmEdit(
        List<String> Function(List<String>, List<String>, Map<String, String?>)
        check,
      ) {
        text = {'a': 'ok', 'b': 'ok'};
        check(text.keys.toList(), ['r'], digests());
        text['b'] = 'bad';
        return check(text.keys.toList(), ['r'], digests());
      }

      expect(warmEdit(newCache().check), ['bad:b:r']);
      List<String>? first;
      List<String> neverRescans(
        List<String> sources,
        List<String> roots,
        Map<String, String?> hashes,
      ) => first ??= newCache().check(sources, roots, hashes);
      expect(warmEdit(neverRescans), isNot(['bad:b:r']));
    });
  });

  group('normalizeRequestDigest', () {
    final String hex = sha256Hex(utf8.encode('x'));
    String b64(String text) => base64.encode(utf8.encode(text));
    final List<int> raw = sha256(utf8.encode('x'));

    test('accepts the forms Bazel and the tests send', () {
      final List<String> forms = [
        hex,
        hex.toUpperCase(),
        b64(hex),
        base64.encode(raw),
      ];
      for (final String form in [...forms, b64(hex.toUpperCase())]) {
        expect(normalizeRequestDigest(form), hex, reason: form);
      }
    });

    test('rejects everything else', () {
      for (final String? bad in [
        null,
        '',
        'not-a-digest',
        hex.substring(1),
        b64('z' * 64),
        b64(hex.substring(2)),
        base64.encode(List.filled(48, 7)),
      ]) {
        expect(normalizeRequestDigest(bad), isNull, reason: '$bad');
      }
    });
  });

  group('handleRequest two-phase state machine', () {
    late Harness h;
    late List<FakeSession> sessions;
    late IncrWorker worker;
    late Directory savedCwd;

    SessionFactory factoryFor(List<CompileResult> Function() scriptOf) {
      // One script shared by every server: a restarted server continues the
      // same phase order, so multi-request tests stage cold, warm and error
      // phases in order.
      final Queue<CompileResult> shared = Queue.of(scriptOf());
      return (fs, full, inc, cwd, {devIncremental = false}) async {
        final s = FakeSession(
          fullDill: full,
          dillBytes: utf8.encode('dill-bytes'),
          shared: shared,
        );
        sessions.add(s);
        return s;
      };
    }

    setUp(() {
      savedCwd = Directory.current;
      h = Harness(Directory.systemTemp.createTempSync('incr_worker_'));
      // The shared read-set check resolves `+file://` lines against the
      // process working directory, which is the exec root in production.
      Directory.current = h.cwd;
      addTearDown(() => h.dir.deleteSync(recursive: true));
      h.writeManifest();
      h.writeCleanSources();
      sessions = [];
    });

    tearDown(() async {
      Directory.current = savedCwd.path;
      await worker.closeAll();
    });

    test(
      'the marker reaches the session factory as a mode, not argv',
      () async {
        final modes = <bool>[];
        final SessionFactory inner = factoryFor(() => [h.ok(), h.ok()]);
        worker = IncrWorker(
          cwd: h.cwd,
          tempParent: h.cwd,
          sessions: (fs, full, inc, cwd, {devIncremental = false}) {
            modes.add(devIncremental);
            expect(fs, isNot(contains(devIncrementalSerializationMarker)));
            return inner(fs, full, inc, cwd, devIncremental: devIncremental);
          },
        );
        final IncrResult result = await worker.handleRequest([
          devIncrementalSerializationMarker,
          ...h.argv,
        ], h.inputs);
        expect(result.exitCode, 0, reason: result.output);
        expect(modes, [true]);
      },
    );

    test('cold: compile, accept, then reset plus an empty recompile', () async {
      worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        sessions: factoryFor(() => [h.ok(), h.ok()]),
      );
      final IncrResult result = expectOk(
        await worker.handleRequest(h.argv, h.inputs),
      );
      expect(result.output, isEmpty);
      expect(sessions, hasLength(1));
      expect(sessions.single.commands, [
        'compile package:app/main.dart',
        'accept',
        'reset+recompile package:app/main.dart []',
        'accept',
      ]);
      expect(File('${h.cwd}/out/app.dill').readAsStringSync(), 'dill-bytes');
    });

    test(
      'warm: only staged dart deltas recompile, then the empty reset',
      () async {
        worker = IncrWorker(
          cwd: h.cwd,
          sessions: factoryFor(() => [h.ok(), h.ok(), h.ok(), h.ok()]),
        );
        expectOk(await worker.handleRequest(h.argv, h.inputs));
        writeBoth(h, 'a.dart', 'int get answer => 43;\n');
        expectOk(await worker.handleRequest(h.argv, h.inputs));
        expect(sessions, hasLength(1));
        expect(sessions.single.commands, [
          'compile package:app/main.dart',
          'accept',
          'reset+recompile package:app/main.dart []',
          'accept',
          'recompile package:app/main.dart [org-dartlang-app:///lib/a.dart]',
          'accept',
          'reset+recompile package:app/main.dart []',
          'accept',
        ]);
      },
    );

    test(
      'warm: an in-place-only edit recompiles with no staged twin',
      () async {
        // The mount world: the manifest stages generated files only and the
        // roots mount the stage plus the exec root (`.`), so an edit to a
        // source read in place carries its own URI.
        h.write('gen.stage/gen/foo.dart', 'int get foo => 1;\n');
        h.write(
          'manifest.txt',
          [
            'lib/main.dart',
            'lib/a.dart',
            '# staged',
            'gen.stage/gen/foo.dart',
            '# allowed-reads',
            'pkg_config.json',
            'platform.dill',
            '# filesystem-roots',
            'gen.stage',
            '.',
            '# entrypoint',
            'lib/main.dart',
            '# output',
            'out/app.dill',
          ].join('\n'),
        );
        final reads = [
          '+file://${h.cwd}/lib/main.dart',
          '+file://${h.cwd}/lib/a.dart',
          '+file://${h.cwd}/gen.stage/gen/foo.dart',
          '+file://${h.cwd}/pkg_config.json',
          '+file://${h.cwd}/platform.dill',
        ];
        CompileResult readOk() =>
            (errors: 0, diagnostics: const [], depLines: reads);
        final argv = [
          '--declared-inputs',
          'manifest.txt',
          '--',
          'fake-vm',
          '--output-dill',
          'out/app.dill',
          '--filesystem-root',
          'gen.stage',
          '--filesystem-root',
          '.',
          '--packages',
          'pkg_config.json',
          'package:app/main.dart',
        ];
        final inputs = [
          'manifest.txt',
          'lib/main.dart',
          'lib/a.dart',
          'gen.stage/gen/foo.dart',
          'pkg_config.json',
          'platform.dill',
        ];
        worker = IncrWorker(
          cwd: h.cwd,
          sessions: factoryFor(() => [readOk(), readOk(), readOk(), readOk()]),
        );
        IncrResult result = await worker.handleRequest(argv, inputs);
        expect(result.exitCode, 0, reason: result.output);
        // Only the in-place source changes: there is no staged twin to edit.
        h.write('lib/a.dart', 'int get answer => 43;\n');
        result = await worker.handleRequest(argv, inputs);
        expect(result.exitCode, 0, reason: result.output);
        expect(sessions, hasLength(1));
        expect(sessions.single.commands, [
          'compile package:app/main.dart',
          'accept',
          'reset+recompile package:app/main.dart []',
          'accept',
          'recompile package:app/main.dart [org-dartlang-app:///lib/a.dart]',
          'accept',
          'reset+recompile package:app/main.dart []',
          'accept',
        ]);
      },
    );

    test(
      'each request lands in its own --output-dill, one warm server',
      () async {
        // The harness (and Bazel strategies) give every request a private
        // output path: requests differing only there share the server, and each
        // finished dill lands in the requesting file.
        worker = IncrWorker(
          cwd: h.cwd,
          sessions: factoryFor(() => [h.ok(), h.ok(), h.ok(), h.ok()]),
        );
        IncrResult result = expectOk(
          await worker.handleRequest(h.argv, h.inputs),
        );
        final List<String> argv2 = [
          for (final a in h.argv) a == 'out/app.dill' ? 'out/other.dill' : a,
        ];
        result = await worker.handleRequest(argv2, h.inputs);
        expect(result.exitCode, 0, reason: result.output);
        expect(sessions, hasLength(1));
        expect(File('${h.cwd}/out/app.dill').readAsStringSync(), 'dill-bytes');
        expect(
          File('${h.cwd}/out/other.dill').readAsStringSync(),
          'dill-bytes',
        );
      },
    );

    test('content change with no digest input is still detected', () async {
      // A request that carries no digest for the changed file hashes its
      // contents, so the edit is seen.
      worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        sessions: factoryFor(() => [h.ok(), h.ok(), h.ok(), h.ok()]),
      );
      expectOk(await worker.handleRequest(h.argv, h.inputs));
      writeBoth(h, 'a.dart', '// a comment\nint get answer => 42;\n');
      expectOk(await worker.handleRequest(h.argv, h.inputs));
      expect(
        sessions.single.commands.where((c) => c.contains('lib/a.dart')),
        hasLength(1),
      );
    });

    group('request digests decide the recompile', () {
      const edited = '// a comment\nint get answer => 42;\n';
      final String fake = 'ab' * 32;

      Map<String, String> digestsOf(Harness h) => {
        for (final p in h.inputs)
          p: sha256Hex(File('${h.cwd}/$p').readAsBytesSync()),
      };

      int deltas() => sessions.single.commands
          .where((c) => c.contains('lib/a.dart'))
          .length;

      void edit() {
        writeBoth(h, 'a.dart', edited);
      }

      Future<void> coldWith(Map<String, String> digests) async {
        worker = IncrWorker(
          cwd: h.cwd,
          tempParent: h.cwd,
          sessions: factoryFor(() => [h.ok(), h.ok(), h.ok(), h.ok()]),
        );
        final IncrResult result = await worker.handleRequest(
          h.argv,
          h.inputs,
          digests: digests,
        );
        expect(result.exitCode, 0, reason: result.output);
        expect(deltas(), 0);
      }

      Future<void> warmWith(Map<String, String> digests) async {
        final IncrResult result = await worker.handleRequest(
          h.argv,
          h.inputs,
          digests: digests,
        );
        expect(result.exitCode, 0, reason: result.output);
      }

      test('an unchanged digest with changed contents is no change', () async {
        final Map<String, String> digests = digestsOf(h);
        await coldWith(digests);
        edit();
        await warmWith(digests);
        expect(deltas(), 0);
        expect(
          sessions.single.commands.where((c) => c.startsWith('recompile')),
          ['recompile package:app/main.dart []'],
        );
      });

      test('a changed digest is a change without reading contents', () async {
        final Map<String, String> digests = digestsOf(h);
        await coldWith(digests);
        // Contents stay the same: only the digest says the file changed.
        await warmWith({
          ...digests,
          'lib/a.dart': fake,
          'stage/lib/a.dart': fake,
        });
        expect(deltas(), 1);
        expect(
          sessions.single.commands.where((c) => c.startsWith('recompile')),
          hasLength(1),
        );
      });

      test('a base64 digest is normalised to the stored spelling', () async {
        final Map<String, String> digests = digestsOf(h);
        await coldWith(digests);
        final Map<String, String> b64 = {
          for (final e in digests.entries)
            e.key: base64.encode([
              for (var i = 0; i < 64; i += 2)
                int.parse(e.value.substring(i, i + 2), radix: 16),
            ]),
        };
        await warmWith(b64);
        expect(deltas(), 0);
      });

      Future<Map<String, int>> countReads(Future<void> Function() body) async {
        final reads = <String, int>{};
        await IOOverrides.runZoned(
          body,
          createFile: (path) {
            final File real = Zone.root.run(() => File(path));
            return path.endsWith('.dart') ? CountingFile(real, reads) : real;
          },
        );
        return reads;
      }

      // Bazel 9.x sends the 64 hex characters as `bytes`, which proto3 JSON
      // prints as base64: 88 characters that decode to 64.
      String bazelForm(String hex) => base64.encode(utf8.encode(hex));

      Map<String, String> bazelDigests() => {
        for (final e in digestsOf(h).entries) e.key: bazelForm(e.value),
      };

      test('a Bazel-form digest is trusted until it changes', () async {
        final Map<String, String> digests = bazelDigests();
        await coldWith(digests);
        edit();
        await warmWith(digests);
        expect(deltas(), 0, reason: 'unchanged digest, so no contents read');
        await warmWith({
          ...digests,
          'lib/a.dart': bazelForm(fake),
          'stage/lib/a.dart': bazelForm(fake),
        });
        expect(deltas(), 1);
      });

      for (final bazel in [false, true]) {
        test('a warm request reads a source at most once ($bazel)', () async {
          final Map<String, String> digests = bazel ? bazelDigests() : {};
          await coldWith(digests);
          final Map<String, int> reads = await countReads(
            () => warmWith(digests),
          );
          expect(reads.values, allOf(isNotEmpty, everyElement(1)));
        });
      }

      for (final MapEntry<String, String?> bad in <String, String?>{
        'no digest': null,
        'an empty digest': '',
        'a malformed digest': 'not-a-digest',
        'a short hex digest': 'abcd',
      }.entries) {
        test('${bad.key} hashes the contents', () async {
          final Map<String, String> good = digestsOf(h);
          Map<String, String> withBad() => {
            ...good,
            if (bad.value != null) 'lib/a.dart': bad.value!,
            if (bad.value != null) 'stage/lib/a.dart': bad.value!,
          }..removeWhere((k, _) => bad.value == null && k.endsWith('a.dart'));
          await coldWith(good);
          await warmWith(withBad());
          expect(deltas(), 0, reason: 'unchanged contents');
          edit();
          await warmWith(withBad());
          expect(deltas(), 1, reason: 'edited contents');
        });
      }

      test('a digest for a path outside the request is ignored', () async {
        final Map<String, String> digests = digestsOf(h);
        await coldWith(digests);
        // lib/a.dart is stored but no longer listed; its fake digest must not
        // be honoured, and a digest for a never-seen path changes nothing.
        final IncrResult result = await worker.handleRequest(
          h.argv,
          [...h.inputs]..remove('lib/a.dart'),
          digests: {...digests, 'lib/a.dart': fake, 'lib/other.dart': fake},
        );
        expect(result.exitCode, 0, reason: result.output);
        expect(deltas(), 0);
      });

      test('digests then none, same contents, is no change', () async {
        await coldWith(digestsOf(h));
        await warmWith(const {});
        expect(deltas(), 0);
        await warmWith(const {});
        expect(deltas(), 0);
      });
    });

    test('a changed package config restarts the server cold', () async {
      worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        sessions: factoryFor(() => [h.ok(), h.ok(), h.ok(), h.ok()]),
      );
      expectOk(await worker.handleRequest(h.argv, h.inputs));
      h.write('pkg_config.json', '{"v":2}\n');
      expectOk(await worker.handleRequest(h.argv, h.inputs));
      expect(sessions, hasLength(2));
      expect(sessions[0].closed, isTrue);
      expect(sessions[1].commands.first, 'compile package:app/main.dart');
    });

    test(
      'a compile error rejects and the next request re-invalidates',
      () async {
        const error = 'lib/a.dart:1:5: Error: Expected `;`.';
        worker = IncrWorker(
          cwd: h.cwd,
          sessions: factoryFor(
            () => [
              h.ok(),
              h.ok(),
              (errors: 1, diagnostics: [error], depLines: []),
              h.ok(),
              h.ok(),
            ],
          ),
        );
        IncrResult result = expectOk(
          await worker.handleRequest(h.argv, h.inputs),
        );
        writeBoth(h, 'a.dart', 'broken syntax (((');
        result = await worker.handleRequest(h.argv, h.inputs);
        expectRefused(result, error);
        expect(sessions.single.commands, contains('reject'));
        // The failed request keeps the last accepted hashes ...
        writeBoth(h, 'a.dart', 'int get answer => 44;\n');
        result = expectOk(await worker.handleRequest(h.argv, h.inputs));
        // ... so the repair still recompiles the file (never accepted
        // broken): one failed attempt plus the repair.
        expect(
          sessions.single.commands.where(
            (c) => c.contains('org-dartlang-app:///lib/a.dart'),
          ),
          hasLength(2),
        );
        expect(sessions, hasLength(1));
      },
    );

    test('a reset-phase error drops the server', () async {
      worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        sessions: factoryFor(
          () => [
            h.ok(),
            (errors: 1, diagnostics: ['reset blew up'], depLines: []),
            h.ok(),
            h.ok(),
          ],
        ),
      );
      final IncrResult result = await worker.handleRequest(h.argv, h.inputs);
      expectRefused(result, 'reset blew up');
      expect(sessions.single.closed, isTrue);
      expectOk(await worker.handleRequest(h.argv, h.inputs));
      expect(sessions, hasLength(2));
    });

    test('a dead server restarts cold', () async {
      worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        sessions: factoryFor(() => [h.ok(), h.ok(), h.ok(), h.ok()]),
      );
      expectOk(await worker.handleRequest(h.argv, h.inputs));
      sessions.single.dead = true;
      expectOk(await worker.handleRequest(h.argv, h.inputs));
      expect(sessions, hasLength(2));
    });
  });

  group('handleRequest guard and read-set parity', () {
    late Harness h;
    late List<FakeSession> sessions;
    late IncrWorker worker;
    late Directory savedCwd;

    setUp(() {
      savedCwd = Directory.current;
      h = Harness(Directory.systemTemp.createTempSync('incr_guard_'));
      Directory.current = h.cwd;
      addTearDown(() => h.dir.deleteSync(recursive: true));
      h.writeManifest();
      h.writeCleanSources();
      sessions = [];
      worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        sessions: scripted(sessions, [h.ok(), h.ok()]),
      );
    });

    tearDown(() async {
      Directory.current = savedCwd.path;
      await worker.closeAll();
    });

    test('a disallowed directive fails before the compiler runs', () async {
      writeBoth(h, 'main.dart', "import 'file:///etc/hostname';\n");
      final IncrResult result = await worker.handleRequest(h.argv, h.inputs);
      expectRefused(result, 'lib/main.dart');
      expect(result.output, contains('is not a declared input'));
      expect(sessions, isEmpty);
    });

    test(
      'the guard reads sources even when request digests are equal',
      () async {
        final String fake = 'ab' * 32;
        final Map<String, String> digests = {for (final p in h.inputs) p: fake};
        final IncrResult first = await worker.handleRequest(
          h.argv,
          h.inputs,
          digests: digests,
        );
        expect(first.exitCode, 0);
        writeBoth(h, 'main.dart', "import 'file:///etc/hostname';\n");
        final IncrResult result = await worker.handleRequest(
          h.argv,
          h.inputs,
          digests: digests,
        );
        expectRefused(result, 'is not a declared input');
      },
    );

    test('an undeclared read is refused with the batch message', () async {
      worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        sessions: scripted(sessions, [
          compiled([...h.depLines(), '+file:///etc/hostname']),
          h.ok(),
        ]),
      );
      final IncrResult result = await worker.handleRequest(h.argv, h.inputs);
      expectRefused(result, undeclaredReadMessage('+file:///etc/hostname'));
      expect(File('${h.cwd}/out/app.dill').existsSync(), isFalse);
    });

    test(
      'a read under a root that only the argv names is refused',
      () async {
        // The argv mounts the mirror via `--filesystem-root`, but the
        // manifest names no such read: allowances come only from the
        // manifest, so the mount buys the compile no read.
        final Directory m = Directory.systemTemp.createTempSync('incr_mirror_');
        addTearDown(() => m.deleteSync(recursive: true));
        final String mirror = m.path;
        for (final rel in ['lib/main.dart', 'lib/a.dart', 'lib/new.dart']) {
          File('$mirror/$rel')
            ..createSync(recursive: true)
            ..writeAsStringSync('int get fresh => 7;\n');
        }
        for (final rel in ['lib/main.dart', 'lib/a.dart']) {
          File('$mirror/$rel').writeAsStringSync(
            File('${h.cwd}/$rel').readAsStringSync(),
          );
        }
        // lib/new.dart is a created library: mirrored like the build would
        // stage it, but declared in no manifest section.
        final mirrorReads = [
          '+file://$mirror/lib/main.dart',
          '+file://$mirror/lib/a.dart',
          '+file://$mirror/lib/new.dart',
          '+file://${h.cwd}/lib/main.dart',
          '+file://${h.cwd}/lib/a.dart',
          '+file://${h.cwd}/pkg_config.json',
          '+file://${h.cwd}/platform.dill',
        ];
        worker = IncrWorker(
          cwd: h.cwd,
          tempParent: h.cwd,
          sessions: scripted(sessions, [
            compiled(mirrorReads),
            compiled(mirrorReads),
          ]),
        );
        final IncrResult result = await worker.handleRequest(
          h.argvWithRoot(mirror),
          h.inputs,
        );
        expectRefused(
          result,
          undeclaredReadMessage('+file://$mirror/lib/new.dart'),
        );
        expect(File('${h.cwd}/out/app.dill').existsSync(), isFalse);
      },
    );

    test(
      'a rejected compile still contributes its reads to the refusal',
      () async {
        worker = IncrWorker(
          cwd: h.cwd,
          sessions: scripted(sessions, [
            h.ok(),
            h.ok(),
            compiled([
              ...h.depLines(),
              '+file:///etc/sneak.dart',
            ], errors: 1),
          ]),
        );
        IncrResult result = expectOk(
          await worker.handleRequest(h.argv, h.inputs),
        );
        writeBoth(h, 'a.dart', 'int get answer => 45;\n');
        result = await worker.handleRequest(h.argv, h.inputs);
        expectRefused(result, undeclaredReadMessage('+file:///etc/sneak.dart'));
      },
    );

    test('zero reads fail closed with the batch message', () async {
      worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        sessions: scripted(sessions, [
          compiled(const []),
          compiled(const []),
        ]),
      );
      final IncrResult result = await worker.handleRequest(h.argv, h.inputs);
      expectRefused(result, noDependencyReadsMessage());
    });
  });

  group('server LRU', () {
    test('evicts the least recently used server over the cap', () async {
      final Directory savedCwd = Directory.current;
      final h = Harness(Directory.systemTemp.createTempSync('incr_lru_'));
      Directory.current = h.cwd;
      addTearDown(() => h.dir.deleteSync(recursive: true));
      h.writeManifest();
      h.writeCleanSources();
      final sessions = <FakeSession>[];
      final worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        maxServers: 1,
        sessions: scripted(sessions, [h.ok(), h.ok()]),
      );
      addTearDown(worker.closeAll);
      final List<String> other = [
        ...h.argv.sublist(0, h.argv.indexOf('--packages')),
        '--packages',
        'other_config.json',
        'package:app/main.dart',
      ];
      h.write('other_config.json', '{}\n');
      IncrResult result = await worker.handleRequest(h.argv, [...h.inputs]);
      expect(result.exitCode, 0, reason: result.output);
      result = await worker.handleRequest(other, [
        ...h.inputs,
        'other_config.json',
      ]);
      expect(result.exitCode, 0, reason: result.output);
      expect(sessions, hasLength(2));
      expect(sessions[0].closed, isTrue);
      expect(sessions[1].closed, isFalse);
      Directory.current = savedCwd.path;
    });
  });

  group('worker temp cleanup on every exit path', () {
    late Harness h;
    late Directory savedCwd;

    setUp(() {
      savedCwd = Directory.current;
      h = Harness(Directory.systemTemp.createTempSync('incr_exit_'));
      Directory.current = h.cwd;
      h.writeManifest();
      h.writeCleanSources();
    });

    tearDown(() {
      Directory.current = savedCwd.path;
      h.dir.deleteSync(recursive: true);
    });

    test('a one-shot success leaves no incr_fkc_ dir', () async {
      final int code = await runOneShotWorker(
        h.argv,
        createWorker: () => IncrWorker(
          cwd: h.cwd,
          tempParent: h.cwd,
          sessions: scripted([], [h.ok(), h.ok()]),
        ),
      );
      expect(code, 0);
      expect(File('${h.cwd}/out/app.dill').readAsStringSync(), 'dill-bytes');
      expect(hasWorkerTemp(h.dir), isFalse);
    });

    test('a one-shot failure leaves no incr_fkc_ dir', () async {
      final int code = await runOneShotWorker(
        h.argv,
        createWorker: () => IncrWorker(
          cwd: h.cwd,
          tempParent: h.cwd,
          sessions: scripted([], [compiled(const [], errors: 1)]),
        ),
      );
      expect(code, 1);
      expect(File('${h.cwd}/out/app.dill').existsSync(), isFalse);
      expect(hasWorkerTemp(h.dir), isFalse);
    });

    test('persistent stdin EOF deletes the temp dir', () async {
      final String request = jsonEncode({
        'requestId': 7,
        'arguments': h.argv,
        'inputs': [
          for (final i in h.inputs) {'path': i},
        ],
      });
      final responses = StringBuffer();
      await runPersistentWorker(
        createWorker: () => IncrWorker(
          cwd: h.cwd,
          tempParent: h.cwd,
          sessions: scripted([], [h.ok(), h.ok()]),
        ),
        stdinBytes: Stream.value(utf8.encode('$request\n')),
        responseSink: responses,
      );
      final List<String> lines = responses
          .toString()
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      expect(lines, hasLength(1));
      final reply = jsonDecode(lines.single) as Map<String, dynamic>;
      expect(reply['exitCode'], 0);
      expect(reply['requestId'], 7);
      expect(hasWorkerTemp(h.dir), isFalse);
    });

    test('a signal closes the worker and deletes the temp dir', () async {
      // The watcher is wired to a real process signal: delivering the test
      // runner its own SIGUSR1 exercises the listener, the `closeAll` and
      // the status report through the production path. SIGTERM/SIGINT are
      // spoken for by the test runner (a self-sent SIGTERM aborts the run
      // whichever listener is attached), so the test watches SIGUSR1, whose
      // signum travels with the pair exactly like the production SIGTERM
      // (143) and SIGINT (130) pairs it stands in for. Attaching a listener
      // suppresses the default kill-the-process action, and `onSignal`
      // records the status instead of exiting, so the runner survives. The
      // worker serves no requests here: construction alone creates the temp
      // dir to delete.
      final worker = IncrWorker(cwd: h.cwd, tempParent: h.cwd);
      final statuses = <int>[];
      final List<StreamSubscription<ProcessSignal>> subs = watchWorkerSignals(
        worker,
        onSignal: statuses.add,
        signals: [(signal: ProcessSignal.sigusr1, status: 999)],
      );
      if (subs.isEmpty) {
        markTestSkipped('this platform delivers no watched signal');
      }
      addTearDown(() => cancelWorkerSignals(subs));
      expect(hasWorkerTemp(h.dir), isTrue);
      expect(Process.killPid(pid, ProcessSignal.sigusr1), isTrue);
      for (var i = 0; i < 200 && statuses.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(statuses, [999]);
      expect(hasWorkerTemp(h.dir), isFalse);
    });
  });

  group('FrontendServerSession protocol', () {
    test(
      'round-trips compile, recompile, accept, reject against a fake',
      () async {
        final Directory d = Directory.systemTemp.createTempSync('incr_proto_');
        addTearDown(() => d.deleteSync(recursive: true));
        const uuid = '11111111-2222-3333-4444-555555555555';
        File('${d.path}/fake_server.dart').writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
void respond() {
  stdout.writeln('result $uuid');
  stdout.writeln('$uuid');
  stdout.writeln('+file://\${Directory.current.path}/lib/main.dart');
  stdout.writeln('$uuid out.dill 0');
}
void main() async {
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  var pending = false;
  await for (final line in lines) {
    if (line.startsWith('compile ')) {
      respond();
      continue;
    }
    if (line.startsWith('recompile ')) {
      pending = true;
      continue;
    }
    if (line == 'kk' && pending) {
      pending = false;
      respond();
      continue;
    }
    if (line == 'reset' || line == 'accept') continue;
    if (line == 'reject') {
      stdout.writeln('rejected');
      stdout.writeln('ok');
      continue;
    }
    if (line == 'quit') return;
  }
}
''');
        final FrontendServerSession session = await FrontendServerSession.start(
          [
            Platform.resolvedExecutable,
            '${d.path}/fake_server.dart',
            '--output-dill',
            'out/app.dill',
            'package:app/main.dart',
          ],
          '${d.path}/full.dill',
          '${d.path}/inc.dill',
          cwd: d.path,
        );
        addTearDown(session.close);
        const entry = 'package:app/main.dart';
        final CompileResult compiled = await session.compile(entry);
        expect(compiled.errors, 0);
        expect(compiled.depLines, hasLength(1));
        await session.accept();
        final CompileResult delta = await session.recompile(entry, [
          'org-dartlang-app:///lib/a.dart',
        ]);
        expect(delta.errors, 0);
        await session.accept();
        expect(
          (await session.recompile(entry, [], resetFirst: true)).errors,
          0,
        );
        await session.accept();
        await session.reject();
        expect(session.alive, isTrue);
        await session.close();
      },
    );
  });
}

/// A [File] that counts `readAsBytesSync` calls per path and forwards the
/// reads the worker makes to [_real].
class CountingFile implements File {
  new(this._real, this._reads);

  final File _real;
  final Map<String, int> _reads;

  @override
  String get path => _real.path;

  @override
  Uint8List readAsBytesSync() {
    _reads[_real.path] = (_reads[_real.path] ?? 0) + 1;
    return _real.readAsBytesSync();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}
