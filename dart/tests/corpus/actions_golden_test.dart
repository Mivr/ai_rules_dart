import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'actions_golden.dart';
import 'golden_digest.dart';

void main() {
  final Directory temp = Directory.systemTemp.createTempSync(
    'actions_golden_test_',
  );
  tearDownAll(() => temp.deleteSync(recursive: true));
  final harness = _TestHarness(temp);

  _registerPathNormaliseTests(harness);
  _registerHostPlatformTests();
  _registerActionOrderingTests(harness);
  _registerCheckTests(harness);
  _registerGraphTests(harness);
  _registerMalformedTests(harness);
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
    expect(compile['inputs'], {'count': 3, 'sha256': hasLength(64)});
    expect(compile['outputs'], ['{bindir}/pkg/main.dart']);
  });
}

void _registerHostPlatformTests() {
  final String linuxCorpusAssets = _nativeAssets('linux_x64', {
    'package:corpus/libcorpus.so': ['relative', 'libcorpus.so'],
  });
  final String macosCorpusAssets = _nativeAssets('macos_arm64', {
    'package:corpus/libcorpus.so': ['relative', 'libcorpus.so'],
  });
  const up = '../../../../../../../..';
  final String linuxSqliteAssets = _nativeAssets('linux_x64', {
    'package:sqlite3/src/ffi/libsqlite3.g.dart': [
      'relative',
      '$up/_solib_k8/_Udart_Sext_Ssqlite3/libsqlite3.so',
    ],
  });
  final String macosSqliteAssets = _nativeAssets('macos_arm64', {
    'package:sqlite3/src/ffi/libsqlite3.g.dart': [
      'relative',
      '$up/_solib_darwin_arm64/_Udart_Sext_Ssqlite3/libsqlite3.dylib',
    ],
  });
  const linuxBin = 'bazel-out/k8-fastbuild/bin';
  const macosBin = 'bazel-out/darwin_arm64-fastbuild/bin';
  const linuxRunfiles = [
    'pkg/a.dart',
    '$linuxBin/_solib_k8/_Udart_Sext_Ssqlite3/libsqlite3.so',
    '$linuxBin/dart/tests/corpus/libcorpus.so',
  ];
  const macosRunfiles = [
    'pkg/a.dart',
    '$macosBin/_solib_darwin_arm64/_Udart_Sext_Ssqlite3/libsqlite3.dylib',
    '$macosBin/dart/tests/corpus/libcorpus.dylib',
  ];

  group('host-platform tokens', () {
    test('the corpus FileWrite of app_bin is the same on Linux and macOS', () {
      expect(
        _fileWriteRecord(macosCorpusAssets),
        _fileWriteRecord(linuxCorpusAssets),
      );
      expect(
        _fileWriteRecord(linuxCorpusAssets)['fileContents'],
        contains('{target-os-arch}'),
      );
    });

    test('the corpus_test FileWrite is the same on Linux and macOS', () {
      expect(
        _fileWriteRecord(macosSqliteAssets),
        _fileWriteRecord(linuxSqliteAssets),
      );
      expect(
        _fileWriteRecord(linuxSqliteAssets)['fileContents'],
        contains('{solib-dir}/_Udart_Sext_Ssqlite3/libsqlite3{shlib-ext}'),
      );
    });

    test('the runfiles input closure digest is the same on both hosts', () {
      expect(_inputsOf(macosRunfiles), _inputsOf(linuxRunfiles));
      expect(_inputsOf(linuxRunfiles), {'count': 3, 'sha256': hasLength(64)});
    });

    test('normalises arguments, outputs and environment values too', () {
      final List<Map<String, Object?>> actions = normaliseAquery({
        'targets': [
          {'id': 1, 'label': '//pkg:lib'},
        ],
        'artifacts': [
          {'id': 1, 'path': 'bazel-out/k8-fastbuild/bin/_solib_k8/libx.so'},
        ],
        'actions': [
          {
            'targetId': 1,
            'mnemonic': 'Act',
            'arguments': ['--lib=_solib_k8/libx.so', '--os=linux_x64'],
            'outputIds': [1],
            'primaryOutputId': 1,
            'environmentVariables': [
              {'key': 'LIB', 'value': '_solib_k8/libx.so'},
            ],
          },
        ],
      });
      final Map<String, Object?> action = actions.single;
      expect(action['primaryOutput'], '{bindir}/{solib-dir}/libx{shlib-ext}');
      expect(action['outputs'], ['{bindir}/{solib-dir}/libx{shlib-ext}']);
      expect(action['arguments'], [
        '--lib={solib-dir}/libx{shlib-ext}',
        '--os={target-os-arch}',
      ]);
      expect(action['environmentVariables'], [
        {'key': 'LIB', 'value': '{solib-dir}/libx{shlib-ext}'},
      ]);
    });

    test('covers every native-asset OS and architecture and extension', () {
      for (final os in const ['linux', 'macos', 'windows', 'android', 'ios']) {
        for (final arch in const ['x64', 'arm64', 'arm', 'ia32', 'riscv64']) {
          expect(normalisePath('"${os}_$arch":'), '"{target-os-arch}":');
        }
      }
      expect(normalisePath('_solib_k8/'), '{solib-dir}/');
      expect(normalisePath('_solib_darwin_arm64/'), '{solib-dir}/');
      expect(normalisePath('_solib_x64_windows'), '{solib-dir}');
      expect(normalisePath('a/libx.so'), 'a/libx{shlib-ext}');
      expect(normalisePath('a/libx.dylib'), 'a/libx{shlib-ext}');
      expect(normalisePath('a/x.dll'), 'a/x{shlib-ext}');
    });

    test('a changed first-party value still changes the record', () {
      final Map<String, Object?> base = _fileWriteRecord(linuxCorpusAssets);
      expect(
        _fileWriteRecord(
          linuxCorpusAssets.replaceAll('package:corpus/', 'package:other/'),
        ),
        isNot(base),
      );
      expect(
        _fileWriteRecord(
          linuxCorpusAssets.replaceAll('"libcorpus.so"]', '"libother.so"]'),
        ),
        isNot(base),
      );
      expect(
        _inputsOf([...linuxRunfiles, 'pkg/extra.so']),
        isNot(_inputsOf(linuxRunfiles)),
      );
      expect(
        _inputsOf([
          'pkg/a.dart',
          '$linuxBin/_solib_k8/_Udart_Sext_Ssqlite3/libsqlite4.so',
          '$linuxBin/dart/tests/corpus/libcorpus.so',
        ]),
        isNot(_inputsOf(linuxRunfiles)),
      );
    });

    test('text that only resembles a token is left alone', () {
      for (final text in const [
        'libx.sox',
        'libx.so.1',
        'libx.dylibs',
        '.so',
        'my_solib_dir',
        'a_solib_k8',
        'linux_x64_extra',
        'xlinux_x64',
        'linux_directory_watcher.dart',
        'linux-x64',
        'solib_k8',
        'linux_x86',
        'freebsd_x64',
      ]) {
        expect(normalisePath(text), text, reason: text);
      }
    });
  });
}

