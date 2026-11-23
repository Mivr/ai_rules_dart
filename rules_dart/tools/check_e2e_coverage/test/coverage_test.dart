import 'dart:io';

import 'package:check_e2e_coverage/coverage.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('e2eRefFromWorkspace', () {
    test('resolves relative and absolute workspace paths against baseDir', () {
      expect(
        e2eRefFromWorkspace('../e2e/hello_world', baseDir: 'tools'),
        'e2e/hello_world',
      );
      expect(e2eRefFromWorkspace('../e2e/hello_world', baseDir: '.'), isNull);
      expect(e2eRefFromWorkspace('e2e/hello_world', baseDir: 'tools'), isNull);
      expect(e2eRefFromWorkspace('e2e/hello_world'), 'e2e/hello_world');
      expect(e2eRefFromWorkspace('./e2e/hello_world'), 'e2e/hello_world');
      expect(e2eRefFromWorkspace('/repo/e2e/hello_world/'), 'e2e/hello_world');
      expect(e2eRefFromWorkspace(r'$GITHUB_WORKSPACE/e2e/smoke'), 'e2e/smoke');
      expect(e2eRefFromWorkspace(r'${{ matrix.workspace }}'), isNull);
      expect(e2eRefFromWorkspace('dev'), isNull);
    });
  });

  group('extractReferences', () {
    test('collects working-directory, workspace, folders and --workspace', () {
      final refs = extractReferences(
        loadYaml('''
jobs:
  test:
    steps:
      - working-directory: e2e/smoke
      - working-directory: tools
        run: bazel run //e2e_runner:e2e_runner -- --workspace="../e2e/analysis"
      - run: (cd tools && bazel run //e2e_runner:e2e_runner -- --workspace ../e2e/link_hook)
      - run: |
          cd tools
          bazel run //e2e_runner:e2e_runner -- \\
            --workspace=../e2e/cross_compile
    strategy:
      matrix:
        workspace:
          - e2e/hello_world
          - e2e/pub_deps
        include:
          - folders: |
              e2e/fix
              e2e/codegen
              dev
          - env:
              WORKSPACES: "e2e/library_deps, e2e/dual_build"
'''),
      );
      expect(refs, contains('e2e/smoke'));
      expect(refs, contains('e2e/analysis'));
      expect(refs, contains('e2e/link_hook'));
      expect(refs, contains('e2e/cross_compile'));
      expect(refs, contains('e2e/hello_world'));
      expect(refs, contains('e2e/pub_deps'));
      expect(refs, contains('e2e/fix'));
      expect(refs, contains('e2e/codegen'));
      expect(refs, contains('e2e/library_deps'));
      expect(refs, contains('e2e/dual_build'));
      expect(refs, isNot(contains('dev')));
    });

    test('scopes subshell cd and rejects wrong relative --workspace paths', () {
      final refs = extractReferences(
        loadYaml('''
jobs:
  test:
    steps:
      - run: |
          (cd tools && bazel run //e2e_runner:e2e_runner -- --workspace=../e2e/good)
          bazel run //e2e_runner:e2e_runner -- --workspace=../e2e/escaped_from_root
'''),
      );
      expect(refs, contains('e2e/good'));
      expect(refs, isNot(contains('e2e/escaped_from_root')));
    });
  });

  group('checkCoverage', () {
    test('flags an uncovered top-level module', () {
      final failures = checkCoverage(
        repoRoot: '/repo',
        topLevel: {'e2e/hello_world', 'e2e/missing'},
        nested: const {},
        references: {'e2e/hello_world'},
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('e2e/missing/MODULE.bazel'));
    });

    test('exempts the six helper child modules only', () {
      final failures = checkCoverage(
        repoRoot: '/repo',
        topLevel: {'e2e/analyze_composition'},
        nested: {
          'e2e/analyze_composition/dep_module',
          'e2e/analyze_composition/unlisted_child',
        },
        references: {'e2e/analyze_composition'},
      );
      expect(failures, hasLength(1));
      expect(
        failures.single,
        contains('e2e/analyze_composition/unlisted_child/MODULE.bazel'),
      );
    });

    test('flags a dangling reference', () {
      final failures = checkCoverage(
        repoRoot: '/repo',
        topLevel: {'e2e/hello_world'},
        nested: const {},
        references: {'e2e/hello_world', 'e2e/ghost'},
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('e2e/ghost'));
    });

    test('passes when every module is covered', () {
      final failures = checkCoverage(
        repoRoot: '/repo',
        topLevel: {'e2e/hello_world'},
        nested: const {},
        references: {'e2e/hello_world'},
      );
      expect(failures, isEmpty);
    });
  });

  group('module discovery', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('cov_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('finds top-level and nested modules', () {
      Directory('${tmp.path}/e2e/hello_world').createSync(recursive: true);
      File('${tmp.path}/e2e/hello_world/MODULE.bazel').writeAsStringSync('x');
      Directory('${tmp.path}/e2e/pub_lock_cross_module/module_b')
          .createSync(recursive: true);
      File('${tmp.path}/e2e/pub_lock_cross_module/module_b/MODULE.bazel')
          .writeAsStringSync('x');
      Directory('${tmp.path}/e2e/empty').createSync(recursive: true);
      expect(topLevelModules(tmp.path), contains('e2e/hello_world'));
      expect(topLevelModules(tmp.path), isNot(contains('e2e/empty')));
      expect(
        nestedModules(tmp.path),
        contains('e2e/pub_lock_cross_module/module_b'),
      );
    });
  });
}
