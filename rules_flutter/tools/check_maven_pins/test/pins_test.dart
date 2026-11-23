/// Unit tests for the rules_android_maven pin validation tool.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../pins.dart';

const String _validSha =
    '66bc2c13bd91fb8ea09e445b21f784d3e5d3a9ec9b180cd07e0e9208c2f939c6';

String _encodeLock({
  Object? version = '3',
  Map<String, Object?>? artifacts,
  Map<String, Object?>? conflictResolution,
}) {
  return jsonEncode(<String, Object?>{
    'version': version,
    'conflict_resolution': ?conflictResolution,
    'artifacts':
        artifacts ??
        <String, Object?>{
          'androidx.annotation:annotation': <String, Object?>{
            'shasums': <String, Object?>{'jar': _validSha},
            'version': '1.9.1',
          },
        },
  });
}

Directory _writeFakeWorkspace(
  Directory parent, {
  String? lockFileAttr = '"//:rules_android_maven_install.json"',
  List<String> declaredArtifacts = const [
    'androidx.annotation:annotation:1.9.1',
  ],
  String? extraModuleContent,
  String? lockContent,
}) {
  final wsDir = Directory('${parent.path}/fake_ws')..createSync();
  final lockLine = lockFileAttr != null
      ? '    lock_file = $lockFileAttr,\n'
      : '';
  final String artifactsLines = declaredArtifacts
      .map((String a) => '        "$a",\n')
      .join();
  final suffix = extraModuleContent != null ? '\n$extraModuleContent\n' : '';

  File('${wsDir.path}/MODULE.bazel').writeAsStringSync(
    'maven.install(\n'
    '    name = "rules_android_maven",\n'
    '    artifacts = [\n'
    '$artifactsLines'
    '    ],\n'
    '$lockLine'
    ')$suffix\n',
  );

  File('${wsDir.path}/rules_android_maven_install.json').writeAsStringSync(
    lockContent ?? _encodeLock(),
  );
  return wsDir;
}

void _registerValidPinTests(Directory Function() getTempDir) {
  test('passes on valid workspace with v3 lock', () {
    final Directory ws = _writeFakeWorkspace(getTempDir());
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, isEmpty);
  });

  test('passes on valid workspace with v2 lock', () {
    final String lock = _encodeLock(version: '2');
    final Directory ws = _writeFakeWorkspace(getTempDir(), lockContent: lock);
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, isEmpty);
  });

  test('ignores hash characters inside string literals', () {
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      extraModuleContent: '# lock_file comment\n_url = "https://example.com#x"',
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, isEmpty);
  });

  test('checkAllWorkspaces validates custom workspaces list', () {
    final Directory root = getTempDir();
    _writeFakeWorkspace(root);
    final List<String> errors = checkAllWorkspaces(
      rootPath: root.path,
      workspaces: const ['fake_ws'],
    );
    expect(errors, isEmpty);
  });
}

void _registerMissingOrMalformedLockTests(Directory Function() getTempDir) {
  test('fails when rules_android_maven has no lock_file', () {
    final Directory ws = _writeFakeWorkspace(getTempDir(), lockFileAttr: null);
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains(ws.path));
    expect(errors.first, contains('MODULE.bazel'));
    expect(errors.first, contains('has no lock_file'));
  });

  test('fails when lock_file is commented out', () {
    final Directory root = getTempDir();
    final wsDir = Directory('${root.path}/commented_ws')..createSync();
    File('${wsDir.path}/MODULE.bazel').writeAsStringSync(
      'maven.install(\n'
      '    name = "rules_android_maven",\n'
      '    # lock_file = "//:rules_android_maven_install.json",\n'
      ')\n',
    );
    final List<String> errors = checkWorkspacePins(wsDir.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains('has no lock_file'));
  });

  test('fails when lock file is missing', () {
    final Directory ws = _writeFakeWorkspace(getTempDir());
    File('${ws.path}/rules_android_maven_install.json').deleteSync();
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains(ws.path));
    expect(errors.first, contains('rules_android_maven_install.json'));
    expect(errors.first, contains('lock file is missing'));
  });

  test('fails when lock file is not valid JSON', () {
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      lockContent: 'not valid json [',
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains(ws.path));
    expect(errors.first, contains('rules_android_maven_install.json'));
    expect(errors.first, contains('lock file is not valid JSON'));
  });

  test('fails when lock file version is not 2 or 3', () {
    final String lock = _encodeLock(version: '1');
    final Directory ws = _writeFakeWorkspace(getTempDir(), lockContent: lock);
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains(ws.path));
    expect(errors.first, contains("expected lock version 2 or 3, got '1'"));
  });
}

