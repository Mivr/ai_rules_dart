/// Offline tests for the repo contents cache checks, on fake directory trees.
library;

import 'dart:io';

import 'package:test/test.dart';

import '../cache_check.dart';

/// Where a fake output base and its repo contents cache live.
typedef _Layout = ({String base, String hashDir});

/// Makes `<hashDir>/<entry>` and links `<base>/external/<repo>` to it.
String _cached(_Layout layout, String repo, {String entry = 'uuid-1'}) {
  final dir = Directory('${layout.hashDir}/$entry')
    ..createSync(recursive: true);
  File('${dir.path}/BUILD.bazel').writeAsStringSync('');
  Directory('${layout.base}/external').createSync(recursive: true);
  Link('${layout.base}/external/$repo').createSync(dir.path);
  return dir.path;
}

void main() {
  late Directory root;
  late _Layout fake;

  setUp(() {
    root = Directory.systemTemp.createTempSync('cache_check_test_');
    fake = (base: '${root.path}/base', hashDir: '${root.path}/cache/abc123');
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('findUnsafeLinks', () {
    test('accepts a tree with files and in-repo relative links', () {
      final String entry = _cached(fake, 'repo');
      Directory('$entry/lib/src').createSync(recursive: true);
      File('$entry/lib/a.dart').writeAsStringSync('');
      Link('$entry/lib/src/a.dart').createSync('../a.dart');
      Link('$entry/lib/alias').createSync('src');
      expect(findUnsafeLinks(entry), isEmpty);
    });

    test('refuses an absolute symlink', () {
      final String entry = _cached(fake, 'repo');
      Link('$entry/usr_lib').createSync('/usr/lib');
      final List<String> problems = findUnsafeLinks(entry);
      expect(problems, hasLength(1));
      expect(problems.single, contains('usr_lib -> /usr/lib'));
      expect(problems.single, contains('absolute'));
    });

    test('refuses a relative symlink that leaves the repository', () {
      final String entry = _cached(fake, 'repo');
      Directory('$entry/lib').createSync();
      Link('$entry/lib/out').createSync('../../outside');
      final List<String> problems = findUnsafeLinks(entry);
      expect(problems.single, contains('lib/out -> ../../outside'));
      expect(problems.single, contains('leaves the repository'));
    });

    test('refuses an escaping link nested deep in the tree', () {
      final String entry = _cached(fake, 'repo');
      Directory('$entry/a/b/c').createSync(recursive: true);
      Link('$entry/a/b/c/up').createSync('../../../../x');
      expect(findUnsafeLinks(entry), hasLength(1));
    });

    test('accepts a link that climbs and re-enters the repository', () {
      final String entry = _cached(fake, 'repo');
      Directory('$entry/a/b').createSync(recursive: true);
      Directory('$entry/c').createSync();
      Link('$entry/a/b/ok').createSync('../../c');
      expect(findUnsafeLinks(entry), isEmpty);
    });
  });

  group('escapesRoot', () {
    test('resolves dot segments lexically', () {
      expect(escapesRoot(<String>['a'], './../b'), isFalse);
      expect(escapesRoot(<String>['a'], '../../b'), isTrue);
      expect(escapesRoot(<String>[], '..'), isTrue);
    });

    test('treats drive-letter and rooted targets as absolute', () {
      expect(isAbsoluteTarget(r'C:\Users\x'), isTrue);
      expect(isAbsoluteTarget('/tmp'), isTrue);
      expect(isAbsoluteTarget('lib/a'), isFalse);
    });
  });

  group('checkCachedRepo', () {
    test('accepts a symlink to a single clean cache entry', () {
      final String entry = _cached(fake, 'repo');
      final CachedCheck checked = checkCachedRepo((
        outputBase: fake.base,
        repo: 'repo',
      ));
      expect(checked.problems, isEmpty);
      expect(checked.entry, entry);
    });

    test('refuses a real directory in the output base', () {
      Directory('${fake.base}/external/repo').createSync(recursive: true);
      final CachedCheck checked = checkCachedRepo((
        outputBase: fake.base,
        repo: 'repo',
      ));
      expect(checked.entry, isNull);
      expect(checked.problems.single, contains('not a cache symlink'));
    });

    test('does not count the recorded-inputs file as an entry', () {
      _cached(fake, 'repo');
      File('${fake.hashDir}/uuid-1.recorded_inputs').writeAsStringSync('');
      final CachedCheck checked = checkCachedRepo((
        outputBase: fake.base,
        repo: 'repo',
      ));
      expect(checked.problems, isEmpty);
    });

    test('refuses a hash directory holding two extractions', () {
      _cached(fake, 'repo');
      Directory('${fake.hashDir}/uuid-2').createSync();
      final CachedCheck checked = checkCachedRepo((
        outputBase: fake.base,
        repo: 'repo',
      ));
      expect(checked.problems.single, contains('holds 2 entries'));
    });

    test('names the repo when its cache entry holds an absolute link', () {
      final String entry = _cached(fake, 'repo');
      Link('$entry/host').createSync('/etc');
      final CachedCheck checked = checkCachedRepo((
        outputBase: fake.base,
        repo: 'repo',
      ));
      expect(checked.problems.single, startsWith('repo: host -> /etc'));
    });
  });

  group('checkRealDirectory', () {
    test('accepts a real directory', () {
      Directory('${fake.base}/external/repo').createSync(recursive: true);
      expect(
        checkRealDirectory((outputBase: fake.base, repo: 'repo')),
        isEmpty,
      );
    });

    test('refuses a cache symlink', () {
      _cached(fake, 'repo');
      expect(
        checkRealDirectory((outputBase: fake.base, repo: 'repo')),
        hasLength(1),
      );
    });
  });
}