/// The `native-assets` file the build writes, for one target key.
String _nativeAssets(String target, Map<String, List<String>> assets) =>
    jsonEncode({
      'format-version': [1, 0, 0],
      'native-assets': {target: assets},
    });

/// The record of one `FileWrite` action that writes [contents].
Map<String, Object?> _fileWriteRecord(String contents) {
  return normaliseAquery({
    'targets': [
      {'id': 1, 'label': '//pkg:app'},
    ],
    'artifacts': [
      {
        'id': 1,
        'path': 'bazel-out/k8-fastbuild/bin/pkg/app.native_assets.yaml',
      },
    ],
    'actions': [
      {
        'targetId': 1,
        'mnemonic': 'FileWrite',
        'fileContents': contents,
        'outputIds': [1],
        'primaryOutputId': 1,
      },
    ],
  }).single;
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

void _registerGraphTests(_TestHarness h) {
  test('sha256Hex matches the published vectors', () {
    expect(
      sha256Hex(utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      sha256Hex(utf8.encode('a' * 100)),
      '2816597888e4a0d3a36b82b83316ab32680eb8f00f8cd3b904d681246d285a0e',
    );
  });

  test('inputs follow transitiveDepSetIds to any depth', () {
    final Map<String, Object?> action = normaliseAquery(
      _readJson(h.query('nested.json')),
    ).single;
    expect(action['inputs'], {
      'count': 3,
      'sha256':
          'b6159dacdd2fe928827c4eeecaaed590d3f78fb388bafc011446ac842b7adda6',
    });
  });

  group('SDK inputs', () {
    const linuxSdk = [
      'external/+dart+dart_linux-x64/bin/dart',
      'external/+dart+dart_linux-x64/lib/_internal/linux_only.dill',
    ];
    const macosSdk = [
      'external/+dart+dart_macos-arm64/bin/dart',
      'external/+dart+dart_macos-arm64/bin/macos_only',
      'external/+dart+dart_macos-arm64/lib/_internal/macos_only.dill',
    ];
    const firstParty = ['pkg/a.dart', 'bazel-out/k8-fastbuild/bin/pkg/b.out'];

    test('classifies only paths under the normalised SDK repository', () {
      expect(isSdkInput('external/{dart-sdk}/bin/dart'), isTrue);
      expect(isSdkInput('external/{dart-sdk}'), isTrue);
      expect(isSdkInput('external/{dart-sdk}x/bin/dart'), isFalse);
      expect(isSdkInput('external/other/{dart-sdk}/bin'), isFalse);
      expect(isSdkInput('pkg/a.dart'), isFalse);
    });

    test('a Linux-like and a macOS-like SDK file set give the same inputs', () {
      expect(
        _inputsOf([...firstParty, ...linuxSdk]),
        _inputsOf([...firstParty, ...macosSdk]),
      );
      expect(_inputsOf([...firstParty, ...linuxSdk]), {
        'count': 2,
        'sha256': hasLength(64),
      });
    });

    test('a first-party input change still changes the inputs', () {
      final Object? base = _inputsOf([...firstParty, ...linuxSdk]);
      expect(
        _inputsOf([...firstParty, 'pkg/c.dart', ...linuxSdk]),
        isNot(base),
      );
      expect(_inputsOf(['pkg/a.dart', ...linuxSdk]), isNot(base));
      expect(
        _inputsOf(['pkg/a.dart', 'pkg/renamed.out', ...linuxSdk]),
        isNot(base),
      );
    });
  });

  test('--check rejects one changed nested input', () {
    final GoldenResult result = h.check(
      'nested_changed.json',
      h.goldenOf('nested.json'),
    );
    expect(result.exitCode, 1);
    expect(result.error, contains('is stale'));
  });

  test('--check rejects a changed executionInfo', () {
    expect(h.goldenOf('exec_a.json'), contains('"supports-workers"'));
    final GoldenResult result = h.check(
      'exec_b.json',
      h.goldenOf('exec_a.json'),
    );
    expect(result.exitCode, 1);
    expect(result.error, contains('no-sandbox'));
  });

  test('--check rejects a changed FileWrite content', () {
    expect(h.goldenOf('filewrite_a.json'), contains('{bindir}/pkg/tool'));
    final GoldenResult result = h.check(
      'filewrite_b.json',
      h.goldenOf('filewrite_a.json'),
    );
    expect(result.exitCode, 1);
    expect(result.error, contains('pkg/other'));
  });
}

void _registerMalformedTests(_TestHarness h) {
  for (final table in const [
    'targets',
    'artifacts',
    'depSetOfFiles',
    'pathFragments',
  ]) {
    test('fails naming the missing $table table', () {
      final GoldenResult result = h.check(
        'missing_$table.json',
        h.goldenOf('base.json'),
      );
      expect(result.exitCode, 2);
      expect(result.error, contains('"$table"'));
    });
  }

  test('fails naming the table of a dangling id', () {
    final GoldenResult result = h.check(
      'dangling_depset.json',
      h.goldenOf('base.json'),
    );
    expect(result.exitCode, 2);
    expect(result.error, contains('"depSetOfFiles"'));
    expect(result.error, contains('9'));
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

/// The `inputs` record of one action whose direct inputs are [paths].
Object? _inputsOf(List<String> paths) {
  return normaliseAquery({
    'targets': [
      {'id': 1, 'label': '//pkg:lib'},
    ],
    'artifacts': [
      for (var i = 0; i < paths.length; i++) {'id': i + 1, 'path': paths[i]},
    ],
    'depSetOfFiles': [
      {
        'id': 1,
        'directArtifactIds': [for (var i = 0; i < paths.length; i++) i + 1],
      },
    ],
    'actions': [
      {
        'targetId': 1,
        'mnemonic': 'Act',
        'inputDepSetIds': [1],
      },
    ],
  }).single['inputs'];
}