void _registerShaTests(Directory Function() getTempDir) {
  test('fails when artifact entry has no 64-hex sha256', () {
    final String lock = _encodeLock(
      artifacts: <String, Object?>{
        'androidx.annotation:annotation': <String, Object?>{
          'shasums': <String, Object?>{'jar': 'invalid-sha'},
          'version': '1.9.1',
        },
      },
    );
    final Directory ws = _writeFakeWorkspace(getTempDir(), lockContent: lock);
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains(ws.path));
    expect(
      errors.first,
      contains(
        "artifact 'androidx.annotation:annotation' has no 64-hex sha256 under shasums",
      ),
    );
  });

  test('fails when artifact entry has empty shasums', () {
    final String lock = _encodeLock(
      artifacts: <String, Object?>{
        'androidx.annotation:annotation': <String, Object?>{
          'shasums': <String, Object?>{},
          'version': '1.9.1',
        },
      },
    );
    final Directory ws = _writeFakeWorkspace(getTempDir(), lockContent: lock);
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains(ws.path));
    expect(
      errors.first,
      contains(
        "artifact 'androidx.annotation:annotation' has no 64-hex sha256 under shasums",
      ),
    );
  });
}

void _registerDeclaredArtifactTests(Directory Function() getTempDir) {
  test('fails when declared group:artifact is absent from lock', () {
    final String lock = _encodeLock(
      artifacts: <String, Object?>{
        'com.google.guava:guava': <String, Object?>{
          'shasums': <String, Object?>{'jar': _validSha},
          'version': '32.1.2-jre',
        },
      },
    );
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      lockContent: lock,
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains(ws.path));
    expect(
      errors.first,
      contains(
        "declared artifact 'androidx.annotation:annotation:1.9.1' "
        '(androidx.annotation:annotation) is absent from lock',
      ),
    );
  });

  test('fails when maven.artifact tag coordinate is absent from lock', () {
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      extraModuleContent:
          'maven.artifact(\n'
          '    name = "rules_android_maven",\n'
          '    group = "com.google.guava",\n'
          '    artifact = "listenablefuture",\n'
          '    version = "1.0",\n'
          ')',
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains('com.google.guava:listenablefuture'));
  });
}

const String _secondInstall =
    'maven.install(\n'
    '    name = "android_ide_common_30_1_3",\n'
    '    artifacts = ["androidx.annotation:annotation:1.9.1"],\n'
    ')';

Directory _writeModule(Directory root, String relPath, String content) {
  final dir = Directory('${root.path}/$relPath')..createSync(recursive: true);
  File('${dir.path}/MODULE.bazel').writeAsStringSync(content);
  return dir;
}

