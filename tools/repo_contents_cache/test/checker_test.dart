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
    rcc = p.join(tempDir.path, 'rcc');

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

  test('passes when reproducible repos are symlinks to same cache entry', () {
    final hashDir = p.join(rcc, 'hash123');
    final cacheEntry = p.join(hashDir, 'uuid-abc');
    Directory(cacheEntry).createSync(recursive: true);
    File(p.join(hashDir, 'uuid-abc.recorded_inputs'))
        .writeAsStringSync('inputs');

    Link(p.join(ob1, 'external', 'my_repo')).createSync(cacheEntry);
    Link(p.join(ob2, 'external', 'my_repo')).createSync(cacheEntry);

    expect(
      () => verifyOutputBases(
        outputBase1: ob1,
        outputBase2: ob2,
        reproducibleRepos: ['my_repo'],
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
        reproducibleRepos: [],
        probeRepos: ['probe'],
      ),
      returnsNormally,
    );
  });

  test(
    'fails when reproducible repo is a real directory instead of symlink',
    () {
      Directory(p.join(ob1, 'external', 'my_repo')).createSync(recursive: true);
      Directory(p.join(ob2, 'external', 'my_repo')).createSync(recursive: true);

      expect(
        () => verifyOutputBases(
          outputBase1: ob1,
          outputBase2: ob2,
          reproducibleRepos: ['my_repo'],
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains(
              'Expected external/my_repo in output base 1 to be a symlink',
            ),
          ),
        ),
      );
    },
  );

  test('fails when symlinks point to different cache entries', () {
    final hashDir1 = p.join(rcc, 'hash1');
    final hashDir2 = p.join(rcc, 'hash2');
    final entry1 = p.join(hashDir1, 'uuid-1');
    final entry2 = p.join(hashDir2, 'uuid-2');
    Directory(entry1).createSync(recursive: true);
    Directory(entry2).createSync(recursive: true);

    Link(p.join(ob1, 'external', 'my_repo')).createSync(entry1);
    Link(p.join(ob2, 'external', 'my_repo')).createSync(entry2);

    expect(
      () => verifyOutputBases(
        outputBase1: ob1,
        outputBase2: ob2,
        reproducibleRepos: ['my_repo'],
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('point to different cache entries'),
        ),
      ),
    );
  });

  test('fails when contents/<hash>/ holds multiple directory entries', () {
    final hashDir = p.join(rcc, 'hash123');
    final entry1 = p.join(hashDir, 'uuid-1');
    final entry2 = p.join(hashDir, 'uuid-2');
    Directory(entry1).createSync(recursive: true);
    Directory(entry2).createSync(recursive: true);

    Link(p.join(ob1, 'external', 'my_repo')).createSync(entry1);
    Link(p.join(ob2, 'external', 'my_repo')).createSync(entry1);

    expect(
      () => verifyOutputBases(
        outputBase1: ob1,
        outputBase2: ob2,
        reproducibleRepos: ['my_repo'],
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Expected contents/hash123/ to hold 1 entry, but found 2'),
        ),
      ),
    );
  });

  test('fails when probe repo is a symlink', () {
    final hashDir = p.join(rcc, 'hash123');
    final entry = p.join(hashDir, 'uuid-1');
    Directory(entry).createSync(recursive: true);

    Link(p.join(ob1, 'external', 'probe')).createSync(entry);
    Link(p.join(ob2, 'external', 'probe')).createSync(entry);

    expect(
      () => verifyOutputBases(
        outputBase1: ob1,
        outputBase2: ob2,
        reproducibleRepos: [],
        probeRepos: ['probe'],
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains(
            'Expected probe repo probe in output base 1 to be a real directory',
          ),
        ),
      ),
    );
  });

  test('scanner sha256 verification passes when files are identical', () {
    final scannerDir1 = p.join(ob1, 'external', 'dart_pub_scanner');
    final scannerDir2 = p.join(ob2, 'external', 'dart_pub_scanner');
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
      ),
      returnsNormally,
    );
  });

  test('scanner sha256 verification fails when files differ', () {
    final scannerDir1 = p.join(ob1, 'external', 'dart_pub_scanner');
    final scannerDir2 = p.join(ob2, 'external', 'dart_pub_scanner');
    Directory(scannerDir1).createSync(recursive: true);
    Directory(scannerDir2).createSync(recursive: true);

    File(p.join(scannerDir1, 'scanner')).writeAsStringSync('binary contents A');
    File(p.join(scannerDir2, 'scanner')).writeAsStringSync('binary contents B');

    expect(
      () => verifyScannerSha256(
        outputBase1: ob1,
        outputBase2: ob2,
        scannerRepo: 'dart_pub_scanner',
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Scanner binary SHA-256 mismatch'),
        ),
      ),
    );
  });

  test(
    'resolveCanonicalRepo handles apparent, canonical, and prefixed names',
    () {
      final mapping = {
        'dart_linux-x64': '+dart+dart_linux-x64',
        'pub_deps': 'ai_rules_dart++pub+pub_deps',
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
        resolveCanonicalRepo('+dart+dart_linux-x64', mapping),
        '+dart+dart_linux-x64',
      );
      expect(
        resolveCanonicalRepo('ai_rules_dart++pub+pub_deps', mapping),
        'ai_rules_dart++pub+pub_deps',
      );
      expect(resolveCanonicalRepo('unknown_repo', mapping), 'unknown_repo');
    },
  );

  test('createCheckScratchDir returns directory outside workspace', () {
    final wsDir = Directory.current.path;
    final scratch = createCheckScratchDir(wsDir);
    try {
      expect(p.isAbsolute(scratch.path), isTrue);
      expect(scratch.path, isNot(equals(p.canonicalize(wsDir))));
      expect(p.isWithin(p.canonicalize(wsDir), scratch.path), isFalse);
      expect(scratch.existsSync(), isTrue);
    } finally {
      scratch.deleteSync(recursive: true);
    }
  });

  test('createCheckScratchDir avoids candidates inside workspace', () {
    final fakeWs = p.join(tempDir.path, 'fake_ws');
    Directory(fakeWs).createSync(recursive: true);
    final insideCandidate = p.join(fakeWs, '.tmp');
    Directory(insideCandidate).createSync(recursive: true);

    final scratch = createCheckScratchDir(
      fakeWs,
      environment: {
        'BUILD_WORKING_DIRECTORY': fakeWs,
        'TMPDIR': insideCandidate,
      },
    );
    try {
      final canonicalWs = p.canonicalize(fakeWs);
      expect(scratch.path, isNot(equals(canonicalWs)));
      expect(p.isWithin(canonicalWs, scratch.path), isFalse);
      expect(scratch.existsSync(), isTrue);
    } finally {
      scratch.deleteSync(recursive: true);
    }
  });
}
