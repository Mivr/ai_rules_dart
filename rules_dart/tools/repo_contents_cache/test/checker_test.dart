/// Unit tests for repo_contents_cache symlink and cache entry comparisons.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:repo_contents_cache/repo_contents_cache.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String ob1;
  late String ob2;
  late String rcc;

  setUp(() {
    tempDir = createCheckScratchDir(Directory.current.path);
    ob1 = p.join(tempDir.path, 'ob1');
    ob2 = p.join(tempDir.path, 'ob2');
    rcc = p.join(tempDir.path, 'contents');

    Directory(p.join(ob1, 'external')).createSync(recursive: true);
    Directory(p.join(ob2, 'external')).createSync(recursive: true);
    Directory(rcc).createSync(recursive: true);
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup of temporary test directory.
    }
  });

  group('verifyOutputBases', () {
    test('passes when reproducible repos are symlinks to same cache entry', () {
      final String hashDir = p.join(rcc, 'hash123');
      final String cacheEntry = p.join(hashDir, 'uuid-abc');
      Directory(cacheEntry).createSync(recursive: true);
      File(p.join(hashDir, 'uuid-abc.recorded_inputs'))
          .writeAsStringSync('inputs');

      Link(p.join(ob1, 'external', 'my_repo')).createSync(cacheEntry);
      Link(p.join(ob2, 'external', 'my_repo')).createSync(cacheEntry);

      expect(
        () => verifyOutputBases(
          outputBase1: ob1,
          outputBase2: ob2,
          reproducibleRepos: <String>['my_repo'],
          repoContentsCache: rcc,
        ),
        returnsNormally,
      );
    });

    test('resolves relative symlinks pointing to same cache entry', () {
      final String hashDir = p.join(rcc, 'hash_rel');
      final String cacheEntry = p.join(hashDir, 'uuid-rel');
      Directory(cacheEntry).createSync(recursive: true);

      final String link1 = p.join(ob1, 'external', 'my_repo');
      final String link2 = p.join(ob2, 'external', 'my_repo');
      Link(link1).createSync(p.relative(cacheEntry, from: p.dirname(link1)));
      Link(link2).createSync(p.relative(cacheEntry, from: p.dirname(link2)));

      expect(
        () => verifyOutputBases(
          outputBase1: ob1,
          outputBase2: ob2,
          reproducibleRepos: <String>['my_repo'],
          repoContentsCache: rcc,
        ),
        returnsNormally,
      );
    });

    test('passes when probe repo is a real directory', () {
      Directory(p.join(ob1, 'external', 'probe')).createSync(recursive: true);
      Directory(p.join(ob2, 'external', 'probe')).createSync(recursive: true);

      expect(
        () => verifyOutputBases(
          outputBase1: ob1,
          outputBase2: ob2,
          reproducibleRepos: <String>[],
          probeRepos: <String>['probe'],
          repoContentsCache: rcc,
        ),
        returnsNormally,
      );
    });

    test(
      'fails when reproducible repo is a real directory instead of symlink',
      () {
        Directory(p.join(ob1, 'external', 'my_repo'))
            .createSync(recursive: true);
        Directory(p.join(ob2, 'external', 'my_repo'))
            .createSync(recursive: true);

        expect(
          () => verifyOutputBases(
            outputBase1: ob1,
            outputBase2: ob2,
            reproducibleRepos: <String>['my_repo'],
            repoContentsCache: rcc,
          ),
          throwsA(
            isA<CheckFailure>().having(
              (CheckFailure e) => e.message,
              'message',
              contains(
                'Expected external/my_repo in output base 1 to be a symlink',
              ),
            ),
          ),
        );
      },
    );

    test('fails when symlinks point outside repoContentsCache', () {
      final String outsideDir = p.join(tempDir.path, 'outside_local', 'entry');
      Directory(outsideDir).createSync(recursive: true);

      Link(p.join(ob1, 'external', 'my_repo')).createSync(outsideDir);
      Link(p.join(ob2, 'external', 'my_repo')).createSync(outsideDir);

      expect(
        () => verifyOutputBases(
          outputBase1: ob1,
          outputBase2: ob2,
          reproducibleRepos: <String>['my_repo'],
          repoContentsCache: rcc,
        ),
        throwsA(
          isA<CheckFailure>().having(
            (CheckFailure e) => e.message,
            'message',
            contains('inside repo contents cache'),
          ),
        ),
      );
    });

    test('fails when symlinks point to different cache entries', () {
      final String entry1 = p.join(rcc, 'hash1', 'uuid-1');
      final String entry2 = p.join(rcc, 'hash2', 'uuid-2');
      Directory(entry1).createSync(recursive: true);
      Directory(entry2).createSync(recursive: true);

      Link(p.join(ob1, 'external', 'my_repo')).createSync(entry1);
      Link(p.join(ob2, 'external', 'my_repo')).createSync(entry2);

      expect(
        () => verifyOutputBases(
          outputBase1: ob1,
          outputBase2: ob2,
          reproducibleRepos: <String>['my_repo'],
          repoContentsCache: rcc,
        ),
        throwsA(
          isA<CheckFailure>().having(
            (CheckFailure e) => e.message,
            'message',
            contains('point to different cache entries'),
          ),
        ),
      );
    });

    test('fails when contents/<hash>/ holds multiple directory entries', () {
      final String hashDir = p.join(rcc, 'hash123');
      final String entry1 = p.join(hashDir, 'uuid-1');
      final String entry2 = p.join(hashDir, 'uuid-2');
      Directory(entry1).createSync(recursive: true);
      Directory(entry2).createSync(recursive: true);

      Link(p.join(ob1, 'external', 'my_repo')).createSync(entry1);
      Link(p.join(ob2, 'external', 'my_repo')).createSync(entry1);

      expect(
        () => verifyOutputBases(
          outputBase1: ob1,
          outputBase2: ob2,
          reproducibleRepos: <String>['my_repo'],
          repoContentsCache: rcc,
        ),
        throwsA(
          isA<CheckFailure>().having(
            (CheckFailure e) => e.message,
            'message',
            contains('Expected contents/hash123/ to hold 1 entry, but found 2'),
          ),
        ),
      );
    });

    test('fails when probe repo is a symlink', () {
      final String entry = p.join(rcc, 'hash123', 'uuid-1');
      Directory(entry).createSync(recursive: true);

      Link(p.join(ob1, 'external', 'probe')).createSync(entry);
      Link(p.join(ob2, 'external', 'probe')).createSync(entry);

      expect(
        () => verifyOutputBases(
          outputBase1: ob1,
          outputBase2: ob2,
          reproducibleRepos: <String>[],
          probeRepos: <String>['probe'],
          repoContentsCache: rcc,
        ),
        throwsA(
          isA<CheckFailure>().having(
            (CheckFailure e) => e.message,
            'message',
            contains(
              'Expected probe repo probe in output base 1 to be a real directory',
            ),
          ),
        ),
      );
    });
  });

  group('verifyScannerSha256', () {
    test('passes when files are identical in real directories', () {
      final String scannerDir1 = p.join(ob1, 'external', 'dart_pub_scanner');
      final String scannerDir2 = p.join(ob2, 'external', 'dart_pub_scanner');
      Directory(scannerDir1).createSync(recursive: true);
      Directory(scannerDir2).createSync(recursive: true);

      File(p.join(scannerDir1, 'scanner'))
          .writeAsStringSync('binary contents 123');
      File(p.join(scannerDir2, 'scanner'))
          .writeAsStringSync('binary contents 123');

      expect(
        () => verifyScannerSha256(
          outputBase1: ob1,
          outputBase2: ob2,
          scannerRepo: 'dart_pub_scanner',
          requireRealDirectory: true,
        ),
        returnsNormally,
      );
    });

    test('fails when files differ', () {
      final String scannerDir1 = p.join(ob1, 'external', 'dart_pub_scanner');
      final String scannerDir2 = p.join(ob2, 'external', 'dart_pub_scanner');
      Directory(scannerDir1).createSync(recursive: true);
      Directory(scannerDir2).createSync(recursive: true);

      File(p.join(scannerDir1, 'scanner'))
          .writeAsStringSync('binary contents A');
      File(p.join(scannerDir2, 'scanner'))
          .writeAsStringSync('binary contents B');

      expect(
        () => verifyScannerSha256(
          outputBase1: ob1,
          outputBase2: ob2,
          scannerRepo: 'dart_pub_scanner',
        ),
        throwsA(
          isA<CheckFailure>().having(
            (CheckFailure e) => e.message,
            'message',
            contains('Scanner binary SHA-256 mismatch'),
          ),
        ),
      );
    });

    test('fails when requireRealDirectory is true and scanner is symlink', () {
      final String cachedScanner = p.join(rcc, 'hash1', 'uuid-scan');
      Directory(cachedScanner).createSync(recursive: true);
      File(p.join(cachedScanner, 'scanner')).writeAsStringSync('same bytes');

      Link(p.join(ob1, 'external', 'dart_pub_scanner'))
          .createSync(cachedScanner);
      Link(p.join(ob2, 'external', 'dart_pub_scanner'))
          .createSync(cachedScanner);

      expect(
        () => verifyScannerSha256(
          outputBase1: ob1,
          outputBase2: ob2,
          scannerRepo: 'dart_pub_scanner',
          requireRealDirectory: true,
        ),
        throwsA(
          isA<CheckFailure>().having(
            (CheckFailure e) => e.message,
            'message',
            contains(
              'Expected scanner repo dart_pub_scanner in output base 1 '
              'to be a real directory',
            ),
          ),
        ),
      );
    });
  });

  group('resolveCanonicalRepo', () {
    test('handles apparent, canonical, scanner, shared and isolated hubs', () {
      final mapping = <String, Object?>{
        'dart_toolchains': 'ai_rules_dart++dart+dart_toolchains',
        'dart_linux-x64': '+dart+dart_linux-x64',
        'pub_deps': 'ai_rules_dart++pub+pub_deps',
        'dart_pub__meta': 'ai_rules_dart++pub+dart_pub__meta',
        'tool_deps': 'ai_rules_dart++_pub_iso+tool_deps',
        'tool_deps__meta': 'ai_rules_dart++_pub_iso+tool_deps__meta',
      };

      expect(
        resolveCanonicalRepo('dart_linux-x64', mapping),
        '+dart+dart_linux-x64',
      );
      expect(
        resolveCanonicalRepo('@dart_linux-x64', mapping),
        '+dart+dart_linux-x64',
      );
      expect(
        resolveCanonicalRepo('@@+dart+dart_linux-x64', mapping),
        '+dart+dart_linux-x64',
      );
      expect(
        resolveCanonicalRepo('pub_deps__meta', mapping),
        'ai_rules_dart++pub+dart_pub__meta',
      );
      expect(
        resolveCanonicalRepo('tool_deps__meta', mapping),
        'ai_rules_dart++_pub_iso+tool_deps__meta',
      );
      expect(
        resolveCanonicalRepo('dart_pub_scanner', mapping),
        'ai_rules_dart++dart+dart_pub_scanner',
      );
      expect(resolveCanonicalRepo('unknown_repo', mapping), 'unknown_repo');
    });
  });

  group('parseCheckArgs', () {
    test('treats positional probe without --probe as reproducible repo', () {
      final CheckConfig config = parseCheckArgs(<String>[
        '../e2e/pub_lock_git',
        'probe',
      ]);
      expect(config.workspaceDir, '../e2e/pub_lock_git');
      expect(config.reproducibleRepos, <String>['probe']);
      expect(config.probeRepos, isEmpty);
      expect(config.checkScanner, isFalse);
    });

    test('parses --probe and --probe= and --scanner flags', () {
      final CheckConfig config = parseCheckArgs(<String>[
        '..',
        'dart_linux-x64',
        '--probe',
        'probe_a',
        '--probe=probe_b',
        '--scanner',
      ]);
      expect(config.workspaceDir, '..');
      expect(config.reproducibleRepos, <String>['dart_linux-x64']);
      expect(config.probeRepos, <String>['probe_a', 'probe_b']);
      expect(config.checkScanner, isTrue);
    });

    test('rejects missing workspace or missing targets', () {
      expect(() => parseCheckArgs(<String>[]), throwsFormatException);
      expect(() => parseCheckArgs(<String>['..']), throwsFormatException);
      expect(
        () => parseCheckArgs(<String>['..', '--probe']),
        throwsFormatException,
      );
      expect(
        () => parseCheckArgs(<String>['..', '--unknown']),
        throwsFormatException,
      );
    });
  });

  group('createCheckScratchDir', () {
    test('returns directory outside workspace', () {
      final String wsDir = Directory.current.path;
      final Directory scratch = createCheckScratchDir(wsDir);
      try {
        expect(p.isAbsolute(scratch.path), isTrue);
        expect(scratch.path, isNot(equals(p.canonicalize(wsDir))));
        expect(p.isWithin(p.canonicalize(wsDir), scratch.path), isFalse);
        expect(scratch.existsSync(), isTrue);
      } finally {
        scratch.deleteSync(recursive: true);
      }
    });

    test('avoids candidates inside workspace', () {
      final String fakeWs = p.join(tempDir.path, 'fake_ws');
      Directory(fakeWs).createSync(recursive: true);
      final String insideCandidate = p.join(fakeWs, '.tmp');
      Directory(insideCandidate).createSync(recursive: true);

      final Directory scratch = createCheckScratchDir(
        fakeWs,
        environment: <String, String>{
          'BUILD_WORKING_DIRECTORY': fakeWs,
          'TMPDIR': insideCandidate,
        },
      );
      try {
        final String canonicalWs = p.canonicalize(fakeWs);
        expect(scratch.path, isNot(equals(canonicalWs)));
        expect(p.isWithin(canonicalWs, scratch.path), isFalse);
        expect(scratch.existsSync(), isTrue);
      } finally {
        scratch.deleteSync(recursive: true);
      }
    });
  });
}
