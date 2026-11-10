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

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('coverage_map_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const dir = SourceDir(
    path: 'bazel-out/k8/bin/p/set',
    shortPath: 'p/set',
    packageName: 'pkg',
  );

  test('maps a staged file to its origin under every URI', () {
    final Map<String, String> entries = expandDirectories(
      dirs: [dir],
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
      dirs: [dir],
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
        dirs: [dir],
        files: [const MemberFile(path: 'x/y.dart', shortPath: 'x/y.dart')],
        origins: {},
      ),
      throwsA(isA<CoverageMapError>()),
    );
  });

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
      dir.shortPath,
      '--file',
      'o/lib/o.dart',
      'o/lib/o.dart',
      '--origin-map',
      write('origins.json', {
        'bazel-out/k8/bin/p/set/lib/g.dart': 'bazel-out/k8/bin/p/lib/g.dart',
      }),
      '--dir',
      dir.path,
      dir.shortPath,
      '--file',
      'bazel-out/k8/bin/p/set/lib/g.dart',
      'p/set/lib/g.dart',
    ]);
    final map =
        jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
    expect(map['package:o/o.dart'], 'o/lib/o.dart');
    expect(map['package:pkg/g.dart'], 'bazel-out/k8/bin/p/lib/g.dart');
  });

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
}