void _registerDiscoveryTests(Directory Function() getTempDir) {
  const mavenModule = 'maven.install(name = "m", lock_file = "//:l")\n';

  test('discovers Maven workspaces, nested ones too, and skips the rest', () {
    final Directory root = getTempDir();
    _writeModule(root, 'e2e/zeta', mavenModule);
    _writeModule(root, 'e2e/alpha', mavenModule);
    _writeModule(root, 'e2e/group/inner', mavenModule);
    _writeModule(root, 'e2e/plain', 'module(name = "plain")\n');
    _writeModule(root, 'e2e/bazel-out', mavenModule);
    Link('${root.path}/e2e/linked').createSync('${root.path}/e2e/alpha');
    expect(discoverMavenWorkspaces(root.path), [
      'e2e/alpha',
      'e2e/group/inner',
      'e2e/zeta',
    ]);
  });

  test('ignores installs that only appear in comments', () {
    final Directory root = getTempDir();
    _writeModule(root, 'e2e/commented', '# maven.install(name = "x")\n');
    expect(discoverMavenWorkspaces(root.path), isEmpty);
  });

  test('fails when e2e has no maven.install declaration', () {
    final Directory root = getTempDir();
    _writeModule(root, 'e2e/plain', 'module(name = "plain")\n');
    final List<String> errors = checkAllWorkspaces(rootPath: root.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains('no maven.install declaration'));
  });

  test('auto-discovery validates every discovered workspace', () {
    final Directory root = getTempDir();
    _writeModule(root, 'e2e/bad', 'maven.install(name = "m")\n');
    final List<String> errors = checkAllWorkspaces(rootPath: root.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains('e2e/bad'));
    expect(errors.first, contains("install 'm'"));
  });

  test('fails an explicit workspace that declares no maven.install', () {
    final Directory root = getTempDir();
    _writeModule(root, 'e2e/plain', 'module(name = "plain")\n');
    final List<String> errors = checkAllWorkspaces(
      rootPath: root.path,
      workspaces: const ['e2e/plain'],
    );
    expect(errors, hasLength(1));
    expect(errors.first, contains('no maven.install declaration'));
  });

  test('fails an explicit workspace without MODULE.bazel', () {
    final Directory root = getTempDir();
    final List<String> errors = checkAllWorkspaces(
      rootPath: root.path,
      workspaces: const ['e2e/missing'],
    );
    expect(errors.single, contains('MODULE.bazel does not exist'));
  });
}

void _registerEveryInstallTests(Directory Function() getTempDir) {
  test('fails a second install without lock_file, naming it', () {
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      extraModuleContent: _secondInstall,
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains(ws.path));
    expect(errors.first, contains("install 'android_ide_common_30_1_3'"));
    expect(errors.first, contains('has no lock_file'));
  });

  test('defaults an unnamed install to maven', () {
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      extraModuleContent: 'maven.install(artifacts = [])',
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains("install 'maven'"));
    expect(errors.first, contains('has no lock_file'));
  });

  test('fails when blocks of one install disagree on lock_file', () {
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      extraModuleContent:
          'maven.install(\n'
          '    name = "rules_android_maven",\n'
          '    lock_file = "//:other.json",\n'
          ')',
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains('disagree on lock_file'));
  });

  test('fails when lock_file points outside the workspace', () {
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      lockFileAttr: '"@other_repo//:rules_android_maven_install.json"',
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains('must point inside the workspace'));
  });

  test('fails when lock_file is an empty string', () {
    final Directory ws = _writeFakeWorkspace(getTempDir(), lockFileAttr: '""');
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors.single, contains('has no lock_file'));
  });

  test('fails when artifacts is not a map', () {
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      lockContent: '{"version": "2", "artifacts": []}',
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors.single, contains('no valid artifacts map'));
  });
}

void _registerVersionTests(Directory Function() getTempDir) {
  test('fails when a declared version is newer than the lock', () {
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      declaredArtifacts: const ['androidx.annotation:annotation:1.9.2'],
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains("install 'rules_android_maven'"));
    expect(errors.first, contains("version '1.9.2' is not pinned in lock"));
  });

  test('fails when a maven.artifact tag bumps its version', () {
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      extraModuleContent:
          'maven.artifact(\n'
          '    name = "rules_android_maven",\n'
          '    group = "androidx.annotation",\n'
          '    artifact = "annotation",\n'
          '    version = "2.0.0",\n'
          ')',
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains("version '2.0.0' is not pinned in lock"));
  });

  test('fails when an inline maven.artifact bumps its version', () {
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      declaredArtifacts: const [],
      extraModuleContent:
          'maven.install(\n'
          '    name = "rules_android_maven",\n'
          '    artifacts = [maven.artifact(group = "androidx.annotation", '
          'artifact = "annotation", version = "0.1")],\n'
          '    lock_file = "//:rules_android_maven_install.json",\n'
          ')',
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains("version '0.1' is not pinned in lock"));
  });
}

