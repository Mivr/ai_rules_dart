/// Unit tests for `package:e2e_runner/staging.dart`.
library;

import 'dart:io';

import 'package:e2e_runner/spec.dart';
import 'package:e2e_runner/staging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Entry point for staging unit tests.
void main() {
  _registerOverrideRewriteTests();
  _registerWorkspaceStageTests();
  _registerMutationTests();
}

void _registerOverrideRewriteTests() {
  group('rewriteEscapingPathOverrides', () {
    test('rewrites escaping relative overrides and leaves intra-workspace', () {
      const moduleSource = '''
module(name = "sample")

# Commented out override must stay untouched:
# local_path_override(module_name = "commented", path = "../..")

DOC = """
local_path_override(module_name = "in_doc", path = "../..")
"""

local_path_override(
    module_name = "ai_rules_flutter",
    path = "../..",
)

local_path_override(
    path = './nested_child',
    module_name = "intra_dot",
)

local_path_override(
    module_name = "intra_plain",
    path = "sub/pkg",
)

local_path_override(
    module_name = "already_abs",
    path = "/opt/fixed/path",
)
''';
      final String rewritten = rewriteEscapingPathOverrides(
        moduleSource,
        originalModuleDir: '/repo/e2e/hello_world',
        sourceWorkspaceDir: '/repo/e2e/hello_world',
      );
      expect(rewritten, contains('path = "/repo"'));
      expect(rewritten, contains("path = './nested_child'"));
      expect(rewritten, contains('path = "sub/pkg"'));
      expect(rewritten, contains('path = "/opt/fixed/path"'));
      expect(
        rewritten,
        contains(
          '# local_path_override(module_name = "commented", path = "../..")',
        ),
      );
      expect(
        rewritten,
        contains(
          'local_path_override(module_name = "in_doc", path = "../..")',
        ),
      );
    });

    test('handles nested child module escaping vs sibling intra-workspace', () {
      const childModule = '''
local_path_override(
    module_name = "ai_rules_flutter",
    path = "../../..",
)
local_path_override(
    module_name = "sibling_pkg",
    path = "../sibling",
)
''';
      final String rewritten = rewriteEscapingPathOverrides(
        childModule,
        originalModuleDir: '/repo/e2e/parent/child',
        sourceWorkspaceDir: '/repo/e2e/parent',
      );
      expect(rewritten, contains('path = "/repo"'));
      expect(rewritten, contains('path = "../sibling"'));
    });
  });
}

void _registerWorkspaceStageTests() {
  group('stageWorkspace', () {
    test(
      'copies tree, skips bazel-*, preserves intra links, derefs external',
      () {
        final Directory root = Directory.systemTemp.createTempSync(
          'stage_test_',
        );
        addTearDown(() => root.deleteSync(recursive: true));

        final repoRoot = Directory(p.join(root.path, 'repo'))..createSync();
        final extTarget = File(p.join(root.path, 'external_secret.txt'))
          ..writeAsStringSync('from_runfiles');
        final srcWs = Directory(p.join(repoRoot.path, 'e2e', 'ws'))
          ..createSync(recursive: true);

        File(p.join(srcWs.path, 'MODULE.bazel.real')).writeAsStringSync('''
local_path_override(
    module_name = "ai_rules_flutter",
    path = "../..",
)
''');
        Link(p.join(srcWs.path, 'MODULE.bazel'))
            .createSync('MODULE.bazel.real');
        Directory(p.join(srcWs.path, 'shared')).createSync();
        File(p.join(srcWs.path, 'shared', 'a.txt')).writeAsStringSync('ok');
        Directory(p.join(srcWs.path, 'pkg')).createSync();
        Link(p.join(srcWs.path, 'pkg', 'linked')).createSync('../shared');
        Link(p.join(srcWs.path, 'ext.txt')).createSync(extTarget.path);
        Directory(p.join(srcWs.path, 'bazel-out')).createSync();
        File(p.join(srcWs.path, 'bazel-out', 'junk')).writeAsStringSync('skip');

        final String stagedWs = p.join(root.path, 'staged');
        stageWorkspace(
          sourceWorkspace: srcWs.path,
          stagedWorkspace: stagedWs,
        );

        expect(Directory(p.join(stagedWs, 'bazel-out')).existsSync(), isFalse);
        expect(
          FileSystemEntity.isLinkSync(p.join(stagedWs, 'pkg', 'linked')),
          isTrue,
        );
        expect(
          Link(p.join(stagedWs, 'pkg', 'linked')).targetSync(),
          '../shared',
        );
        expect(
          FileSystemEntity.isLinkSync(p.join(stagedWs, 'ext.txt')),
          isFalse,
        );
        expect(
          File(p.join(stagedWs, 'ext.txt')).readAsStringSync(),
          'from_runfiles',
        );
        final String stagedModule = File(
          p.join(stagedWs, 'MODULE.bazel'),
        ).readAsStringSync();
        expect(
          stagedModule,
          contains('path = "${repoRoot.path.replaceAll(r'\', '/')}"'),
        );
        expect(
          File(p.join(srcWs.path, 'MODULE.bazel.real')).readAsStringSync(),
          contains('path = "../.."'),
        );
      },
    );
  });
}

void _registerMutationTests() {
  group('applyWriteFiles and applyReplaceInFiles', () {
    test('writes files, expands WORKSPACE, and fails naming spec+command', () {
      final Directory dir = Directory.systemTemp.createTempSync('mutate_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      const SpecErrorContext ctx = (
        specPath: 'e2e/demo/e2e.yaml',
        commandName: 'mutate-step',
      );

      applyWriteFiles(
        const [WriteFileSpec(path: 'sub/hello.txt', content: 'root=__ROOT__')],
        stagedWorkspace: dir.path,
        context: ctx,
      );
      applyReplaceInFiles(
        const [
          ReplaceInFileSpec(
            path: 'sub/hello.txt',
            from: '__ROOT__',
            to: r'${WORKSPACE}',
          ),
        ],
        stagedWorkspace: dir.path,
        context: ctx,
      );
      expect(
        File(p.join(dir.path, 'sub', 'hello.txt')).readAsStringSync(),
        'root=${dir.path.replaceAll(r'\', '/')}',
      );

      expect(
        () => applyReplaceInFiles(
          const [
            ReplaceInFileSpec(path: 'does_not_exist.txt', from: 'a', to: 'b'),
          ],
          stagedWorkspace: dir.path,
          context: ctx,
        ),
        throwsA(
          isA<E2eRunnerException>()
              .having((e) => e.specPath, 'specPath', 'e2e/demo/e2e.yaml')
              .having((e) => e.commandName, 'commandName', 'mutate-step'),
        ),
      );

      expect(
        () => applyWriteFiles(
          const [WriteFileSpec(path: '../escape.txt', content: 'bad')],
          stagedWorkspace: dir.path,
          context: ctx,
        ),
        throwsA(
          isA<E2eRunnerException>()
              .having((e) => e.specPath, 'specPath', 'e2e/demo/e2e.yaml')
              .having((e) => e.commandName, 'commandName', 'mutate-step'),
        ),
      );
    });
  });
}
