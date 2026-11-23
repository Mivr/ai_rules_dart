/// Unit tests for the corpus action-golden normaliser and checker.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'actions_golden.dart';

String _dataPath(String name) {
  final candidates = <String>[
    'testdata/$name',
    'flutter/tests/corpus/testdata/$name',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  final roots = <String>[
    ?Platform.environment['RUNFILES_DIR'],
    ?Platform.environment['TEST_SRCDIR'],
  ];
  final suffix = 'flutter/tests/corpus/testdata/$name';
  for (final root in roots) {
    final directory = Directory(root);
    if (!directory.existsSync()) continue;
    for (final FileSystemEntity entity in directory.listSync(
      recursive: true,
    )) {
      final String path = entity.path.replaceAll(r'\', '/');
      if (entity is File && path.endsWith(suffix)) return entity.path;
    }
  }
  throw StateError('testdata/$name is not in the test runfiles');
}

String _fixture(String name) => File(_dataPath(name)).readAsStringSync();

List<Map<String, dynamic>> _goldenActions(String golden) {
  final doc = jsonDecode(golden) as Map<String, dynamic>;
  return <Map<String, dynamic>>[
    for (final Object? action in doc['actions'] as List<dynamic>)
      jsonDecode(action! as String) as Map<String, dynamic>,
  ];
}

Map<String, dynamic> _decoded(String name) =>
    jsonDecode(_fixture(name)) as Map<String, dynamic>;

void main() {
  late Directory temp;
  setUpAll(() => temp = Directory.systemTemp.createTempSync('corpus_golden_'));
  tearDownAll(() => temp.deleteSync(recursive: true));

  test('normalises every configuration-specific output root', () {
    final String golden = normalizedGolden(_fixture('input_a.json'));
    expect(golden, contains('{bindir}/pkg/a.out'));
    expect(golden, contains('{genfilesdir}/g.txt'));
    expect(golden, contains('{testlogsdir}/t.log'));
    expect(golden, contains('{bindir}/other'));
    expect(golden, isNot(contains('bazel-out/')));
    expect(golden, isNot(contains('k8-fastbuild')));
    expect(golden, isNot(contains('k8-opt')));
  });

  test('drops the test-only Dart analyzer aspects', () {
    final Map<String, dynamic> doc = _decoded('input_aspects.json');
    (doc['aspectDescriptors'] as List<dynamic>).add(<String, dynamic>{
      'id': 3,
      'name': '@@repo+//dart:analyze.bzl%dart_analyze',
    });
    (doc['actions'] as List<dynamic>).add(<String, dynamic>{
      'targetId': 1,
      'aspectDescriptorIds': <int>[3],
      'mnemonic': 'DartFormat',
      'primaryOutputId': 1,
      'outputIds': <int>[1],
    });
    final String golden = normalizedGolden(jsonEncode(doc));
    expect(
      _goldenActions(golden).where(
        (Map<String, dynamic> action) => action['mnemonic'] == 'DartFormat',
      ),
      isEmpty,
    );
  });

  test('resolves aspect descriptor ids to their labels', () {
    final String golden = normalizedGolden(_fixture('input_aspects.json'));
    expect(
      _goldenActions(golden).single['aspect'],
      '@repo//:b.bzl%aspect_b,@repo//:a.bzl%aspect_a',
    );
  });

  test('sorts actions independently of their input order', () {
    expect(
      normalizedGolden(_fixture('input_a.json')),
      normalizedGolden(_fixture('input_a_shuffled.json')),
    );
  });

  test('an added action changes the golden', () {
    final Map<String, dynamic> doc = _decoded('input_a.json');
    final actions = doc['actions'] as List<dynamic>;
    actions.add(Map<String, dynamic>.from(actions.first as Map));
    expect(
      normalizedGolden(jsonEncode(doc)),
      isNot(normalizedGolden(_fixture('input_a.json'))),
    );
  });

  test('a removed action changes the golden', () {
    final Map<String, dynamic> doc = _decoded('input_a.json');
    (doc['actions'] as List<dynamic>).removeAt(0);
    expect(
      normalizedGolden(jsonEncode(doc)),
      isNot(normalizedGolden(_fixture('input_a.json'))),
    );
  });

  test('a changed mnemonic changes the golden', () {
    final Map<String, dynamic> doc = _decoded('input_a.json');
    final actions = doc['actions'] as List<dynamic>;
    (actions.first as Map<String, dynamic>)['mnemonic'] = 'Renamed';
    expect(
      normalizedGolden(jsonEncode(doc)),
      isNot(normalizedGolden(_fixture('input_a.json'))),
    );
  });

  test('--check passes against the checked-in fixture golden', () {
    expect(
      runActionsGolden(
        ['--check', _dataPath('input_a.json')],
        goldenPath: _dataPath('golden_a.json'),
      ),
      0,
    );
  });

  test('--check reads aquery from stdin when no path is given', () {
    expect(
      runActionsGolden(
        ['--check'],
        stdinText: _fixture('input_a.json'),
        goldenPath: _dataPath('golden_a.json'),
      ),
      0,
    );
  });

  test('--check exits 1 on a difference and never rewrites the golden', () {
    final Map<String, dynamic> doc = _decoded('input_a.json');
    final actions = doc['actions'] as List<dynamic>;
    (actions.first as Map<String, dynamic>)['mnemonic'] = 'Renamed';
    final input = File('${temp.path}/changed.json')
      ..writeAsStringSync(jsonEncode(doc));
    final golden = File('${temp.path}/kept.golden.json')
      ..writeAsStringSync(_fixture('golden_a.json'));
    expect(
      runActionsGolden(
        ['--check', input.path],
        goldenPath: golden.path,
      ),
      1,
    );
    expect(golden.readAsStringSync(), _fixture('golden_a.json'));
  });

  test('--check fails naming an absent golden', () {
    expect(
      () => runActionsGolden(
        ['--check', _dataPath('input_a.json')],
        goldenPath: '${temp.path}/absent.golden.json',
      ),
      throwsA(
        isA<ActionsGoldenError>().having(
          (error) => error.message,
          'message',
          contains('checked-in golden not found'),
        ),
      ),
    );
  });

  test('malformed jsonproto fails naming the source', () {
    expect(
      () => runActionsGolden(
        ['--check', _dataPath('malformed.txt')],
        goldenPath: _dataPath('golden_a.json'),
      ),
      throwsA(
        isA<ActionsGoldenError>().having(
          (error) => error.message,
          'message',
          contains('malformed jsonproto'),
        ),
      ),
    );
  });

  test('a missing aquery argument file fails naming the path', () {
    expect(
      () => runActionsGolden(['${temp.path}/absent.json']),
      throwsA(
        isA<ActionsGoldenError>().having(
          (error) => error.message,
          'message',
          contains('aquery input file not found'),
        ),
      ),
    );
  });

  test('without --check it writes the normalised golden', () {
    final output = '${temp.path}/written.golden.json';
    expect(
      runActionsGolden(
        [_dataPath('input_a.json')],
        goldenPath: output,
      ),
      0,
    );
    expect(File(output).readAsStringSync(), _fixture('golden_a.json'));
  });
}
