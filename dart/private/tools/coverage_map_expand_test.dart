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

  test('writeCoverageMap merges the static map, origins and members', () {
    final out = '${tmp.path}/out.json';
    writeCoverageMap([
      out,
      '--static',
      write('static.json', {'package:o/o.dart': 'o/lib/o.dart'}),
      '--origin-map',
      write('origins.json', {
        'bazel-out/k8/bin/p/set/lib/g.dart': 'bazel-out/k8/bin/p/lib/g.dart',
      }),
      '--dir',
      dir.path,
      dir.shortPath,
      dir.packageName,
      '--file',
      'bazel-out/k8/bin/p/set/lib/g.dart',
      'p/set/lib/g.dart',
    ]);
    final map =
        jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
    expect(map['package:o/o.dart'], 'o/lib/o.dart');
    expect(map['package:pkg/g.dart'], 'bazel-out/k8/bin/p/lib/g.dart');
  });
}
