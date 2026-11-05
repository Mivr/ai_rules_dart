import 'dart:convert';
import 'dart:io';

import 'package:coverage_map_fixture/generated.dart';
import 'package:coverage_map_fixture/plain.dart';
import 'package:coverage_map_set/gen_in_set.dart';
import 'package:coverage_map_set/in_set.dart';
import 'package:path/path.dart' as p;
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'test_runner_coverage.dart';

/// The `<name>.coverage_map.json` `dart_test` generated for this very test.
Map<String, String> generatedMap() {
  final String workspace = Platform.environment['TEST_WORKSPACE'] ?? '_main';
  final String path = Runfiles.create().rlocation(
    '$workspace/dart/tests/coverage_map_fixture/'
    'coverage_map_test.coverage_map.json',
  );
  final raw = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return {for (final e in raw.entries) e.key: e.value as String};
}

final RegExp _binExecPath = RegExp('^bazel-out/[^/]+/bin/');

void main() {
  // The imports are what puts the three libraries in this test's closure.
  test('the closure is compiled', () {
    expect([plain(), generated(), inSet(), genInSet()], [0, 1, 2, 3]);
    expect(p.basename('a/b'), 'b');
  });

  final Map<String, String> map = generatedMap();
  const pkgDir = 'dart/tests/coverage_map_fixture';

  test('a generated source maps to its bazel-out exec path', () {
    final String? path = map['package:coverage_map_fixture/generated.dart'];
    expect(path, matches(_binExecPath));
    expect(path, endsWith('/bin/$pkgDir/lib/generated.dart'));
    expect(map['org-dartlang-root:///$pkgDir/lib/generated.dart'], path);
    expect(
      map['package:coverage_map_fixture/plain.dart'],
      '$pkgDir/lib/plain.dart',
    );
  });

  test('an external source maps to external/<repo>', () {
    final String path = map['package:path/path.dart']!;
    expect(path, startsWith('external/'));
    expect(path, endsWith('/lib/path.dart'));
    expect(path, isNot(startsWith('../')));
    expect(map['org-dartlang-root:///$path'], path);
  });

  test('a srcs_dir source maps to the exec path of the set input', () {
    expect(
      map['package:coverage_map_set/in_set.dart'],
      '$pkgDir/lib/in_set.dart',
    );
    expect(
      map['org-dartlang-root:///$pkgDir/set/lib/in_set.dart'],
      '$pkgDir/lib/in_set.dart',
    );
    final String? generatedInput =
        map['package:coverage_map_set/gen_in_set.dart'];
    expect(generatedInput, matches(_binExecPath));
    expect(generatedInput, endsWith('/bin/$pkgDir/lib/gen_in_set.dart'));
    // The staged copy's own path leads back to the input too.
    final String staged = map.keys.firstWhere(
      (k) => k.endsWith('/bin/$pkgDir/set/lib/in_set.dart'),
    );
    expect(map[staged], '$pkgDir/lib/in_set.dart');
  });

  test('no entry names a host path', () {
    for (final MapEntry<String, String> e in map.entries) {
      expect(e.value, isNot(startsWith('/')));
      expect(e.key, isNot(startsWith('file:')));
    }
  });

  test('the generated sources are named for the launcher', () {
    final String workspace = Platform.environment['TEST_WORKSPACE'] ?? '_main';
    final String path = Runfiles.create().rlocation(
      '$workspace/$pkgDir/coverage_map_test.coverage_generated',
    );
    final List<String> listed = File(path).readAsLinesSync();
    // `COVERAGE_MANIFEST` lists source files only, so under `bazel coverage` the
    // generated ones the instrumentation filter selects come by this list.
    expect(listed, isNot(contains('$pkgDir/lib/plain.dart')));
    if (Platform.environment.containsKey('COVERAGE_OUTPUT_FILE')) {
      expect(
        listed,
        containsAll([
          map['package:coverage_map_fixture/generated.dart'],
          map['package:coverage_map_set/gen_in_set.dart'],
        ]),
      );
    }
  });

  test('the launcher reports all three from the generated map', () {
    const root = 'file:///sandbox/execroot/_main';
    final List<String> exec = [
      map['package:coverage_map_fixture/generated.dart']!,
      map['package:path/path.dart']!,
      map['package:coverage_map_set/in_set.dart']!,
      map['package:coverage_map_set/gen_in_set.dart']!,
    ];
    final List<String> staged = [
      for (final k in map.keys)
        if (k.contains('/bin/$pkgDir/set/lib/')) '$root/$k',
    ];
    final Map<String, dynamic> report = {
      'coverage': [
        for (final u in [
          ...exec.map((e) => '$root/$e'),
          ...staged,
          'package:coverage_map_fixture/plain.dart',
        ])
          {
            'source': u,
            'script': {'type': '@Script', 'fixedId': true, 'id': 'x', 'uri': u},
            'hits': [3, 1],
          },
      ],
    };
    final LcovResult result = lcovFromCoverage(
      coverageJson: report,
      uriMap: map,
      manifest: parseManifest([...exec, '$pkgDir/lib/plain.dart']),
    );
    expect(result.error, isNull);
    for (final e in exec) {
      expect(result.lcov, contains('SF:$e\n'));
    }
    expect(result.lcov, contains('SF:$pkgDir/lib/plain.dart\n'));
    expect(result.lcov, isNot(contains('sandbox')));
  });
}
