// Tagged `runfiles`: the worker imports `kernel_filter.dart`, which imports
// `package:rules_dart_guard`, supplied via the `@rules_dart//dart/guard`
// dep its `dart_test` declares. A bare `dart test` resolves only this
// package's pubspec, where that import does not exist.
// Coverage comes from //flutter/private/tools:incr_fkc_staging_test.
@Tags(['runfiles'])
library;

import 'dart:convert';

import 'package:test/test.dart';

import '../incr_fkc_server.dart';
import '../sha256.dart';

void main() {
  group('sha256Hex', () {
    test('matches the standard vectors', () {
      expect(
        sha256Hex(const []),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        sha256Hex(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });
  });

  group('splitWorkerArgv', () {
    test('drops a leading tool path, keeps flags and flagfiles', () {
      expect(stripWorkerArgv0(['--declared-inputs', 'm']), [
        '--declared-inputs',
        'm',
      ]);
      expect(stripWorkerArgv0(['@args']), ['@args']);
      expect(stripWorkerArgv0(['/tool/worker', '--declared-inputs', 'm']), [
        '--declared-inputs',
        'm',
      ]);
      expect(stripWorkerArgv0([]), isEmpty);
    });
    test('splits the manifest from the compiler command', () {
      final ({String manifestPath, List<String> command, bool devIncremental})
      split = splitWorkerArgv([
        '--declared-inputs',
        'm.txt',
        '--',
        'vm',
        'snap.snapshot',
        'entry.dart',
      ]);
      expect(split.manifestPath, 'm.txt');
      expect(split.command, ['vm', 'snap.snapshot', 'entry.dart']);
    });

    test('rejects a missing manifest flag and stray args', () {
      expect(() => splitWorkerArgv(['--', 'vm']), throwsFormatException);
      expect(
        () => splitWorkerArgv(['--bogus', 'x', '--', 'vm']),
        throwsFormatException,
      );
      expect(
        () => splitWorkerArgv(['--declared-inputs', 'm']),
        throwsFormatException,
      );
    });
  });

  group('dev incremental serialization', () {
    const flags = [
      'vm',
      'fe.snapshot',
      '--output-dill',
      'full.dill',
      'package:app/main.dart',
    ];

    test('the default spawn argv pins --no-incremental-serialization', () {
      expect(frontendServerSpawnArgs(flags.sublist(0, 4), 'inc.dill'), [
        'fe.snapshot',
        '--incremental',
        '--no-incremental-serialization',
        '--output-incremental-dill',
        'inc.dill',
        '--output-dill',
        'full.dill',
        '--print-incremental-dependencies',
      ]);
    });

    test('the marker drops the flag and never reaches frontend_server', () {
      final List<String> args = frontendServerSpawnArgs(
        flags.sublist(0, 4),
        'inc.dill',
        devIncremental: true,
      );
      expect(args, isNot(contains('--no-incremental-serialization')));
      expect(args, isNot(contains(devIncrementalSerializationMarker)));
      expect(args, contains('--incremental'));
    });

    test('splitWorkerArgv consumes and strips the marker', () {
      final ({String manifestPath, List<String> command, bool devIncremental})
      split = splitWorkerArgv([
        devIncrementalSerializationMarker,
        '--declared-inputs',
        'm',
        '--',
        'vm',
        'entry.dart',
      ]);
      expect(split.devIncremental, isTrue);
      expect(split.command, ['vm', 'entry.dart']);
      expect(
        splitWorkerArgv(['--declared-inputs', 'm', '--', 'vm']).devIncremental,
        isFalse,
      );
    });

    test('the configuration key ignores the marker', () {
      final ({String manifestPath, List<String> command, bool devIncremental})
      marked = splitWorkerArgv([
        devIncrementalSerializationMarker,
        '--declared-inputs',
        'm',
        '--',
        ...flags,
        devIncrementalSerializationMarker,
      ]);
      expect(
        configurationKey(marked.command, sha256Hex),
        configurationKey(flags, sha256Hex),
      );
    });
  });

  group('uriOfStaged and classifyChanged', () {
    test('maps staged paths under a root to the app scheme', () {
      expect(
        uriOfStaged('stage/lib/a.dart', ['stage']),
        'org-dartlang-app:///lib/a.dart',
      );
      expect(uriOfStaged('lib/a.dart', ['stage']), isNull);
      // The mount world reads sources in place: under an exec-root mount an
      // in-place path carries its own URI, so no staged twin is needed.
      expect(
        uriOfStaged('stage/lib/a.dart', ['.', '']),
        'org-dartlang-app:///stage/lib/a.dart',
      );
    });

    test('staged dart files become URIs, their source twins are skipped', () {
      final ChangedInputs classified = classifyChanged(
        ['lib/a.dart', 'stage/lib/a.dart'],
        ['stage'],
        {'lib/main.dart', 'lib/a.dart'},
      );
      expect(classified.restartReason, isNull);
      expect(classified.uris, ['org-dartlang-app:///lib/a.dart']);
    });

    test('a changed package config restarts cold', () {
      final ChangedInputs classified = classifyChanged(
        ['pkg_config.json'],
        ['stage'],
        {'lib/main.dart'},
      );
      expect(classified.restartReason, 'pkg_config.json');
    });

    test('an unstaged dart file outside the manifest restarts cold', () {
      final ChangedInputs classified = classifyChanged(
        ['tool/gen.dart'],
        ['stage'],
        {'lib/main.dart'},
      );
      expect(classified.restartReason, 'tool/gen.dart');
    });

    test('a deleted staged dart file still invalidates by URI', () {
      final ChangedInputs classified = classifyChanged(
        ['stage/lib/gone.dart'],
        ['stage'],
        {'lib/main.dart'},
      );
      expect(classified.restartReason, isNull);
      expect(classified.uris, ['org-dartlang-app:///lib/gone.dart']);
    });

    test('in-place sources map under an exec-root mount', () {
      expect(
        uriOfStaged('lib/a.dart', ['gen.stage', '.']),
        'org-dartlang-app:///lib/a.dart',
      );
      expect(mountsExecRoot(['gen.stage', '.']), isTrue);
      expect(mountsExecRoot(['gen.stage']), isFalse);
      expect(isInPlacePath('lib/a.dart'), isTrue);
      expect(isInPlacePath('../escape.dart'), isFalse);
      expect(isInPlacePath('/abs/a.dart'), isFalse);
    });

    test('a generated file keys the same URI in place and staged', () {
      // The in-place `bazel-out/<config>/bin/` path strips to the
      // workspace-relative path it is staged at ...
      expect(
        inPlaceSourceKey('bazel-out/k8-fastbuild/bin/gen/foo.dart'),
        'gen/foo.dart',
      );
      expect(inPlaceSourceKey('lib/a.dart'), 'lib/a.dart');
      expect(
        uriOfStaged('bazel-out/k8-fastbuild/bin/gen/foo.dart', [
          'gen.stage',
          '.',
        ]),
        'org-dartlang-app:///gen/foo.dart',
      );
      // ... so the pair dedupes to one delta URI.
      final ChangedInputs classified = classifyChanged(
        ['bazel-out/k8-fastbuild/bin/gen/foo.dart', 'gen.stage/gen/foo.dart'],
        ['gen.stage', '.'],
        {'bazel-out/k8-fastbuild/bin/gen/foo.dart'},
      );
      expect(classified.restartReason, isNull);
      expect(classified.uris, ['org-dartlang-app:///gen/foo.dart']);
    });

    test('a source beside its staged twin recompiles once', () {
      final ChangedInputs classified = classifyChanged(
        ['lib/a.dart', 'gen.stage/lib/a.dart'],
        ['gen.stage', '.'],
        {'lib/a.dart'},
      );
      expect(classified.restartReason, isNull);
      expect(classified.uris, ['org-dartlang-app:///lib/a.dart']);
    });

    test('an unmappable dart file still restarts cold', () {
      expect(uriOfStaged('../escape.dart', ['.']), isNull);
      final ChangedInputs classified = classifyChanged(
        ['../escape.dart'],
        ['.'],
        {'lib/main.dart'},
      );
      expect(classified.restartReason, '../escape.dart');
    });
  });
}
