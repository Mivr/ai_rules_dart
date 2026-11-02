import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'actions_golden.dart';

void main(List<String> args) {
  final String root = _workspaceRoot(args);
  final testdata = Directory('$root/dart/tests/corpus/testdata');
  final Directory temp = Directory.systemTemp.createTempSync(
    'actions_golden_test_',
  );
  tearDownAll(() => temp.deleteSync(recursive: true));

  String query(String name) => '${testdata.path}/$name';

  String goldenOf(String name) =>
      encodeGolden(normaliseAquery(_readJson(query(name))));

  String writeGolden(String name, String text) {
    final file = File('${temp.path}/$name');
    file.writeAsStringSync(text);
    return file.path;
  }

  GoldenResult check(String queryName, String goldenText) => GoldenRunner(
    goldenPath: writeGolden('$queryName.golden.json', goldenText),
  ).run(['--check', query(queryName)]);

  group('normalisePath', () {
    test('replaces each output directory', () {
      expect(normalisePath('bazel-out/k8-fastbuild/bin/a'), '{bindir}/a');
      expect(
        normalisePath('bazel-out/k8-fastbuild/genfiles/a'),
        '{genfilesdir}/a',
      );
      expect(
        normalisePath('bazel-out/k8-fastbuild/testlogs/a'),
        '{testlogsdir}/a',
      );
      expect(normalisePath('bazel-out/k8-opt-exec/a'), '{bazel-out}/a');
    });

    test('replaces a segment inside a longer argument', () {
      expect(
        normalisePath('--out=bazel-out/k8-fastbuild/bin/a'),
        '--out={bindir}/a',
      );
    });

    test('replaces the host-specific SDK repository', () {
      expect(
        normalisePath('external/+dart+dart_linux-x64/bin/dart'),
        'external/{dart-sdk}/bin/dart',
      );
    });
  });

  test('normalises arguments, inputs and outputs from the fixture', () {
    final List<Map<String, Object?>> actions = normaliseAquery(
      _readJson(query('base.json')),
    );
    final Map<String, Object?> compile = actions.firstWhere(
      (action) => action['mnemonic'] == 'DartCompile',
    );
    expect(compile['target'], '//pkg:lib');
    expect(compile['primaryOutput'], '{bindir}/pkg/main.dart');
    expect(compile['arguments'], contains('{bindir}/pkg/main.dart'));
    expect(compile['inputs'], contains('{bindir}/pkg/lib.dart'));
    expect(compile['outputs'], ['{bindir}/pkg/main.dart']);
  });

  test('orders actions independently of their input order', () {
    expect(goldenOf('order_b.json'), goldenOf('order_a.json'));
  });

  test('writes one action per line', () {
    final List<String> lines = goldenOf('base.json').split('\n');
    final Iterable<String> actions = lines.where(
      (line) => line.trimLeft().startsWith('{ '),
    );
    expect(actions, hasLength(4));
  });

  test('--check accepts a matching golden', () {
    expect(check('base.json', goldenOf('base.json')).exitCode, 0);
  });

  test('--check rejects an added action', () {
    final GoldenResult result = check('added.json', goldenOf('base.json'));
    expect(result.exitCode, 1);
    expect(result.error, contains('is stale'));
    expect(result.error, contains('DartExtra'));
  });

  test('--check rejects a removed action', () {
    final GoldenResult result = check('removed.json', goldenOf('base.json'));
    expect(result.exitCode, 1);
    expect(result.error, contains('DartCopyTree'));
  });

  test('--check rejects a changed mnemonic', () {
    final GoldenResult result = check('mnemonic.json', goldenOf('base.json'));
    expect(result.exitCode, 1);
    expect(result.error, contains('DartCompileChanged'));
  });

  test('--check fails when the golden is absent', () {
    final GoldenResult result = GoldenRunner(
      goldenPath: '${temp.path}/absent.golden.json',
    ).run(['--check', query('base.json')]);
    expect(result.exitCode, 2);
    expect(result.error, contains('does not exist'));
  });

  test('--check fails on malformed jsonproto', () {
    expect(
      GoldenRunner(
        goldenPath: writeGolden('valid.golden.json', goldenOf('base.json')),
      ).run(['--check', query('malformed.json')]).error,
      contains('malformed jsonproto'),
    );
  });

  test('--check fails on a malformed golden', () {
    final GoldenResult result = check('base.json', '{"actions": [');
    expect(result.exitCode, 2);
    expect(result.error, contains('malformed golden'));
  });

  test('--check fails on a missing aquery file', () {
    final GoldenResult result = GoldenRunner(
      goldenPath: writeGolden('present.golden.json', goldenOf('base.json')),
    ).run(['--check', '${temp.path}/missing.json']);
    expect(result.exitCode, 2);
    expect(result.error, contains('missing.json'));
  });

  test('write mode writes the golden and check reads it back', () {
    final path = '${temp.path}/written.golden.json';
    final GoldenResult written = GoldenRunner(
      goldenPath: path,
      workspaceRoot: temp.path,
    ).run([query('base.json')]);
    expect(written.exitCode, 0);
    expect(File(path).readAsStringSync(), goldenOf('base.json'));
    expect(
      GoldenRunner(goldenPath: path)
          .run(['--check', query('base.json')])
          .exitCode,
      0,
    );
  });

  test('--check never writes the golden', () {
    final String path = writeGolden(
      'unchanged.golden.json',
      goldenOf('base.json'),
    );
    final String before = File(path).readAsStringSync();
    final GoldenResult result = GoldenRunner(goldenPath: path)
        .run(['--check', query('added.json')]);
    expect(result.exitCode, 1);
    expect(File(path).readAsStringSync(), before);
  });

  test('rejects an unknown option', () {
    final GoldenResult result = GoldenRunner().run(['--unknown']);
    expect(result.exitCode, 2);
    expect(result.error, contains('--unknown'));
  });
}

Map<String, Object?> _readJson(String path) {
  final Object? decoded = jsonDecode(File(path).readAsStringSync());
  if (decoded is! Map) {
    fail('$path is not a JSON object');
  }
  return Map<String, Object?>.from(decoded);
}

String _workspaceRoot(List<String> args) {
  if (args.isNotEmpty) {
    final String start = File(Runfiles.create().rlocation(args.first))
        .parent
        .path;
    final String? root = _rootAbove(start);
    if (root != null) return root;
    fail('cannot find the workspace root above $start');
  }
  for (final String? start in [
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'],
    Directory.current.path,
  ]) {
    final String? root = _rootAbove(start ?? '');
    if (root != null) return root;
  }
  fail('cannot find the workspace root; run the test from the workspace');
}

String? _rootAbove(String start) {
  Directory? directory = start.isEmpty ? null : Directory(start);
  while (directory != null) {
    if (File('${directory.path}/MODULE.bazel').existsSync()) {
      return directory.path;
    }
    final Directory parent = directory.parent;
    if (parent.path == directory.path) return null;
    directory = parent;
  }
  return null;
}
