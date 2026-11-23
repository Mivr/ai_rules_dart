// Tagged `runfiles`: the code under test imports `package:rules_dart_guard`,
// which Bazel supplies via the `@rules_dart//dart/guard:directive_guard` dep
// its `dart_test` declares. A bare `dart test` resolves only this package's
// pubspec, where that import does not exist, so the file fails to load rather
// than failing a test.
// Coverage comes from //flutter/private/tools:kernel_read_set_test.
@Tags(['runfiles'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../directive_guard.dart';
import '../kernel_filter.dart';

void main() {
  group('findUndeclaredReads', () {
    const declared = {
      'app/lib/main.dart',
      'bazel-out/k8-fastbuild/bin/app.dill.stage/app/lib/main.dart',
    };
    const allowed = {'.dart_tool/package_config.json'};

    test('accepts declared and allowed reads spelt exec-root-relative', () {
      final Directory work = Directory.systemTemp.createTempSync(
        'kernel_filter_ru_',
      );
      addTearDown(() => work.deleteSync(recursive: true));
      final Directory saved = Directory.current;
      Directory.current = work.path;
      addTearDown(() => Directory.current = saved.path);
      expect(
        findUndeclaredReads(
          [
            '+file://${work.path}/app/lib/main.dart',
            '+file://${work.path}/.dart_tool/package_config.json',
          ],
          declared,
          allowed,
        ),
        isEmpty,
      );
    });

    test('refuses absolute reads outside the working directory by default', () {
      final Directory work = Directory.systemTemp.createTempSync(
        'kernel_filter_ro_',
      );
      addTearDown(() => work.deleteSync(recursive: true));
      final Directory saved = Directory.current;
      Directory.current = work.path;
      addTearDown(() => Directory.current = saved.path);
      expect(
        findUndeclaredReads(
          ['+file:///tmp/mirror/app/lib/main.dart'],
          declared,
          allowed,
        ),
        ['+file:///tmp/mirror/app/lib/main.dart'],
      );
    });

    test('refuses a read under a root that only the argv names', () {
      // No manifest entry allows it: the argv `--filesystem-root` alone
      // widens nothing, so the mirrored read is undeclared.
      final Directory parent = Directory.systemTemp.createTempSync(
        'kernel_filter_rm_',
      );
      addTearDown(() => parent.deleteSync(recursive: true));
      final work = Directory('${parent.path}/work')..createSync();
      final mirror = Directory('${parent.path}/mirror')..createSync();
      final Directory saved = Directory.current;
      Directory.current = work.path;
      addTearDown(() => Directory.current = saved.path);
      expect(
        findUndeclaredReads(
          [
            '+file://${mirror.path}/app/lib/main.dart',
            '+file://${mirror.path}/app/lib/new.dart',
          ],
          declared,
          allowed,
        ),
        [
          '+file://${mirror.path}/app/lib/main.dart',
          '+file://${mirror.path}/app/lib/new.dart',
        ],
      );
    });

    test('collapses repeated slashes before the declared-set comparison', () {
      final Directory work = Directory.systemTemp.createTempSync(
        'kernel_filter_sl_',
      );
      final Directory saved = Directory.current;
      Directory.current = work.path;
      addTearDown(() {
        Directory.current = saved.path;
        work.deleteSync(recursive: true);
      });
      final String cwd = Directory.current.path;
      final doubled = '+file://$cwd/demo/lib/src//d.dart';
      final undeclared = '+file://$cwd/demo/lib/src//other.dart';
      final reads = [
        doubled,
        '+file://$cwd//demo///lib/src/d.dart',
        undeclared,
      ];
      const declaredSet = {'demo/lib/src/d.dart'};
      expect(findUndeclaredReads(reads, declaredSet, {}), [undeclared]);
      expect(
        findUndeclaredReadsWithMirrorRoots(reads, declaredSet, {}, const []),
        [undeclared],
      );
    });

    test('the test-only mirror excuse accepts a mirrored created library', () {
      final Directory parent = Directory.systemTemp.createTempSync(
        'kernel_filter_rm_',
      );
      addTearDown(() => parent.deleteSync(recursive: true));
      final work = Directory('${parent.path}/work')..createSync();
      final mirror = Directory('${parent.path}/mirror')..createSync();
      final Directory saved = Directory.current;
      Directory.current = work.path;
      addTearDown(() => Directory.current = saved.path);
      expect(
        findUndeclaredReadsWithMirrorRoots(
          [
            '+file://${mirror.path}/app/lib/main.dart',
            '+file://${mirror.path}/app/lib/new.dart',
            '+file://${work.path}/.dart_tool/package_config.json',
          ],
          declared,
          allowed,
          [mirror.path],
        ),
        isEmpty,
      );
    });

    test('the mirror excuse still refuses escapes and outside reads', () {
      final Directory parent = Directory.systemTemp.createTempSync(
        'kernel_filter_rb_',
      );
      addTearDown(() => parent.deleteSync(recursive: true));
      final work = Directory('${parent.path}/work')..createSync();
      final mirror = Directory('${parent.path}/mirror')..createSync();
      final Directory saved = Directory.current;
      Directory.current = work.path;
      addTearDown(() => Directory.current = saved.path);
      final escape = '+file://${mirror.path}/../evil.dart';
      const outside = '+file:///tmp/other/evil.dart';
      expect(
        findUndeclaredReadsWithMirrorRoots(
          [escape, outside, '+dart:async'],
          declared,
          allowed,
          ['${mirror.path}/'],
        ),
        [escape, outside, '+dart:async'],
      );
    });
  });

  group('scanFlutterDirectivesAgainst', () {
    late Directory work;
    late Directory savedCwd;

    setUp(() {
      savedCwd = Directory.current;
      work = Directory.systemTemp.createTempSync('kernel_filter_subset_');
      Directory.current = work.path;
    });
    tearDown(() {
      Directory.current = savedCwd.path;
      work.deleteSync(recursive: true);
    });

    void write(String rel, String content) {
      File('${work.path}/$rel')
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    test('checks only the chosen subset against the full declared set', () {
      write('lib/helper.dart', 'int a = 1;\n');
      write('lib/a.dart', "import 'helper.dart';\nimport 'gone.dart';\n");
      write('lib/b.dart', "import 'gone.dart';\n");
      final all = ['lib/helper.dart', 'lib/a.dart', 'lib/b.dart'];
      final Map<String, List<String>> verdicts = scanFlutterDirectivesAgainst(
        ['lib/a.dart'],
        all,
        [],
      );
      expect(verdicts.keys, ['lib/a.dart']);
      expect(verdicts['lib/a.dart'], hasLength(1));
      expect(verdicts['lib/a.dart']!.single, contains('gone.dart'));
    });

    test('a directive is allowed only while its target is declared', () {
      write('lib/helper.dart', 'int a = 1;\n');
      write('lib/a.dart', "import 'helper.dart';\n");
      final Map<String, List<String>> withHelper = scanFlutterDirectivesAgainst(
        ['lib/a.dart'],
        ['lib/helper.dart', 'lib/a.dart'],
        [],
      );
      expect(withHelper['lib/a.dart'], isEmpty);
      final Map<String, List<String>> without = scanFlutterDirectivesAgainst(
        ['lib/a.dart'],
        ['lib/a.dart'],
        [],
      );
      expect(without['lib/a.dart'], hasLength(1));
    });

    test('per-source scan flattens to the existing full-scan result', () {
      write('lib/a.dart', "import 'x.dart';\n");
      write('lib/b.dart', "import 'y.dart';\n");
      final sources = [
        'lib/b.dart',
        'lib/a.dart',
        'lib/missing.dart',
      ];
      final Map<String, List<String>> perSource =
          scanFlutterDirectivesPerSource(sources, []);
      expect(perSource.keys.toSet(), {'lib/a.dart', 'lib/b.dart'});
      expect(
        [for (final p in perSource.keys.toList()..sort()) ...perSource[p]!],
        findDisallowedFlutterDirectives(sources, []),
      );
    });
  });
}
