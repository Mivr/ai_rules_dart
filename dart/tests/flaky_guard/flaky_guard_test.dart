import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const List<String> _e2eWorkspaces = [
  'analysis',
  'hello_world',
  'isolated_hub',
  'pub_deps',
  'pub_lock_cross_module',
  'pub_lock_dedup',
  'pub_lock_upgrade',
  'root_sdk_pin',
];

const Set<String> _allowedBuildOnlyFolders = {
  '.github/workflows',
  'e2e/dual_build',
};

void main(List<String> args) {
  group('flaky guard', () {
    test(
      'effective test configuration pins flaky_test_attempts=1 and preset has no retry',
      () => _checkFlakyFlag(_workspaceRoot(args)),
    );

    test(
      'tools/BUILD.bazel suppresses flaky_test_attempts preset',
      () => _checkPresetSuppression(_workspaceRoot(args)),
    );

    test(
      'neither ci.yaml nor full.yaml contains exit-code-4 tolerance',
      () => _checkNoExit4Tolerance(_workspaceRoot(args)),
    );

    test(
      'shard runners build only the explicit zero-test folders',
      () => _checkShardBuildOnlyFolders(_workspaceRoot(args)),
    );

    test(
      'all eight e2e workspaces are in CI matrices and declare sized test targets',
      () => _checkE2eMatrixWorkspaces(_workspaceRoot(args)),
    );
  });
}

void _checkFlakyFlag(String root) {
  final String rootBazelrc = File('$root/.bazelrc').readAsStringSync();
  final String presetBazelrc = File('$root/tools/preset.bazelrc')
      .readAsStringSync();

  expect(
    rootBazelrc,
    matches(RegExp(r'^\s*test\s+.*--flaky_test_attempts=1\b', multiLine: true)),
    reason: 'root .bazelrc must pin test --flaky_test_attempts=1',
  );

  final retryPattern = RegExp(r'--flaky_test_attempts=(?:[2-9]|\d{2,})\b');
  expect(
    rootBazelrc,
    isNot(matches(retryPattern)),
    reason: 'root .bazelrc must not set flaky_test_attempts to 2 or more',
  );
  expect(
    presetBazelrc,
    isNot(matches(retryPattern)),
    reason:
        'tools/preset.bazelrc must not set flaky_test_attempts to 2 or more',
  );
  expect(
    presetBazelrc,
    isNot(contains('flaky_test_attempts')),
    reason:
        'tools/preset.bazelrc must lose the entire flaky_test_attempts block',
  );
}

void _checkPresetSuppression(String root) {
  final String toolsBuild = File('$root/tools/BUILD.bazel').readAsStringSync();
  final suppressionPattern = RegExp(
    r'''["']flaky_test_attempts["']\s*:\s*\[\s*\]''',
  );
  expect(
    toolsBuild,
    matches(suppressionPattern),
    reason: 'tools/BUILD.bazel must pass {"flaky_test_attempts": []} to bazelrc_preset',
  );
}

void _checkNoExit4Tolerance(String root) {
  final workflows = <File>[
    File('$root/.github/workflows/ci.yaml'),
    File('$root/.github/workflows/full.yaml'),
  ];
  final tolerancePatterns = <RegExp>[
    RegExp(r'\|\|\s*\[\s*\$\??\s*-eq\s*4\s*\]'),
    RegExp(r'\bbazel\b.*\|\|\s*\[?\s*\$?[\w?]*\s*-eq\s*4'),
  ];

  for (final wf in workflows) {
    final List<String> lines = wf.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final String line = lines[i].trim();
      if (line.startsWith('#')) continue;
      for (final pat in tolerancePatterns) {
        expect(
          pat.hasMatch(line),
          isFalse,
          reason: '${wf.path}:${i + 1} contains exit-code-4 tolerance: $line',
        );
      }
    }
  }
}