void _registerOmittedAndResolvedVersionTests(
  Directory Function() getTempDir,
) {
  test('fails when a coordinate omits its version', () {
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      declaredArtifacts: const ['androidx.annotation:annotation'],
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains('explicit non-empty group'));
  });

  test('fails when a maven.artifact tag omits its version', () {
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      extraModuleContent:
          'maven.artifact(\n'
          '    group = "androidx.annotation",\n'
          '    artifact = "annotation",\n'
          '    name = "rules_android_maven",\n'
          ')',
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains('explicit non-empty group'));
  });

  test('passes when a conflict_resolution maps the declared version', () {
    final String lock = _encodeLock(
      conflictResolution: <String, Object?>{
        'androidx.annotation:annotation:1.0.0':
            'androidx.annotation:annotation:1.9.1',
      },
    );
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      declaredArtifacts: const ['androidx.annotation:annotation:1.0.0'],
      lockContent: lock,
    );
    expect(checkWorkspacePins(ws.path), isEmpty);
  });

  test('fails when conflict_resolution maps to an unpinned version', () {
    final String lock = _encodeLock(
      conflictResolution: <String, Object?>{
        'androidx.annotation:annotation:1.0.0':
            'androidx.annotation:annotation:7.7.7',
      },
    );
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      declaredArtifacts: const ['androidx.annotation:annotation:1.0.0'],
      lockContent: lock,
    );
    expect(checkWorkspacePins(ws.path), hasLength(1));
  });
}

/// Finds the checkout by resolving this test's own runfiles symlink, which
/// Bazel points at the real source file, then walking up to `MODULE.bazel`.
String? _findRepoRoot() {
  const testPath = 'tools/check_maven_pins/test/pins_test.dart';
  final testFile = File(testPath);
  if (!testFile.existsSync()) return null;
  Directory dir = File(testFile.resolveSymbolicLinksSync()).parent;
  while (true) {
    if (File('${dir.path}/MODULE.bazel').existsSync() &&
        Directory('${dir.path}/e2e').existsSync()) {
      return dir.path;
    }
    if (dir.parent.path == dir.path) return null;
    dir = dir.parent;
  }
}

void _registerRepositoryTests() {
  final String? root = _findRepoRoot();

  test('the repository passes across all Android workspaces', () {
    expect(root, isNotNull, reason: 'repository checkout not reachable');
    final List<String> workspaces = discoverMavenWorkspaces(root!);
    expect(
      workspaces,
      containsAll(<String>[
        'e2e/android_example',
        'e2e/android_no_go_sdk',
        'e2e/android_sharedprefs',
        'e2e/hello_world',
        'e2e/integration_android',
        'e2e/min_versions',
        'e2e/plugin_example',
        'e2e/pub_scc',
      ]),
    );
    expect(countInstalls(root, workspaces), greaterThanOrEqualTo(16));
    expect(checkAllWorkspaces(rootPath: root), isEmpty);
  });
}

/// Runs the unit test suite for `tools/check_maven_pins`.
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('maven_pins_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('checkWorkspacePins', () {
    _registerValidPinTests(() => tempDir);
    _registerMissingOrMalformedLockTests(() => tempDir);
    _registerShaTests(() => tempDir);
    _registerDeclaredArtifactTests(() => tempDir);
    _registerEveryInstallTests(() => tempDir);
    _registerVersionTests(() => tempDir);
    _registerOmittedAndResolvedVersionTests(() => tempDir);
  });
  group('discovery', () => _registerDiscoveryTests(() => tempDir));
  group('repository', _registerRepositoryTests);
}
