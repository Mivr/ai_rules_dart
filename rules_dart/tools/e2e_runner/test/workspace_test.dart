import 'dart:io';

import 'package:e2e_runner/workspace.dart';
import 'package:test/test.dart';

void main() {
  group('pathEscapesWorkspace', () {
    test('identifies escaping and intra-workspace paths', () {
      expect(pathEscapesWorkspace('../..'), isTrue);
      expect(pathEscapesWorkspace('..'), isTrue);
      expect(pathEscapesWorkspace('../foo'), isTrue);
      expect(pathEscapesWorkspace(r'..\foo'), isTrue);
      expect(pathEscapesWorkspace('./dep_module'), isFalse);
      expect(pathEscapesWorkspace('dep_module'), isFalse);
      expect(pathEscapesWorkspace('intruder'), isFalse);
      expect(pathEscapesWorkspace('/abs/path'), isFalse);
      expect(pathEscapesWorkspace(r'C:\abs\path'), isFalse);
    });
  });

  group('escapingOverridePath', () {
    test('returns the escaping path from a module', () {
      const module = '''
module(name = "hello_world")

bazel_dep(name = "ai_rules_dart", version = "0.0.0", repo_name = "rules_dart")
local_path_override(
    module_name = "ai_rules_dart",
    path = "../..",
)
''';
      expect(escapingOverridePath(module), '../..');
    });

    test('ignores intra-workspace overrides', () {
      const module = '''
local_path_override(
    module_name = "toolchain_intruder",
    path = "intruder",
)
local_path_override(
    module_name = "ai_rules_dart",
    path = "../..",
)
''';
      expect(escapingOverridePath(module), '../..');
    });

    test('returns null when nothing escapes', () {
      expect(escapingOverridePath('module(name = "x")\n'), isNull);
    });
  });

  group('rewriteEscapingOverrides', () {
    test('rewrites escaping paths and leaves intra-workspace ones alone', () {
      const module = '''
local_path_override(
    module_name = "toolchain_intruder",
    path = "intruder",
)
local_path_override(
    module_name = "already_absolute",
    path = "/opt/other",
)
local_path_override(
    module_name = "ai_rules_dart",
    path = "../..",
)
local_path_override(
    module_name = "single_quoted",
    path = '..',
)
''';
      final rewritten = rewriteEscapingOverrides(module, r'C:\repo\root');
      expect(rewritten, contains('path = "intruder"'));
      expect(rewritten, contains('path = "/opt/other"'));
      expect(rewritten, contains('path = "C:/repo/root"'));
      expect(rewritten, isNot(contains('"../.."')));
      expect(rewritten, isNot(contains("'..'")));
    });
  });

  group('resolveRepoRoot', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('e2e_ws_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('resolves ../.. from the workspace', () {
      final ws = Directory('${tmp.path}/repo/e2e/hello_world')
        ..createSync(recursive: true);
      File('${ws.path}/MODULE.bazel').writeAsStringSync(
        'local_path_override(\n'
        '    module_name = "ai_rules_dart",\n'
        '    path = "../..",\n'
        ')\n',
      );
      expect(resolveRepoRoot(ws.path), normalizePath('${tmp.path}/repo'));
    });

    test('throws when there is no escaping override', () {
      final ws = Directory('${tmp.path}/bare')..createSync(recursive: true);
      File('${ws.path}/MODULE.bazel').writeAsStringSync('module(name = "x")\n');
      expect(() => resolveRepoRoot(ws.path), throwsStateError);
    });
  });

  group('stageWorkspace', () {
    late Directory tmp;
    late String repo;
    late String ws;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('e2e_stage_');
      repo = '${tmp.path}/repo';
      ws = '$repo/e2e/hello_world';
      Directory(ws).createSync(recursive: true);
      File('$repo/.bazelversion').writeAsStringSync('9.3.0\n');
      File('$ws/MODULE.bazel').writeAsStringSync(
        'local_path_override(\n'
        '    module_name = "ai_rules_dart",\n'
        '    path = "../..",\n'
        ')\n',
      );
      File('$ws/hello.dart').writeAsStringSync('void main() {}\n');
      File('$ws/.bazelversion').writeAsStringSync('9.3.0\n');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('copies sources, rewrites the override, and keeps bazelversion', () {
      final staged = '${tmp.path}/scratch/ws';
      final starlarkRepo = repo.replaceAll(r'\', '/');
      stageWorkspace(ws, staged, repo);
      expect(File('$staged/hello.dart').existsSync(), isTrue);
      final module = File('$staged/MODULE.bazel').readAsStringSync();
      expect(module, contains('path = "$starlarkRepo"'));
      expect(module, isNot(contains('"../.."')));
      expect(File('$staged/.bazelversion').readAsStringSync(), '9.3.0\n');
    });

    test('writes a .bazelversion when the workspace lacks one', () {
      File('$ws/.bazelversion').deleteSync();
      final staged = '${tmp.path}/scratch2/ws';
      stageWorkspace(ws, staged, repo);
      expect(File('$staged/.bazelversion').readAsStringSync(), '9.3.0\n');
    });

    test('rewrites escaping overrides in nested modules too', () {
      final childDir = '$ws/dep_module';
      Directory(childDir).createSync(recursive: true);
      File('$childDir/MODULE.bazel').writeAsStringSync('''
module(name = "dep_module")
local_path_override(
    module_name = "ai_rules_dart",
    path = "../../..",
)
local_path_override(
    module_name = "local_peer",
    path = "../peer",
)
''');
      final staged = '${tmp.path}/scratch3/ws';
      final starlarkRepo = repo.replaceAll(r'\', '/');
      stageWorkspace(ws, staged, repo);
      final childModule = File('$staged/dep_module/MODULE.bazel')
          .readAsStringSync();
      expect(childModule, contains('path = "$starlarkRepo"'));
      expect(childModule, isNot(contains('"../../.."')));
      expect(childModule, contains('path = "../peer"'));
    });
  });

  group('copyDirectory', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('e2e_copy_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('preserves nested directories and skips bazel links', () {
      final src = Directory('${tmp.path}/src')..createSync(recursive: true);
      File('${src.path}/a.txt').writeAsStringSync('a');
      Directory('${src.path}/sub/lib').createSync(recursive: true);
      File('${src.path}/sub/lib/b.dart').writeAsStringSync('b');
      Link('${src.path}/bazel-out').createSync('/somewhere');
      final dst = '${tmp.path}/dst';
      copyDirectory(src.path, dst);
      expect(File('$dst/a.txt').existsSync(), isTrue);
      expect(File('$dst/sub/lib/b.dart').existsSync(), isTrue);
      expect(Link('$dst/bazel-out').existsSync(), isFalse);
    });
  });

  group('deleteTree', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('e2e_del_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('removes files, directories and symlinks without following them', () {
      final target = Directory('${tmp.path}/target')..createSync();
      File('${target.path}/t.txt').writeAsStringSync('t');
      final tree = Directory('${tmp.path}/tree')..createSync();
      File('${tree.path}/a.txt').writeAsStringSync('a');
      Directory('${tree.path}/sub').createSync();
      File('${tree.path}/sub/b.txt').writeAsStringSync('b');
      Link('${tree.path}/link').createSync(target.path);
      deleteTree(tree.path);
      expect(Directory(tree.path).existsSync(), isFalse);
      // The link target must survive: deleteTree must not follow the link.
      expect(File('${target.path}/t.txt').existsSync(), isTrue);
    });
  });
}
