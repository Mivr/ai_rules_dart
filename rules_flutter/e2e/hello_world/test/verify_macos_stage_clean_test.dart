/// macOS rebuild guard: a local rebuild must not ship a deleted asset.
///
/// The `FlutterMacOSFramework` action writes `App.framework` into a staging
/// directory beside its zip. When the action runs under a local strategy that
/// directory survives between builds, so an assemble step that only adds and
/// overwrites would keep files from the previous run in the new zip.
///
/// This test drives real builds of `//:hello_world_macos` on macOS. It builds
/// once with the framework action local (so the stage is populated), deletes
/// `assets/stage_clean.txt` (declared through a glob in `BUILD.bazel`, so the
/// file becomes undeclared without editing the build file), rebuilds with the
/// framework action local again, and asserts the removed asset is absent from
/// the new `App.framework.zip` while the versioned layout is intact. The file
/// is restored on every exit path. `full.yaml` runs `bazel test //...` in this
/// workspace on macOS; the target is incompatible elsewhere because building
/// a macOS app needs Xcode.
///
/// The nested Bazel client comes from `BAZEL` when it is set and non-empty,
/// otherwise from `bazel` on the inherited `PATH`; the target declares both in
/// `env_inherit` because Bazel sanitizes a test's environment. `unzip` is
/// resolved through the same inherited `PATH`. `//:bazel_client_test` unit
/// tests that resolver on every host; the rebuild assertion below is what the
/// macOS lane of `full.yaml` proves.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'bazel_client.dart';

/// The asset the test removes between the two builds.
const _assetRelPath = 'assets/stage_clean.txt';

/// Runs only the framework action unsandboxed, so its staging directory is
/// the real output directory and survives the next build.
const _localFramework = '--strategy=FlutterMacOSFramework=local';

/// The teardown steps that release the private output base.
const _shutdownStep = 'shutdown of the private Bazel server';
const _cleanupStep = 'removal of the private output base';

/// Where the framework action writes its zip inside a configuration.
const _frameworkZipRel =
    'bin/__hello_world_macos_app_framework/App.framework.zip';

/// Whether [root] is the hello_world example workspace root.
bool _looksLikeRoot(String root) =>
    File('$root/MODULE.bazel').existsSync() &&
    File('$root/macos/Runner/Info.plist').existsSync() &&
    File('$root/test/verify_macos_stage_clean_test.dart').existsSync();

/// Workspace root the test drives: `BUILD_WORKSPACE_DIRECTORY` when set,
/// otherwise the test's own anchor in `data` resolved through the runfiles
/// library. Null when neither resolves, so the test fails loudly instead of
/// checking the wrong tree.
String? _workspaceRoot() {
  final fromEnv = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (fromEnv != null && fromEnv.isNotEmpty && _looksLikeRoot(fromEnv)) {
    return fromEnv;
  }
  final anchor = Platform.environment['GUARD_ROOT_ANCHOR'];
  if (anchor == null || anchor.isEmpty) {
    return null;
  }
  final resolved = Runfiles.create().rlocation(anchor);
  var dir = File(File(resolved).resolveSymbolicLinksSync()).parent;
  for (var i = 0; i < 8; i++) {
    if (_looksLikeRoot(dir.path)) {
      return dir.path;
    }
    dir = dir.parent;
  }
  return null;
}

/// Runs [args] against a private output base so the nested builds do not
/// contend with the Bazel server running this test.
ProcessResult _bazel(
  String root,
  String outputBase,
  List<String> args,
  String step,
) {
  final client = resolveBazelClient(
    environment: Platform.environment,
    step: step,
  );
  final argv = ['--output_base=$outputBase', '--max_idle_secs=60', ...args];
  return runHostTool(
    executable: client,
    args: argv,
    step: step,
    workingDirectory: root,
  );
}

