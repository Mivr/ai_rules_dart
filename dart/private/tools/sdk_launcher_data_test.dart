// Runs the `dart_sdk_binary` launcher the way `e2e/smoke:dart_version_test`
// does: as a data dependency, resolved through runfiles and executed
// directly, with no `RunEnvironmentInfo` environment. Each run asks for
// `dart --version` (a file-form execution, so no analytics flag) and expects
// the SDK version line. The manifest-only run pins the `--noenable_runfiles`
// (Windows) lookup; the directory-only run pins the tree lookup.

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'sdk_launcher.dart' show adjacentSdkConfigFile;

/// Test entry: runs the launcher at the rlocation path in `args[0]` as a
/// data dependency, with no `RunEnvironmentInfo` environment.
void main(List<String> args) {
  if (args.isEmpty) {
    throw StateError(
      'sdk_launcher_data_test: pass \$(rlocationpath //dart) as the test argument.',
    );
  }
  final launcher = Runfiles.create().rlocation(args[0]);

  group('adjacentSdkConfigFile', () {
    test('falls back to the current executable for an empty name', () {
      expect(adjacentSdkConfigFile('')?.path, adjacentSdkConfigFile()?.path);
    });

    test('names the sidecar beside a bare executable', () {
      final tmp = Directory.systemTemp.createTempSync(
        'sdk_launcher_data_test.',
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      File('${tmp.path}/dart.sdk_config.json').writeAsStringSync('{}');
      final file = adjacentSdkConfigFile('${tmp.path}/dart');
      expect(file, isNotNull);
      expect(file!.existsSync(), isTrue);
    });

    test('strips a Windows .exe suffix', () {
      final tmp = Directory.systemTemp.createTempSync(
        'sdk_launcher_data_test.',
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      File('${tmp.path}/dart.sdk_config.json').writeAsStringSync('{}');
      final file = adjacentSdkConfigFile('${tmp.path}/dart.exe');
      expect(file, isNotNull);
      expect(file!.path, endsWith('dart.sdk_config.json'));
      expect(file.existsSync(), isTrue);
    });
  });

  group('launcher as a data dependency (no RunEnvironmentInfo)', () {
    test('reports the SDK version with the inherited runfiles', () async {
      await _expectVersion(launcher, _dataDepEnv());
    });

    test('reports the SDK version from the manifest alone', () async {
      final env = _dataDepEnv()
        ..remove('RUNFILES_DIR')
        ..['RUNFILES_MANIFEST_FILE'] = _childManifest(launcher);
      await _expectVersion(launcher, env);
    });

    test('reports the SDK version from the runfiles directory alone', () async {
      final dir = Platform.environment['RUNFILES_DIR'];
      if (dir == null ||
          dir.isEmpty ||
          !Directory(dir).existsSync() ||
          !_dirHoldsManifest(dir)) {
        fail(
          'sdk_launcher_data_test: RUNFILES_DIR holds no runfiles; '
          'run under Bazel.',
        );
      }
      await _expectVersion(
        launcher,
        _dataDepEnv()..remove('RUNFILES_MANIFEST_FILE'),
      );
    });
  });
}

/// Manifest file for the manifest-only child run.
///
/// The runner's own manifest when it exports one; otherwise a scratch
/// manifest mapping the config's SDK path at its real location, so the child
/// still resolves the SDK through a manifest with `RUNFILES_DIR` unset (as
/// on Windows under `--noenable_runfiles`).
String _childManifest(String launcher) {
  final fromEnv = Platform.environment['RUNFILES_MANIFEST_FILE'];
  if (fromEnv != null && fromEnv.isNotEmpty && File(fromEnv).existsSync()) {
    return fromEnv;
  }
  final config = adjacentSdkConfigFile(launcher);
  if (config == null || !config.existsSync()) {
    fail('sdk_launcher_data_test: no SDK config beside $launcher.');
  }
  final sdkKey =
      (jsonDecode(config.readAsStringSync()) as Map<String, dynamic>)['dart']
          as String;
  final realDart = Runfiles.create().rlocation(sdkKey);
  final dir = Directory.systemTemp.createTempSync('sdk_launcher_manifest.');
  addTearDown(() => dir.deleteSync(recursive: true));
  final manifest = File('${dir.path}/MANIFEST');
  manifest.writeAsStringSync('$sdkKey $realDart\n');
  return manifest.path;
}

/// The test's environment with the `bazel run` config key removed.
///
/// `RunEnvironmentInfo` reaches only `bazel run`; a data-dependency
/// execution inherits the caller's runfiles variables and nothing else.
Map<String, String> _dataDepEnv() {
  final env = Map<String, String>.from(Platform.environment);
  env.remove('DART_SDK_CONFIG');
  return env;
}

/// Whether [dir] is a runfiles directory: it exists and carries a manifest
/// or materialized entries, so `Runfiles.create` resolves through it.
///
/// Under `--noenable_runfiles` Bazel still creates the directory with only a
/// `MANIFEST` in it; without any marker the directory is not runfiles.
bool _dirHoldsManifest(String dir) {
  if (File('$dir/MANIFEST').existsSync()) return true;
  if (File('${dir}_manifest').existsSync()) return true;
  // A materialized runfiles tree holds the workspace directories.
  try {
    return Directory(dir).listSync(followLinks: false).isNotEmpty;
  } on FileSystemException {
    // Unreadable here means unusable as runfiles; the caller fails naming it.
    return false;
  }
}

/// Runs [launcher] with `--version` under [env] and expects the SDK line.
Future<void> _expectVersion(String launcher, Map<String, String> env) async {
  final result = await Process.run(launcher, ['--version'], environment: env);
  expect(
    result.exitCode,
    0,
    reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
  );
  expect('${result.stdout}${result.stderr}', contains('Dart SDK version'));
}
