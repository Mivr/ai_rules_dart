import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'actions_golden.dart';

void main() {
  final Directory temp = Directory.systemTemp.createTempSync(
    'actions_golden_test_',
  );
  tearDownAll(() => temp.deleteSync(recursive: true));
  final harness = _TestHarness(temp);

  _registerPathNormaliseTests(harness);
  _registerActionOrderingTests(harness);
  _registerCheckTests(harness);
  _registerIoAndRunfilesTests(harness);
}

final class _TestHarness {
  new(this.temp);

  final Directory temp;

  String query(String name) => _locateFixture(name);

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
}

void _registerPathNormaliseTests(_TestHarness h) {
  group('normalisePath', () {
    test('replaces each output directory and respects segment boundaries', () {
      expect(normalisePath('bazel-out/k8-fastbuild/bin/a'), '{bindir}/a');
      expect(normalisePath('bazel-out/k8-fastbuild/bin'), '{bindir}');
      expect(
        normalisePath('bazel-out/k8-fastbuild/genfiles/a'),
        '{genfilesdir}/a',
      );
      expect(
        normalisePath('bazel-out/k8-fastbuild/testlogs/a'),
        '{testlogsdir}/a',
      );
      expect(normalisePath('bazel-out/k8-opt-exec/a'), '{bazel-out}/a');
      expect(
        normalisePath('bazel-out/k8-opt-exec/binary'),
        '{bazel-out}/binary',
      );
    });

    test('replaces segments inside flags and host SDK repositories', () {
      expect(
        normalisePath('--out=bazel-out/k8-fastbuild/bin/a'),
        '--out={bindir}/a',
      );
      expect(
        normalisePath('external/+dart+dart_linux-x64/bin/dart'),
        'external/{dart-sdk}/bin/dart',
      );
      expect(
        normalisePath('external/+dart+dart_macos-arm64/bin/dart'),
        'external/{dart-sdk}/bin/dart',
      );
    });
  });

  test('normalises arguments, inputs, outputs and environment', () {
    final List<Map<String, Object?>> actions = normaliseAquery(
      _readJson(h.query('base.json')),
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
}

void _registerActionOrderingTests(_TestHarness h) {
  test(
    'resolves aspectDescriptorIds and sorts by target, aspect, mnemonic',
    () {
      final List<Map<String, Object?>> actions = normaliseAquery({
        'targets': [
          {'id': '1', 'label': '//pkg:lib'},
        ],
        'aspectDescriptors': [
          {'id': '1', 'name': '//dart:a.bzl%aspect_a'},
          {'id': '2', 'name': '//dart:b.bzl%aspect_b'},
        ],
        'artifacts': [
          {'id': '10', 'path': 'bazel-out/k8-fastbuild/bin/b.out'},
          {'id': '11', 'path': 'bazel-out/k8-fastbuild/bin/a.out'},
        ],
        'actions': [
          {
            'targetId': '1',
            'aspectDescriptorIds': ['2'],
            'mnemonic': 'Act',
            'outputIds': ['10'],
            'primaryOutputId': '10',
          },
          {
            'targetId': '1',
            'aspectDescriptorIds': ['1'],
            'mnemonic': 'Act',
            'outputIds': ['11'],
            'primaryOutputId': '11',
          },
        ],
      });
      expect(actions.map((a) => a['aspect']).toList(), [
        '//dart:a.bzl%aspect_a',
        '//dart:b.bzl%aspect_b',
      ]);
    },
  );

  test('orders actions independently of their input order', () {
    expect(h.goldenOf('order_b.json'), h.goldenOf('order_a.json'));
  });

  test('keeps Symlink staging actions rather than dropping them', () {
    final List<Map<String, Object?>> actions = normaliseAquery(
      _readJson(h.query('symlink.json')),
    );
    expect(actions.map((action) => action['mnemonic']).toList(), [
      'DartCompile',
      'Symlink',
    ]);
  });

  test('writes one action per line', () {
    final List<String> lines = h.goldenOf('base.json').split('\n');
    final Iterable<String> actions = lines.where(
      (line) => line.trimLeft().startsWith('{ '),
    );
    expect(actions, hasLength(4));
  });
}

void _registerCheckTests(_TestHarness h) {
  test('--check accepts a matching golden', () {
    expect(h.check('base.json', h.goldenOf('base.json')).exitCode, 0);
  });

  test('--check rejects an added action', () {
    final GoldenResult result = h.check('added.json', h.goldenOf('base.json'));
    expect(result.exitCode, 1);
    expect(result.error, contains('is stale'));
    expect(result.error, contains('DartExtra'));
  });

  test('--check rejects a removed action', () {
    final GoldenResult result = h.check(
      'removed.json',
      h.goldenOf('base.json'),
    );
    expect(result.exitCode, 1);
    expect(result.error, contains('DartCopyTree'));
  });

  test('--check rejects a removed Symlink action', () {
    final GoldenResult result = h.check(
      'base.json',
      h.goldenOf('symlink.json'),
    );
    expect(result.exitCode, 1);
    expect(result.error, contains('Symlink'));
  });

  test('--check rejects a changed mnemonic', () {
    final GoldenResult result = h.check(
      'mnemonic.json',
      h.goldenOf('base.json'),
    );
    expect(result.exitCode, 1);
    expect(result.error, contains('DartCompileChanged'));
  });

  test('--check fails when the golden is absent', () {
    final GoldenResult result = GoldenRunner(
      goldenPath: '${h.temp.path}/absent.golden.json',
    ).run(['--check', h.query('base.json')]);
    expect(result.exitCode, 2);
    expect(result.error, contains('does not exist'));
  });

  test('--check fails on malformed jsonproto and syntax errors', () {
    final String golden = h.writeGolden(
      'valid.golden.json',
      h.goldenOf('base.json'),
    );
    expect(
      GoldenRunner(goldenPath: golden)
          .run(['--check', h.query('malformed.json')])
          .error,
      contains('malformed jsonproto'),
    );
    final GoldenResult badJson = GoldenRunner(
      goldenPath: golden,
      readStdin: () => '{broken json',
    ).run(['--check']);
    expect(badJson.exitCode, 2);
    expect(badJson.error, contains('malformed jsonproto in stdin'));
  });

  test('--check fails on a malformed golden', () {
    final GoldenResult result = h.check('base.json', '{"actions": [');
    expect(result.exitCode, 2);
    expect(result.error, contains('malformed golden'));
  });

  test('--check fails on a missing aquery file', () {
    final GoldenResult result = GoldenRunner(
      goldenPath: h.writeGolden('present.golden.json', h.goldenOf('base.json')),
    ).run(['--check', '${h.temp.path}/missing.json']);
    expect(result.exitCode, 2);
    expect(result.error, contains('missing.json'));
  });
}

void _registerIoAndRunfilesTests(_TestHarness h) {
  test('write mode writes the golden and check never modifies it', () {
    final path = '${h.temp.path}/written.golden.json';
    final GoldenResult written = GoldenRunner(
      goldenPath: path,
      workspaceRoot: h.temp.path,
    ).run([h.query('base.json')]);
    expect(written.exitCode, 0);
    final String expected = h.goldenOf('base.json');
    expect(File(path).readAsStringSync(), expected);
    expect(
      GoldenRunner(goldenPath: path)
          .run(['--check', h.query('base.json')])
          .exitCode,
      0,
    );
    final GoldenResult stale = GoldenRunner(goldenPath: path)
        .run(['--check', h.query('added.json')]);
    expect(stale.exitCode, 1);
    expect(File(path).readAsStringSync(), expected);
  });

  test('reads stdin when no path argument is supplied', () {
    final String rawBase = File(h.query('base.json')).readAsStringSync();
    final String golden = h.writeGolden(
      'stdin.golden.json',
      h.goldenOf('base.json'),
    );
    final GoldenResult ok = GoldenRunner(
      goldenPath: golden,
      readStdin: () => rawBase,
    ).run(['--check']);
    expect(ok.exitCode, 0);
  });

  test('resolves relative input paths and manifest-only runfiles', () {
    final sub = Directory('${h.temp.path}/caller_cwd')..createSync();
    File('${sub.path}/rel.json')
        .writeAsStringSync(File(h.query('base.json')).readAsStringSync());
    final String golden = h.writeGolden(
      'manifest.golden.json',
      h.goldenOf('base.json'),
    );
    final runfiles = Runfiles.fromState(
      manifest: {'ai_rules_dart/$goldenRelativePath': golden},
    );
    final GoldenResult result = GoldenRunner(
      runfiles: runfiles,
      workingDirectory: sub.path,
    ).run(['--check', 'rel.json']);
    expect(result.exitCode, 0);
  });

  test('rejects an unknown option', () {
    final GoldenResult result = const GoldenRunner().run(['--unknown']);
    expect(result.exitCode, 2);
    expect(result.error, contains('--unknown'));
  });
}

String _locateFixture(String name) {
  const rel = 'dart/tests/corpus/testdata';
  final String? fromRunfiles = locateCorpusRunfile('$rel/$name');
  if (fromRunfiles != null) return fromRunfiles;
  final fallback = File('$rel/$name');
  if (fallback.existsSync()) return fallback.path;
  fail('cannot locate fixture testdata/$name in runfiles');
}

Map<String, Object?> _readJson(String path) {
  final Object? decoded = jsonDecode(File(path).readAsStringSync());
  if (decoded is! Map) {
    fail('$path is not a JSON object');
  }
  return Map<String, Object?>.from(decoded);
}
