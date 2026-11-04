import 'package:test/test.dart';

import 'test_runner_coverage.dart';

/// One source's entry in `package:coverage`'s collected JSON.
Map<String, dynamic> _entry(
  String source, {
  List<Object>? funcHits = const [3, 1],
  List<Object>? funcNames = const [3, 'main'],
}) => {
  'source': source,
  'script': {'type': '@Script', 'fixedId': true, 'id': 'x', 'uri': source},
  'hits': [3, 1, 4, 0, 5, 2],
  'funcHits': ?funcHits,
  'funcNames': ?funcNames,
  'branchHits': [4, 0, 5, 1],
};

Map<String, dynamic> _report(List<String> sources) => {
  'type': 'CodeCoverage',
  'coverage': [for (final s in sources) _entry(s)],
};

Map<String, dynamic> _entries(List<Map<String, dynamic>> entries) => {
  'type': 'CodeCoverage',
  'coverage': entries,
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

  group('lcovFromCoverage function records', () {
    const a = 'package:pkg/a.dart';
    const abs = 'file:///abs/pkg/lib/a.dart';

    test('writes FNDA:0 for an uncalled function', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: _entries([
          _entry(
            a,
            funcNames: [3, 'main', 10, 'unusedHelper'],
            funcHits: [3, 2, 10, 0],
          ),
        ]),
        uriMap: _uriMap,
      );
      expect(result.lcov, contains('FN:3,main\nFN:10,unusedHelper\n'));
      expect(result.lcov, contains('FNDA:2,main\nFNDA:0,unusedHelper\n'));
      expect(result.lcov, contains('FNF:2\nFNH:1\n'));
    });

    test('merging two zero-hit URIs keeps the function uncounted', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: _entries([
          _entry(a, funcNames: [10, 'f'], funcHits: [10, 0]),
          _entry(abs, funcNames: [10, 'f'], funcHits: [10, 0]),
        ]),
        uriMap: _uriMap,
      );
      expect(result.lcov, contains('FNDA:0,f\n'));
      expect(result.lcov, contains('FNF:1\nFNH:0\n'));
    });

    test('merging a zero-hit and a hit URI sums and counts it', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: _entries([
          _entry(a, funcNames: [10, 'f'], funcHits: [10, 0]),
          _entry(abs, funcNames: [10, 'f'], funcHits: [10, 4]),
        ]),
        uriMap: _uriMap,
      );
      expect(result.lcov, contains('FNDA:4,f\n'));
      expect(result.lcov, contains('FNF:1\nFNH:1\n'));
    });

    test('a name missing from funcHits is FNDA:0, never dropped', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: _entries([
          _entry(a, funcNames: [3, 'main', 10, 'gone'], funcHits: [3, 1]),
        ]),
        uriMap: _uriMap,
      );
      expect(result.lcov, contains('FNDA:0,gone\n'));
      expect(result.lcov, isNot(contains('null')));
      expect(result.lcov, contains('FNF:2\nFNH:1\n'));
    });

    test('without function coverage writes only line records', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: _entries([_entry(a, funcNames: null, funcHits: null)]),
        uriMap: _uriMap,
      );
      expect(result.lcov, contains('DA:3,1\n'));
      expect(result.lcov, contains('LF:3\nLH:2\n'));
      for (final tag in ['FN:', 'FNDA:', 'FNF:', 'FNH:']) {
        expect(result.lcov, isNot(contains(tag)));
      }
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
        {'external/repo/x.dart', 'external/repo/y.dart', 'z.dart'},
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

    test('a scoped collection that loaded nothing is non-zero', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: {'coverage': <Object>[]},
        uriMap: _uriMap,
        scoped: true,
      );
      expect(result.exitCode, isNot(0));
      expect(result.lcov, isEmpty);
      expect(result.error, contains('pkg/lib/a.dart'));
      expect(result.error, contains('pkg/lib/b.dart'));
    });

    test('a scoped collection with nothing mapped is empty with no map', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: {'coverage': <Object>[]},
        uriMap: const {},
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

  group('lcovFromCoverage exec paths', () {
    const generated = 'bazel-out/k8-fastbuild/bin/pkg/lib/a.g.dart';
    const external = 'external/repo+/lib/x.dart';
    const map = {
      'package:pkg/a.dart': 'pkg/lib/a.dart',
      'package:pkg/a.g.dart': generated,
      'package:repo/x.dart': external,
    };

    test('parseManifest keeps a generated and an external exec path', () {
      expect(
        parseManifest([
          generated,
          '../repo+/lib/x.dart',
          r'.\pkg\lib\a.dart',
          'external/repo+/lib/x.dart',
        ]),
        {generated, external, 'pkg/lib/a.dart'},
      );
    });

    test('a generated source is kept and written under its exec path', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: _report(['package:pkg/a.g.dart']),
        uriMap: map,
        manifest: parseManifest([generated]),
      );
      expect(result.exitCode, 0);
      expect(result.lcov, contains('SF:$generated\n'));
    });

    test('an external source is written under external/', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: _report(['package:repo/x.dart']),
        uriMap: {'package:repo/x.dart': '../repo+/lib/x.dart'},
        manifest: parseManifest(['../repo+/lib/x.dart']),
      );
      expect(result.exitCode, 0);
      expect(result.lcov, contains('SF:$external\n'));
      expect(result.lcov, isNot(contains('SF:../')));
    });

    test('a file: URI under any execroot resolves by exec path suffix', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: _report([
          'file:///sandbox/execroot/_main/pkg/lib/a.dart',
          'file:///sandbox/execroot/_main/$generated',
          'file:///sandbox/execroot/_main/$external',
        ]),
        uriMap: map,
      );
      expect(result.exitCode, 0);
      expect(result.lcov, contains('SF:pkg/lib/a.dart\n'));
      expect(result.lcov, contains('SF:$generated\n'));
      expect(result.lcov, contains('SF:$external\n'));
      expect(result.lcov, isNot(contains('sandbox')));
      expect(map.keys.any((k) => k.contains('sandbox')), isFalse);
    });

    test('the longest exec path wins and merges with the package: URI', () {
      const both = {
        'package:pkg/a.dart': 'pkg/lib/a.dart',
        'package:other/a.dart': 'bazel-out/k8-fastbuild/bin/pkg/lib/a.dart',
      };
      final LcovResult result = lcovFromCoverage(
        coverageJson: _report([
          'file:///root/bazel-out/k8-fastbuild/bin/pkg/lib/a.dart',
          'file:///root/pkg/lib/a.dart',
          'package:pkg/a.dart',
        ]),
        uriMap: both,
      );
      expect('SF:pkg/lib/a.dart\n'.allMatches(result.lcov), hasLength(1));
      expect(
        result.lcov,
        contains('SF:bazel-out/k8-fastbuild/bin/pkg/lib/a.dart\n'),
      );
      expect(result.lcov, contains('DA:3,2\n'));
    });

    test('a staged file resolves through its path key to its origin', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: _report(['file:///r/bazel-out/k8/bin/p/set/lib/s.dart']),
        uriMap: const {
          'bazel-out/k8/bin/p/set/lib/s.dart': 'p/lib/s.dart',
          'package:p/s.dart': 'p/lib/s.dart',
        },
      );
      expect(result.lcov, contains('SF:p/lib/s.dart\n'));
    });

    test('a manifest that lists Dart files none of which map is non-zero', () {
      for (final scoped in [false, true]) {
        final LcovResult result = lcovFromCoverage(
          coverageJson: _report(['dart:core']),
          uriMap: map,
          manifest: parseManifest(['z/b.dart', 'a/b.dart', 'notes.txt']),
          scoped: scoped,
        );
        expect(result.exitCode, 1);
        expect(result.lcov, isEmpty);
        expect(result.error, contains('a/b.dart, z/b.dart'));
        expect(result.error, isNot(contains('notes.txt')));
      }
    });

    test('a manifest with a sibling that maps still succeeds', () {
      final LcovResult result = lcovFromCoverage(
        coverageJson: _report(['package:pkg/a.dart']),
        uriMap: map,
        manifest: parseManifest(['pkg/lib/a.dart', 'pkg/lib/unused.dart']),
      );
      expect(result.exitCode, 0);
    });

    test('a manifest that lists no Dart file is an empty report', () {
      for (final lines in [
        <String>[],
        ['notes.txt', 'data.json'],
      ]) {
        final LcovResult result = lcovFromCoverage(
          coverageJson: _report(['package:pkg/a.dart']),
          uriMap: map,
          manifest: parseManifest(lines),
        );
        expect(result.exitCode, 0);
        expect(result.lcov, isEmpty);
        expect(result.error, isNull);
      }
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

  group('needsEveryLibrary', () {
    test('a file outside a package needs the unfiltered collection', () {
      expect(needsEveryLibrary(_uriMap, null), isTrue);
      expect(
        needsEveryLibrary(_uriMap, parseManifest(['pkg/lib/b.dart'])),
        isTrue,
      );
    });

    test('a map of package files stays scoped', () {
      const packaged = {
        'package:pkg/a.dart': 'pkg/lib/a.dart',
        'file:///abs/pkg/lib/a.dart': 'pkg/lib/a.dart',
        'org-dartlang-root:///pkg/lib/a.dart': 'pkg/lib/a.dart',
      };
      expect(needsEveryLibrary(packaged, null), isFalse);
      expect(
        needsEveryLibrary(packaged, parseManifest(['pkg/lib/a.dart'])),
        isFalse,
      );
    });

    test('the manifest decides which files count', () {
      const mixed = {
        'package:pkg/a.dart': 'pkg/lib/a.dart',
        'org-dartlang-root:///t/test.dart': 't/test.dart',
      };
      expect(
        needsEveryLibrary(mixed, parseManifest(['pkg/lib/a.dart'])),
        isFalse,
      );
      expect(needsEveryLibrary(mixed, parseManifest(['t/test.dart'])), isTrue);
    });
  });
}
