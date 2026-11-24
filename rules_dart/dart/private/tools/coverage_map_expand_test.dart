import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'coverage_map_expand.dart';

/// Unit tests for the step that completes a `dart_test`'s coverage map with the
/// files of its directory sources.

late Directory tmp;

String write(String name, Object json) {
  final path = '${tmp.path}/$name';
  File(path).writeAsStringSync(jsonEncode(json));
  return path;
}

const SourceDir _dir = SourceDir(
  path: 'bazel-out/k8/bin/p/set',
  shortPath: 'p/set',
  packageName: 'pkg',
);

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('coverage_map_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  _testExpandDirectories();
  _testWriteCoverageMap();
  _testPlainEntries();
  _testPathNormalization();
}

void _testExpandDirectories() {
  test('maps a staged file to its origin under every URI', () {
    final Map<String, String> entries = expandDirectories(
      dirs: [_dir],
      files: [
        const MemberFile(
          path: 'bazel-out/k8/bin/p/set/lib/a.dart',
          shortPath: 'p/set/lib/a.dart',
        ),
      ],
      origins: {'bazel-out/k8/bin/p/set/lib/a.dart': 'p/lib/a.dart'},
    );
    expect(entries, {
      'org-dartlang-root:///p/set/lib/a.dart': 'p/lib/a.dart',
      'package:pkg/a.dart': 'p/lib/a.dart',
      'bazel-out/k8/bin/p/set/lib/a.dart': 'p/lib/a.dart',
    });
  });

  test('a file with no origin maps to its own exec path', () {
    final Map<String, String> entries = expandDirectories(
      dirs: [_dir],
      files: [
        const MemberFile(
          path: 'bazel-out/k8/bin/p/set/tool/t.dart',
          shortPath: 'p/set/tool/t.dart',
        ),
      ],
      origins: {},
    );
    expect(entries, {
      'org-dartlang-root:///p/set/tool/t.dart':
          'bazel-out/k8/bin/p/set/tool/t.dart',
    });
  });

  test('a file in no listed directory is an error', () {
    expect(
      () => expandDirectories(
        dirs: [_dir],
        files: [const MemberFile(path: 'x/y.dart', shortPath: 'x/y.dart')],
        origins: {},
      ),
      throwsA(isA<CoverageMapError>()),
    );
  });
}

void _testWriteCoverageMap() {
  test('writeCoverageMap merges plain files, origins and members', () {
    final out = '${tmp.path}/out.json';
    writeCoverageMap([
      out,
      '--package',
      'o',
      'o/lib/',
      'o',
      '--package',
      'pkg',
      'p/set/lib/',
      _dir.shortPath,
      '--file',
      'o/lib/o.dart',
      'o/lib/o.dart',
      '--origin-map',
      write('origins.json', {
        'bazel-out/k8/bin/p/set/lib/g.dart': 'bazel-out/k8/bin/p/lib/g.dart',
      }),
      '--dir',
      _dir.path,
      _dir.shortPath,
      '--file',
      'bazel-out/k8/bin/p/set/lib/g.dart',
      'p/set/lib/g.dart',
    ]);
    final map =
        jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
    expect(map['package:o/o.dart'], 'o/lib/o.dart');
    expect(map['package:pkg/g.dart'], 'bazel-out/k8/bin/p/lib/g.dart');
  });

  test('writeCoverageMap sorts plain entries, then appends directory ones', () {
    final out = '${tmp.path}/order.json';
    writeCoverageMap([
      out,
      '--package',
      'z',
      'z/lib/',
      'z',
      '--package',
      'pkg',
      'p/set/lib/',
      _dir.shortPath,
      '--dir',
      _dir.path,
      _dir.shortPath,
      '--file',
      'z/lib/b.dart',
      'z/lib/b.dart',
      '--file',
      'a/a.dart',
      'a/a.dart',
      '--file',
      'bazel-out/k8/bin/p/set/lib/c.dart',
      'p/set/lib/c.dart',
    ]);
    expect(
      File(out).readAsStringSync(),
      '{"org-dartlang-root:///a/a.dart":"a/a.dart",'
      '"org-dartlang-root:///z/lib/b.dart":"z/lib/b.dart",'
      '"package:z/b.dart":"z/lib/b.dart",'
      '"org-dartlang-root:///p/set/lib/c.dart":'
      '"bazel-out/k8/bin/p/set/lib/c.dart",'
      '"package:pkg/c.dart":"bazel-out/k8/bin/p/set/lib/c.dart"}',
    );
  });
}