/// Fails with the command's output when it did not exit 0.
void _expectOk(ProcessResult result, String step) {
  if (result.exitCode != 0) {
    throw StateError(
      '$step failed with exit ${result.exitCode}\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
}

/// Extracts the framework zip at [zipPath] under [dest].
void _extractZip(String zipPath, Directory dest, String step) {
  final unzip = resolveHostTool(
    tool: 'unzip',
    environment: Platform.environment,
    step: step,
  );
  final result = runHostTool(
    executable: unzip,
    args: ['-q', '-o', zipPath, '-d', dest.path],
    step: step,
  );
  _expectOk(result, step);
}

/// Builds `//:hello_world_macos` with only the framework action local.
void _buildMacosApp(String root, String outputBase, String step) {
  const args = ['build', '//:hello_world_macos', _localFramework];
  _expectOk(_bazel(root, outputBase, args, step), step);
}

/// The `App.framework.zip` the framework action writes in [outputBase].
///
/// The macOS app builds under a platform transition, so the zip lands in a
/// transitioned configuration's `bin`, not in `bazel info bazel-bin`. Exactly
/// one configuration under the output path must hold it.
String _frameworkZipPath(String root, String outputBase) {
  const step = 'bazel info output_path';
  final result = _bazel(root, outputBase, ['info', 'output_path'], step);
  _expectOk(result, step);
  final outputPath = Directory('${result.stdout}'.trim());
  final found = [
    for (final config in outputPath.listSync().whereType<Directory>())
      if (File('${config.path}/$_frameworkZipRel').existsSync())
        '${config.path}/$_frameworkZipRel',
  ];
  if (found.length != 1) {
    throw StateError(
      'expected one $_frameworkZipRel under ${outputPath.path}, '
      'found ${found.length}: $found',
    );
  }
  return found.single;
}

/// Extracts [zipPath] under a fresh [dest] and returns its `App.framework`.
String _extractFramework(Directory dest, String zipPath, String step) {
  _extractZip(zipPath, dest, step);
  return '${dest.path}/App.framework';
}

/// Whether [assetRelPath] is bundled under [framework]'s `flutter_assets`.
bool _hasAsset(String framework, String assetRelPath) =>
    File('$framework/Versions/A/Resources/flutter_assets/$assetRelPath')
        .existsSync();

void main() {
  test('local rebuild drops a removed asset from App.framework.zip', () {
    final root = _workspaceRoot();
    if (root == null) {
      throw StateError(
        'hello_world workspace root not found: set BUILD_WORKSPACE_DIRECTORY '
        'or run unsandboxed with the test source in data',
      );
    }
    final asset = File('$root/$_assetRelPath');
    final original = asset.readAsStringSync();
    final tmp = Directory.systemTemp.createTempSync('macos_stage_clean_');
    final outputBase = '${tmp.path}/output_base';
    addTearDown(() {
      // Restore the asset before touching Bazel: a failed client resolution or
      // shutdown must not leave the workspace without the file the next run
      // needs.
      asset.parent.createSync(recursive: true);
      asset.writeAsStringSync(original);
      try {
        _bazel(root, outputBase, ['shutdown'], _shutdownStep);
      } finally {
        if (tmp.existsSync()) {
          // Bazel leaves read-only directories in the output base.
          runHostTool(
            executable: resolveHostTool(
              tool: 'chmod',
              environment: Platform.environment,
              step: _cleanupStep,
            ),
            args: ['-R', 'u+w', tmp.path],
            step: _cleanupStep,
          );
          tmp.deleteSync(recursive: true);
        }
      }
    });

    _buildMacosApp(root, outputBase, 'first build');
    final zipPath = _frameworkZipPath(root, outputBase);
    final first = _extractFramework(
      Directory('${tmp.path}/first'),
      zipPath,
      'unzip first App.framework.zip',
    );
    expect(
      _hasAsset(first, _assetRelPath),
      isTrue,
      reason:
          'the first build did not bundle $_assetRelPath, so the '
          'rebuild assertion would be vacuous',
    );

    asset.deleteSync();

    _buildMacosApp(
      root,
      outputBase,
      'local rebuild after removing $_assetRelPath',
    );
    final second = _extractFramework(
      Directory('${tmp.path}/second'),
      zipPath,
      'unzip rebuilt App.framework.zip',
    );
    expect(
      _hasAsset(second, _assetRelPath),
      isFalse,
      reason:
          'the local rebuild kept $_assetRelPath in App.framework.zip: '
          'the staging directory was not cleared and the removed asset '
          'survived from the previous run',
    );
    expect(
      File('$second/Versions/A/Resources/flutter_assets/AssetManifest.bin')
          .existsSync(),
      isTrue,
      reason: 'the rebuilt zip lost its asset manifest',
    );
    expect(Link('$second/Versions/Current').targetSync(), 'A');
    expect(Link('$second/App').targetSync(), 'Versions/Current/App');
    expect(
      Link('$second/Resources').targetSync(),
      'Versions/Current/Resources',
    );
  });
}
