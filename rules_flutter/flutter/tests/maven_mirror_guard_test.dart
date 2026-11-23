/// Maven mirror guard: every `maven.install` falls back to Google's Maven
/// Central mirror before `repo1.maven.org`.
///
/// `repo1.maven.org` answers `429 Too Many Requests` to busy CI clusters and
/// coursier does not fall through past a 429, so the mirror has to sit in
/// front of it: the list reads `maven.google.com`, the mirror, then repo1.
/// The test fails when an install in the root or any `e2e/*/MODULE.bazel`
/// lists the repositories in another order or omits the mirror, and when a
/// lock file an install names has no mirror entry in its `repositories` map.
///
/// Inputs are discovered at runtime from the workspace root (the test's own
/// source file in `data`, or `BUILD_WORKSPACE_DIRECTORY` when set), so a new
/// workspace is checked with no file list to maintain.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const _google = 'https://maven.google.com';
const _mirror = 'https://maven-central.storage-download.googleapis.com/maven2';
const _repo1 = 'https://repo1.maven.org/maven2';

/// One `maven.install(...)` call: its repository URLs in declared order and
/// the workspace-relative lock file it names, if any.
typedef MavenInstall = ({List<String> repositories, String? lockFile});

/// The text of every balanced `maven.install(...)` call in [module], with
/// comments dropped so a parenthesis in prose cannot unbalance the scan.
Iterable<String> installBodies(String module) sync* {
  final String code = module.replaceAll(
    RegExp(r'^\s*#.*$', multiLine: true),
    '',
  );
  var from = 0;
  while (true) {
    final int start = code.indexOf('maven.install(', from);
    if (start < 0) return;
    var depth = 0;
    var end = start;
    for (; end < code.length; end++) {
      if (code[end] == '(') depth++;
      if (code[end] == ')' && --depth == 0) break;
    }
    yield code.substring(start, end);
    from = end;
  }
}

/// The installs declared in [module].
List<MavenInstall> parseInstalls(String module) {
  final strings = RegExp('"([^"]*)"');
  final repos = RegExp(r'repositories\s*=\s*\[([^\]]*)\]');
  final lock = RegExp(r'lock_file\s*=\s*"//:([^"]+)"');
  return [
    for (final body in installBodies(module))
      (
        repositories: [
          for (final m in strings.allMatches(
            repos.firstMatch(body)?.group(1) ?? '',
          ))
            m.group(1)!,
        ],
        lockFile: lock.firstMatch(body)?.group(1),
      ),
  ];
}

/// Why [urls] is not "google, mirror, repo1" (the first two adjacent), or
/// null when it is.
String? orderProblem(List<String> urls) {
  final int g = urls.indexOf(_google);
  final int m = urls.indexOf(_mirror);
  final int r = urls.indexOf(_repo1);
  if (m < 0) return 'does not list $_mirror';
  if (g < 0 || m != g + 1) return 'lists the mirror not right after $_google';
  if (r <= m) return 'lists $_repo1 before the mirror (or not at all)';
  return null;
}

/// Why the lock JSON [lock] does not record the mirror, or null.
String? lockProblem(String lock) {
  final Map<String, dynamic> repos =
      (jsonDecode(lock) as Map<String, dynamic>)['repositories']
          as Map<String, dynamic>? ??
      const {};
  final Iterable<String> names = repos.keys.map(
    (k) => k.replaceFirst(RegExp(r'/$'), ''),
  );
  return names.contains(_mirror) ? null : 'repositories map has no mirror';
}

/// The workspace root: `BUILD_WORKSPACE_DIRECTORY`, else the first ancestor of
/// the anchor file's real path that holds `flutter/` and `MODULE.bazel`.
Directory workspaceRoot() {
  bool isRoot(Directory d) =>
      Directory('${d.path}/flutter').existsSync() &&
      File('${d.path}/MODULE.bazel').existsSync();
  final Map<String, String> env = Platform.environment;
  final String? fromEnv = env['BUILD_WORKSPACE_DIRECTORY'];
  if (fromEnv != null && isRoot(Directory(fromEnv))) return Directory(fromEnv);
  final anchor = '${env['TEST_SRCDIR']}/${env['GUARD_ROOT_ANCHOR']}';
  String dir = File(anchor).resolveSymbolicLinksSync();
  for (var i = 0; i < 8; i++) {
    dir = File(dir).parent.path;
    if (isRoot(Directory(dir))) return Directory(dir);
  }
  throw StateError('workspace root not found from $anchor');
}

/// Every real (non-symlink) `MODULE.bazel` of the root and the e2e workspaces.
List<File> moduleFiles(Directory root) =>
    [
          File('${root.path}/MODULE.bazel'),
          for (final d in Directory('${root.path}/e2e').listSync())
            if (d is Directory && File('${d.path}/MODULE.bazel').existsSync())
              File('${d.path}/MODULE.bazel'),
        ]
        .where(
          (f) =>
              FileSystemEntity.typeSync(f.path, followLinks: false) ==
              FileSystemEntityType.file,
        )
        .toList();

void main() {
  group('checker', () {
    test('accepts google, mirror, repo1', () {
      expect(orderProblem([_google, _mirror, _repo1]), isNull);
    });
    test('rejects a missing mirror', () {
      expect(orderProblem([_google, _repo1]), isNotNull);
    });
    test('rejects the mirror before google', () {
      expect(orderProblem([_mirror, _google, _repo1]), isNotNull);
    });
    test('rejects the mirror after repo1', () {
      expect(orderProblem([_google, _repo1, _mirror]), isNotNull);
    });
    test('rejects a lock without the mirror', () {
      expect(
        lockProblem('{"repositories": {"https://maven.google.com/": []}}'),
        isNotNull,
      );
      expect(
        lockProblem('{"repositories": {"$_mirror/": []}}'),
        isNull,
      );
    });
    test('parses installs', () {
      final List<MavenInstall> installs = parseInstalls(
        'maven.install(\n  # (note)\n  lock_file = "//:a.json",\n'
        '  repositories = ["$_google", "$_repo1"],\n)\n',
      );
      expect(installs.single.lockFile, 'a.json');
      expect(installs.single.repositories, [_google, _repo1]);
    });
  });

  group('workspace', () {
    final Directory root = workspaceRoot();
    final List<File> modules = moduleFiles(root);

    test('finds installs', () {
      final int count = modules
          .expand((f) => parseInstalls(f.readAsStringSync()))
          .length;
      expect(count, greaterThan(10));
    });

    for (final module in modules) {
      final String rel = module.path.substring(root.path.length + 1);
      for (final MavenInstall install in parseInstalls(
        module.readAsStringSync(),
      )) {
        test('$rel: ${install.lockFile ?? 'unlocked install'}', () {
          expect(orderProblem(install.repositories), isNull);
          final String? lock = install.lockFile;
          if (lock != null) {
            final String text = File('${module.parent.path}/$lock')
                .readAsStringSync();
            expect(lockProblem(text), isNull);
          }
        });
      }
    }
  });
}