void _testPlainEntries() {
  test('plainEntries maps a file under its deepest package lib', () {
    final Map<String, String> entries = plainEntries(
      packages: [
        const PackageRoot(name: 'outer', libPrefix: 'a/lib/', libRoot: 'a'),
        const PackageRoot(
          name: 'inner',
          libPrefix: 'a/lib/b/lib/',
          libRoot: 'a/lib/b',
        ),
        const PackageRoot(name: 'root', libPrefix: 'lib/', libRoot: ''),
      ],
      files: [
        const MemberFile(path: 'a/lib/x.dart', shortPath: 'a/lib/x.dart'),
        const MemberFile(
          path: 'a/lib/b/lib/y.dart',
          shortPath: 'a/lib/b/lib/y.dart',
        ),
        const MemberFile(
          path: 'external/r/lib/z.dart',
          shortPath: '../r/lib/z.dart',
        ),
        const MemberFile(path: 'lib/t.dart', shortPath: 'lib/t.dart'),
        const MemberFile(path: 'test/t.dart', shortPath: 'test/t.dart'),
      ],
    );
    expect(entries.entries.map((e) => '${e.key} ${e.value}').toList(), [
      'org-dartlang-root:///a/lib/x.dart a/lib/x.dart',
      'package:outer/x.dart a/lib/x.dart',
      'org-dartlang-root:///a/lib/b/lib/y.dart a/lib/b/lib/y.dart',
      'package:inner/y.dart a/lib/b/lib/y.dart',
      'org-dartlang-root:///external/r/lib/z.dart external/r/lib/z.dart',
      'org-dartlang-root:///lib/t.dart lib/t.dart',
      'package:root/t.dart lib/t.dart',
      'org-dartlang-root:///test/t.dart test/t.dart',
    ]);
  });

  test('a directory that roots no package is an error', () {
    expect(
      () => parseCoverageMapRequest(['out', '--dir', 'bin/d', 'd']),
      throwsA(isA<CoverageMapError>()),
    );
  });

  test(
    'writeCoverageMap writes empty JSON object when no Dart sources exist',
    () {
      final out = '${tmp.path}/empty.json';
      writeCoverageMap([out, '--package', 'pkg', 'p/lib/', 'p']);
      expect(File(out).readAsStringSync(), '{}');
    },
  );
}

void _testPathNormalization() {
  test(
    'normalizes Windows backslash separators in plain and directory sources',
    () {
      final out = '${tmp.path}/win.json';
      writeCoverageMap([
        out,
        '--package',
        'o',
        'o/lib/',
        'o',
        '--package',
        'pkg',
        'p/set/lib/',
        'p/set',
        '--origin-map',
        write('win_origins.json', {
          r'bazel-out\x64_windows-fastbuild\bin\p\set\lib\g.dart':
              r'p\lib\g.dart',
        }),
        '--dir',
        r'bazel-out\x64_windows-fastbuild\bin\p\set',
        r'p\set',
        '--file',
        r'o\lib\o.dart',
        r'o\lib\o.dart',
        '--file',
        r'bazel-out\x64_windows-fastbuild\bin\p\set\lib\g.dart',
        r'p\set\lib\g.dart',
      ]);
      final map =
          jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
      expect(map, {
        'org-dartlang-root:///o/lib/o.dart': 'o/lib/o.dart',
        'package:o/o.dart': 'o/lib/o.dart',
        'org-dartlang-root:///p/set/lib/g.dart': 'p/lib/g.dart',
        'package:pkg/g.dart': 'p/lib/g.dart',
        'bazel-out/x64_windows-fastbuild/bin/p/set/lib/g.dart': 'p/lib/g.dart',
      });
    },
  );
}
