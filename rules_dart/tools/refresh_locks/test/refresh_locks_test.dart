import 'dart:async';
import 'dart:io';

import 'package:refresh_locks/refresh.dart';
import 'package:refresh_locks/workspaces.dart';
import 'package:test/test.dart';

/// A repository tree under a temporary directory.
Directory fixture(List<String> files) {
  final root = Directory.systemTemp.createTempSync('refresh_locks_test');
  addTearDown(() => root.deleteSync(recursive: true));
  for (final f in files) {
    File('${root.path}/$f')
      ..createSync(recursive: true)
      ..writeAsStringSync('');
  }
  return root;
}

/// A fake Bazel: [script] answers each command line, and every command is
/// recorded in [calls].
final class Fake {
  Fake(this.script);
  final CommandResult Function(List<String> args, String dir) script;
  final calls = <String>[];

  Future<CommandResult> call(List<String> command, String dir) async {
    calls.add(command.skip(1).join(' '));
    return script(command.skip(1).toList(), dir);
  }
}

const ok = CommandResult(0, '');

void main() {
  group('findWorkspaces', () {
    test('finds every MODULE.bazel and prunes what is not a workspace', () {
      final root = fixture([
        'MODULE.bazel',
        'rules_dart/MODULE.bazel',
        'rules_dart/e2e/smoke/MODULE.bazel',
        'rules_dart/e2e/smoke/sub/MODULE.bazel',
        'rules_dart/e2e/skipme/MODULE.bazel',
        'rules_dart/.hidden/MODULE.bazel',
        'rules_dart/bazel-out/MODULE.bazel',
        'rules_dart/references/r/MODULE.bazel',
        'rules_dart/e2e/none/BUILD.bazel',
      ]);
      Link('${root.path}/linked').createSync('rules_dart/e2e/smoke');
      final found = findWorkspaces(
        root.path,
        skipped: {'rules_dart/e2e/skipme': 'because'},
      );
      expect(
        [for (final w in found) w.path],
        ['.', 'rules_dart', 'rules_dart/e2e/smoke', 'rules_dart/e2e/smoke/sub'],
      );
    });

    test('every skipped workspace has a reason', () {
      expect(skippedWorkspaces.values.every((r) => r.isNotEmpty), isTrue);
    });

    test('a workspace is not both skipped and expected to fail', () {
      expect(
        expectedFailures.keys.where(skippedWorkspaces.containsKey),
        isEmpty,
      );
    });
  });

  group('selectWorkspaces', () {
    final all = [
      for (final p in [
        'rules_dart/e2e/pub',
        'rules_dart/e2e/pub_lock',
        'rules_flutter/e2e/hello_world',
      ])
        Workspace(p, '/x/$p'),
    ];
    List<String> pick(List<String> f) => [
      for (final w in selectWorkspaces(all, f)) w.path,
    ];

    test('matches a path or a directory above it, never a name prefix', () {
      expect(pick(['rules_dart/e2e/pub']), ['rules_dart/e2e/pub']);
      expect(pick(['rules_dart/e2e/']).length, 2);
      expect(pick(['./rules_flutter']), ['rules_flutter/e2e/hello_world']);
    });
    test('no filter selects everything', () {
      expect(pick([]).length, 3);
    });
  });

  test('findRepositoryRoot walks up to the directory holding both modules', () {
    final root = fixture([
      'rules_dart/MODULE.bazel',
      'rules_flutter/MODULE.bazel',
      'rules_dart/tools/x/y.txt',
    ]);
    expect(
      findRepositoryRoot('${root.path}/rules_dart/tools/x'),
      Directory(root.path).absolute.path,
    );
  });

  group('refreshWorkspace', () {
    late Directory root;
    late Workspace ws;
    setUp(() {
      root = fixture(['ws/MODULE.bazel']);
      ws = Workspace('ws', '${root.path}/ws');
    });

    /// `mod deps --lockfile_mode=update` writes the lock, as Bazel does.
    CommandResult writesLock(List<String> args, String dir) {
      if (args.contains('--lockfile_mode=update')) {
        File('$dir/MODULE.bazel.lock').writeAsStringSync('{"v": 1}\n');
      }
      return ok;
    }

    test('runs tidy, update, error, then stops the server', () async {
      final fake = Fake(writesLock);
      final o = await refreshWorkspace(
        ws,
        const Options(),
        fake.call,
        StringBuffer(),
      );
      expect(fake.calls, [
        'mod tidy --lockfile_mode=refresh',
        'mod deps --lockfile_mode=update',
        'mod deps --lockfile_mode=error',
        'shutdown',
      ]);
      expect(o.status, Status.updated);
    });

    test('a second run that writes the same bytes is current', () async {
      final fake = Fake(writesLock);
      await refreshWorkspace(ws, const Options(), fake.call, StringBuffer());
      final o = await refreshWorkspace(
        ws,
        const Options(),
        fake.call,
        StringBuffer(),
      );
      expect(o.status, Status.current);
    });

    test(
      '--no-tidy, --keep-servers and --expunge change the commands',
      () async {
        final fake = Fake(writesLock);
        await refreshWorkspace(
          ws,
          const Options(tidy: false, shutdown: false),
          fake.call,
          StringBuffer(),
        );
        expect(fake.calls.any((c) => c.contains('tidy')), isFalse);
        expect(fake.calls.last, 'mod deps --lockfile_mode=error');
        fake.calls.clear();
        await refreshWorkspace(
          ws,
          const Options(tidy: false, expunge: true),
          fake.call,
          StringBuffer(),
        );
        expect(fake.calls.last, 'clean --expunge');
      },
    );

    test(
      'a failing step is retried once, then reported with its first error',
      () async {
        final fake = Fake(
          (args, dir) => args.contains('tidy')
              ? const CommandResult(1, 'INFO: x\nERROR: no registry\nmore\n')
              : ok,
        );
        final o = await refreshWorkspace(
          ws,
          const Options(),
          fake.call,
          StringBuffer(),
        );
        expect(o.status, Status.failed);
        expect(o.detail, 'mod tidy: ERROR: no registry');
        expect(fake.calls.where((c) => c.contains('tidy')).length, 2);
        expect(fake.calls.last, 'shutdown');
      },
    );

    test(
      'a transient failure that passes on the retry is not a failure',
      () async {
        var first = true;
        final fake = Fake((args, dir) {
          if (args.contains('--lockfile_mode=update') && first) {
            first = false;
            return const CommandResult(1, 'ERROR: timeout');
          }
          return writesLock(args, dir);
        });
        final o = await refreshWorkspace(
          ws,
          const Options(),
          fake.call,
          StringBuffer(),
        );
        expect(o.status, Status.updated);
      },
    );

    test(
      'a failure it is listed for is expected, anything else is not',
      () async {
        final fake = Fake(
          (args, dir) => args.contains('--lockfile_mode=update')
              ? const CommandResult(
                  1,
                  'ERROR: conflicting versions across lock files',
                )
              : ok,
        );
        var o = await refreshWorkspace(
          ws,
          const Options(expected: {'ws': 'conflicting versions'}),
          fake.call,
          StringBuffer(),
        );
        expect(o.status, Status.expected);
        expect(o.ok, isTrue);
        o = await refreshWorkspace(
          ws,
          const Options(expected: {'ws': 'something else'}),
          fake.call,
          StringBuffer(),
        );
        expect(o.status, Status.failed);
      },
    );

    test(
      'a lock that does not pass `error` mode right after is a failure',
      () async {
        final fake = Fake(
          (args, dir) => args.contains('--lockfile_mode=error')
              ? const CommandResult(1, 'ERROR: extension not in lockfile')
              : ok,
        );
        final o = await refreshWorkspace(
          ws,
          const Options(),
          fake.call,
          StringBuffer(),
        );
        expect(o.status, Status.failed);
        expect(o.detail, contains('extension not in lockfile'));
      },
    );
  });

  group('checkWorkspace', () {
    test('a missing lockfile is stale, and Bazel is not asked', () async {
      final root = fixture(['ws/MODULE.bazel']);
      final fake = Fake((a, d) => ok);
      final o = await checkWorkspace(
        Workspace('ws', '${root.path}/ws'),
        const Options(),
        fake.call,
        StringBuffer(),
      );
      expect(o.status, Status.stale);
      expect(fake.calls, isEmpty);
    });

    test('passes when `error` mode passes, and never writes', () async {
      final root = fixture(['ws/MODULE.bazel', 'ws/MODULE.bazel.lock']);
      final fake = Fake((a, d) => ok);
      final o = await checkWorkspace(
        Workspace('ws', '${root.path}/ws'),
        const Options(),
        fake.call,
        StringBuffer(),
      );
      expect(o.status, Status.current);
      expect(fake.calls, ['mod deps --lockfile_mode=error', 'shutdown']);
    });

    test('names the first error of a stale lockfile', () async {
      final root = fixture(['ws/MODULE.bazel', 'ws/MODULE.bazel.lock']);
      final fake = Fake(
        (a, d) => const CommandResult(
          1,
          'Loading\nERROR: module extension "pub" is not in the lockfile\n',
        ),
      );
      final o = await checkWorkspace(
        Workspace('ws', '${root.path}/ws'),
        const Options(),
        fake.call,
        StringBuffer(),
      );
      expect(o.status, Status.stale);
      expect(o.ok, isFalse);
      expect(o.detail, startsWith('ERROR: module extension'));
    });
  });

  group('osKeyedExtensions', () {
    test('names extensions with an entry for one system', () {
      const lock = '''
{"moduleExtensions": {
  "@@a+//:e.bzl%general_only": {"general": {}},
  "@@b+//:e.bzl%per_system": {"os:linux,arch:amd64": {}, "os:macos,arch:arm64": {}}
}}''';
      expect(osKeyedExtensions(lock), [
        '@@b+//:e.bzl%per_system (os:linux,arch:amd64; os:macos,arch:arm64)',
      ]);
    });
    test('a lock with only general entries, or no JSON, has none', () {
      expect(
        osKeyedExtensions('{"moduleExtensions": {"x": {"general": {}}}}'),
        isEmpty,
      );
      expect(osKeyedExtensions('not json'), isEmpty);
      expect(osKeyedExtensions('{}'), isEmpty);
    });
  });

  test(
    'a lockfile with per-system entries fails a refresh and a check',
    () async {
      final root = fixture(['ws/MODULE.bazel']);
      final ws = Workspace('ws', '${root.path}/ws');
      const perSystem =
          '{"moduleExtensions": {"x": {"os:linux,arch:amd64": {}}}}';
      final fake = Fake((args, dir) {
        if (args.contains('--lockfile_mode=update')) {
          File('$dir/MODULE.bazel.lock').writeAsStringSync(perSystem);
        }
        return ok;
      });
      var o = await refreshWorkspace(
        ws,
        const Options(),
        fake.call,
        StringBuffer(),
      );
      expect(o.status, Status.failed);
      expect(o.detail, contains('per-system entries'));
      o = await checkWorkspace(ws, const Options(), fake.call, StringBuffer());
      expect(o.status, Status.stale);
    },
  );

  test('runPool keeps within its limit and keeps the order', () async {
    var running = 0;
    var peak = 0;
    final results = await runPool<int, int>(List.generate(7, (i) => i), 3, (
      i,
    ) async {
      peak = peak < ++running ? running : peak;
      await Future<void>.delayed(Duration(milliseconds: 5 * (7 - i)));
      running--;
      return i * 2;
    });
    expect(peak, 3);
    expect(results, [0, 2, 4, 6, 8, 10, 12]);
  });

  test('userBazelrcs names the workspaces that have one', () {
    final root = fixture([
      'a/MODULE.bazel',
      'b/MODULE.bazel',
      'b/.bazelrc.user',
    ]);
    expect(
      userBazelrcs([
        Workspace('a', '${root.path}/a'),
        Workspace('b', '${root.path}/b'),
      ]),
      ['b/.bazelrc.user'],
    );
  });

  test('firstError prefers an ERROR line and falls back to the last line', () {
    expect(firstError('x\nERROR: a\nERROR: b'), 'ERROR: a');
    expect(firstError('x\ny\n\n'), 'y');
    expect(firstError(''), '(no output)');
  });
}
