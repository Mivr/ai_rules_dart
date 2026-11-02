import 'package:test/test.dart';

import 'test_runner_coverage.dart';

/// One source's entry in `package:coverage`'s collected JSON.
Map<String, dynamic> _entry(String source) => {
  'source': source,
  'script': {'type': '@Script', 'fixedId': true, 'id': 'x', 'uri': source},
  'hits': [3, 1, 4, 0, 5, 2],
  'funcHits': [3, 1],
  'funcNames': [3, 'main'],
  'branchHits': [4, 0, 5, 1],
};

Map<String, dynamic> _report(List<String> sources) => {
  'type': 'CodeCoverage',
  'coverage': [for (final s in sources) _entry(s)],
};

const _uriMap = {
  'package:pkg/a.dart': 'pkg/lib/a.dart',
  'file:///abs/pkg/lib/a.dart': 'pkg/lib/a.dart',
  'org-dartlang-root:///pkg/lib/b.dart': 'pkg/lib/b.dart',
};

void main() {
  group('lcovFromCoverage records', () {
    final LcovResult result = lcovFromCoverage(
      coverageJson: _report(['package:pkg/a.dart']),
      uriMap: _uriMap,
    );

    test('succeeds', () {
      expect(result.exitCode, 0);
      expect(result.error, isNull);
    });

    test('writes DA records and totals', () {
      expect(result.lcov, contains('DA:3,1\nDA:4,0\nDA:5,2\n'));
      expect(result.lcov, contains('LF:3\nLH:2\n'));
    });

    test('writes FN and FNDA records', () {
      expect(result.lcov, contains('FN:3,main\n'));
      expect(result.lcov, contains('FNDA:1,main\n'));
      expect(result.lcov, contains('FNF:1\nFNH:1\n'));
    });

    test('writes BRDA records', () {
      expect(result.lcov, contains('BRDA:4,0,0,0\n'));
      expect(result.lcov, contains('BRDA:5,0,0,1\n'));
    });

    test('ends the record', () {
      expect(result.lcov, endsWith('end_of_record\n'));
    });
  });

  group('lcovFromCoverage URI mapping', () {
    test('writes a workspace-relative SF for each URI form', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: _report([
          'package:pkg/a.dart',
          'org-dartlang-root:///pkg/lib/b.dart',
        ]),
        uriMap: _uriMap,
      );
      expect(result.lcov, contains('SF:pkg/lib/a.dart\n'));
      expect(result.lcov, contains('SF:pkg/lib/b.dart\n'));
      expect(result.lcov, isNot(contains('org-dartlang-root')));
      expect(result.lcov, isNot(contains('/abs/')));
    });

    test('merges two URIs of one file into one record', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: _report([
          'package:pkg/a.dart',
          'file:///abs/pkg/lib/a.dart',
        ]),
        uriMap: _uriMap,
      );
      expect('SF:pkg/lib/a.dart'.allMatches(result.lcov), hasLength(1));
      expect(result.lcov, contains('DA:5,4\n'));
    });

    test('leaves out a source the map does not name', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: _report(['package:pkg/a.dart', 'dart:core']),
        uriMap: _uriMap,
      );
      expect(result.lcov, isNot(contains('core')));
      expect('SF:'.allMatches(result.lcov), hasLength(1));
    });
  });

  group('lcovFromCoverage manifest', () {
    test('drops the SF records the manifest does not list', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: _report([
          'package:pkg/a.dart',
          'org-dartlang-root:///pkg/lib/b.dart',
        ]),
        uriMap: _uriMap,
        manifest: parseManifest(['pkg/lib/b.dart', '']),
      );
      expect(result.lcov, contains('SF:pkg/lib/b.dart\n'));
      expect(result.lcov, isNot(contains('pkg/lib/a.dart')));
    });

    test('spells an external repository either way', () {
      expect(
        parseManifest(['external/repo/x.dart', '../repo/y.dart', './z.dart']),
        {'repo/x.dart', 'repo/y.dart', 'z.dart'},
      );
    });
  });

  group('lcovFromCoverage failures', () {
    test('a partial collection is non-zero with no report', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: _report(['package:pkg/a.dart']),
        uriMap: _uriMap,
        partial: ['ERROR: An isolate exited without pausing'],
      );
      expect(result.exitCode, isNot(0));
      expect(result.lcov, isEmpty);
      expect(result.error, contains('partial'));
      expect(result.error, contains('exited without pausing'));
    });

    test('a scoped collection that loaded nothing is an empty report', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: {'coverage': <Object>[]},
        uriMap: _uriMap,
        scoped: true,
      );
      expect(result.exitCode, 0);
      expect(result.lcov, isEmpty);
    });

    test('a collection with nothing in it is non-zero', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: {'coverage': <Object>[]},
        uriMap: _uriMap,
      );
      expect(result.exitCode, isNot(0));
      expect(result.error, contains('no coverage'));
    });
  });

  group('packagesToCollect', () {
    test('names the packages of every mapped package: URI', () {
      expect(packagesToCollect(_uriMap, null), {'pkg'});
    });

    test('keeps only the packages a manifest lists', () {
      const map = {
        'package:a/a.dart': 'a/lib/a.dart',
        'package:b/b.dart': 'b/lib/b.dart',
        'org-dartlang-root:///t/test.dart': 't/test.dart',
      };
      expect(packagesToCollect(map, parseManifest(['b/lib/b.dart'])), {'b'});
      expect(packagesToCollect(map, parseManifest([])), isEmpty);
    });
  });
}
