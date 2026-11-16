import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The folders full.yaml's macOS job tests whole: what only a darwin host
/// proves (native executables, link hooks, cross-compilation from darwin,
/// darwin exec toolchains and SDK archives, the Go gazelle binary through
/// apple_support). e2e/hello_world is the plain macOS host smoke.
const Set<String> _wholeFolders = {
  'e2e/link_hook',
  'e2e/gazelle',
  'e2e/cross_compile',
  'e2e/hello_world',
  'e2e/sdk_coupling',
  'e2e/root_sdk_pin',
};

/// The folders it tests only on their darwin-relevant tests.
const Set<String> _darwinFolders = {'.', 'e2e/ext_exemplar'};

/// The folders the two macOS shards ran before, dropped from macOS since
/// their macOS run proves nothing their Linux run does not. Each needs a
/// one-line reason in full.yaml and a Linux shard in ci.yaml.
const Set<String> _dropped = {
  '.github/workflows',
  'dev',
  'tools',
  'e2e/analysis',
  'e2e/analyze_composition',
  'e2e/codegen',
  'e2e/dart_test',
  'e2e/dart_test_pkg',
  'e2e/dual_build',
  'e2e/fix',
  'e2e/guard_reuse',
  'e2e/isolated_hub',
  'e2e/library_deps',
  'e2e/pub_deps',
  'e2e/pub_lock',
  'e2e/pub_lock_cross_module',
  'e2e/pub_lock_dedup',
  'e2e/pub_lock_git',
  'e2e/pub_lock_scc',
  'e2e/pub_lock_upgrade',
  'e2e/pub_workspace',
  'e2e/smoke',
  'e2e/web_app',
};

/// The shape full.yaml's `test-macos` had before it was scoped: two shards,
/// every folder whole. [_problems] must reject it.
const String _oldFull = '''
jobs:
  test-macos:
    strategy:
      matrix:
        include:
          - shard: 1
            folders: |
              .
              e2e/hello_world
              e2e/pub_lock
          - shard: 2
            folders: |
              e2e/ext_exemplar
              tools
''';

void main(List<String> args) {
  final String root = _repoRoot(args);
  final String full = File('$root/.github/workflows/full.yaml')
      .readAsStringSync();
  final String ci = File('$root/.github/workflows/ci.yaml').readAsStringSync();

  test('full.yaml test-macos runs only the darwin-relevant folders', () {
    expect(_problems(full, ci), isEmpty);
  });

  test('the old two-shard, every-folder shape is rejected', () {
    expect(_problems(_oldFull, ci), isNotEmpty);
  });

  test('a dropped folder without a reason is rejected', () {
    final String noReason = full.replaceFirst(
      RegExp(r'^\s*# - e2e/web_app:.*\n', multiLine: true),
      '',
    );
    expect(noReason, isNot(equals(full)));
    expect(_problems(noReason, ci), isNotEmpty);
  });
}

/// Everything wrong with the macOS scope of [full] against the Linux shards
/// of [ci]; empty when the scope is as pinned.
List<String> _problems(String full, String ci) {
  final problems = <String>[];
  final List<YamlMap> include = _include(full, 'test-macos');
  if (include.length != 1) {
    problems.add('test-macos must be one macOS job, has ${include.length}');
  }
  final whole = <String>{};
  final darwin = <String>{};
  for (final entry in include) {
    whole.addAll(_lines(entry['folders']));
    darwin.addAll(_lines(entry['darwin_folders']).map(_firstWord));
  }
  if (!_same(whole, _wholeFolders)) {
    problems.add('folders are $whole, want $_wholeFolders');
  }
  if (!_same(darwin, _darwinFolders)) {
    problems.add('darwin_folders are $darwin, want $_darwinFolders');
  }
  for (final String folder in _dropped) {
    final reason = RegExp(
      '^\\s*# - ${RegExp.escape(folder)}: \\S',
      multiLine: true,
    );
    if (!reason.hasMatch(full)) {
      problems.add('dropped $folder has no `# - $folder: <reason>` line');
    }
  }
  final Set<String> linux = _linuxFolders(ci);
  for (final String folder in {
    ..._wholeFolders,
    ..._darwinFolders,
    ..._dropped,
  }) {
    if (!linux.contains(folder)) {
      problems.add('$folder runs in no Linux shard of ci.yaml');
    }
  }
  return problems;
}

/// The matrix `include` entries of [job] in the workflow [text].
List<YamlMap> _include(String text, String job) {
  YamlMap at(Object? node, String key) => (node! as YamlMap)[key] as YamlMap;
  final YamlMap matrix = at(
    at(at(at(loadYaml(text), 'jobs'), job), 'strategy'),
    'matrix',
  );
  return (matrix['include'] as YamlList).cast<YamlMap>().toList();
}

/// The folders ci.yaml's `test` job runs on ubuntu-latest.
Set<String> _linuxFolders(String ci) {
  return {
    for (final YamlMap entry in _include(ci, 'test'))
      if (entry['os'] == 'ubuntu-latest') ..._lines(entry['folders']),
  };
}

List<String> _lines(Object? block) => block == null
    ? const []
    : block
          .toString()
          .split('\n')
          .map((String l) => l.trim())
          .where((String l) => l.isNotEmpty)
          .toList();

String _firstWord(String line) => line.split(RegExp(r'\s+')).first;

bool _same(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

/// Resolves the repository root via the runfiles anchor.
String _repoRoot(List<String> args) {
  if (args.isNotEmpty) {
    try {
      final String located = Runfiles.create().rlocation(args.first);
      Directory dir = File(File(located).resolveSymbolicLinksSync()).parent;
      while (dir.path != dir.parent.path) {
        if (File('${dir.path}/MODULE.bazel').existsSync() &&
            Directory('${dir.path}/.github/workflows').existsSync()) {
          return dir.path;
        }
        dir = dir.parent;
      }
    } on Object catch (_) {
      // Fall through to the environment.
    }
  }
  return Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
      Directory.current.path;
}