void _checkShardBuildOnlyFolders(String root) {
  final listPattern = RegExp(
    r'^\s*build_only_folders="([^"]*)"\s*$',
    multiLine: true,
  );
  for (final rel in [
    '.github/workflows/ci.yaml',
    '.github/workflows/full.yaml',
  ]) {
    final String content = File('$root/$rel').readAsStringSync();
    final Iterable<RegExpMatch> matches = listPattern.allMatches(content);
    expect(
      matches,
      hasLength(1),
      reason: '$rel must declare build_only_folders exactly once',
    );
    final Set<String> folders = matches.single
        .group(1)!
        .split(RegExp(r'\s+'))
        .where((String s) => s.isNotEmpty)
        .toSet();
    expect(
      folders,
      equals(_allowedBuildOnlyFolders),
      reason:
          '$rel build_only_folders must name only $_allowedBuildOnlyFolders',
    );
  }
}

void _checkE2eMatrixWorkspaces(String root) {
  final String ciYaml = File('$root/.github/workflows/ci.yaml')
      .readAsStringSync();
  final String fullYaml = File('$root/.github/workflows/full.yaml')
      .readAsStringSync();

  for (final String dir in _e2eWorkspaces) {
    expect(
      ciYaml,
      contains('e2e/$dir'),
      reason: 'ci.yaml matrix must include e2e/$dir',
    );
    expect(
      fullYaml,
      contains('e2e/$dir'),
      reason: 'full.yaml matrix must include e2e/$dir',
    );

    final e2eDir = Directory('$root/e2e/$dir');
    final List<File> buildFiles = _findBuildFiles(e2eDir);
    expect(
      buildFiles,
      isNotEmpty,
      reason: 'e2e/$dir must contain at least one BUILD.bazel',
    );

    final bool hasSizedTest = buildFiles.any(
      (File f) => _hasSizedTestRule(f.readAsStringSync()),
    );
    expect(
      hasSizedTest,
      isTrue,
      reason:
          'e2e/$dir BUILD files must declare at least one _test( rule with explicit size',
    );
  }
}

/// Finds all `BUILD.bazel` files under [dir], ignoring hidden and `bazel-*` dirs.
List<File> _findBuildFiles(Directory dir) {
  final found = <File>[];
  void walk(Directory current) {
    for (final FileSystemEntity entity in current.listSync(
      followLinks: false,
    )) {
      final String name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.') || name.startsWith('bazel-')) continue;
      if (entity is File && name == 'BUILD.bazel') {
        found.add(entity);
      } else if (entity is Directory) {
        walk(entity);
      }
    }
  }

  walk(dir);
  return found;
}

/// Resolves the repository workspace root via the runfiles anchor.
String _workspaceRoot(List<String> args) {
  if (args.isNotEmpty) {
    try {
      final String located = Runfiles.create().rlocation(args.first);
      final String realAnchor = File(located).resolveSymbolicLinksSync();
      Directory dir = Directory(realAnchor).parent;
      while (dir.path != dir.parent.path) {
        if (File('${dir.path}/MODULE.bazel').existsSync() &&
            Directory('${dir.path}/dart').existsSync()) {
          return dir.path;
        }
        dir = dir.parent;
      }
    } on Object catch (_) {
      // Fall through to environment lookup.
    }
  }
  final Map<String, String> env = Platform.environment;
  for (final key in ['BUILD_WORKSPACE_DIRECTORY', 'BUILD_WORKING_DIRECTORY']) {
    final String? candidate = env[key];
    if (candidate != null && Directory(candidate).existsSync()) {
      return candidate;
    }
  }
  return Directory.current.path;
}

/// Checks if [content] defines at least one `_test(` rule with explicit size.
bool _hasSizedTestRule(String content) {
  final testRulePattern = RegExp(r'\b\w+_test\s*\(');
  for (final Match match in testRulePattern.allMatches(content)) {
    final int openIndex = match.end - 1;
    final int closeIndex = _matchingParen(content, openIndex);
    if (closeIndex == -1) continue;
    final String ruleBody = content.substring(match.start, closeIndex + 1);
    final Match? sizeMatch = RegExp(
      r'''\bsize\s*=\s*["'](small|medium|large)["']''',
    ).firstMatch(ruleBody);
    if (sizeMatch != null) {
      return true;
    }
  }
  return false;
}

/// Finds the index of the matching `)` for the `(` at [open] in [text].
int _matchingParen(String text, int open) {
  var depth = 0;
  for (var i = open; i < text.length; i++) {
    if (text[i] == '(') depth++;
    if (text[i] == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}
