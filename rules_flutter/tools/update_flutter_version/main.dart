/// Updates flutter/private/versions.bzl with data for a new Flutter version.
///
/// Usage:
///   bazel run //tools/update_flutter_version -- 3.42.0
///
/// Prerequisites:
///   - A clone of the Flutter repo at references/flutter (or FLUTTER_REPO env var)
///
/// What it does:
///   1. Looks up the engine revision from the Flutter tag
///   2. Downloads each artifact and computes SHA-256 (archives already pinned
///      in versions.bzl for this version are reused, not downloaded again).
///      Exits non-zero if any artifact fails, after printing the snippet with
///      MISSING in its place.
///   3. Prints the Starlark snippet to add to versions.bzl
library;

import 'dart:io';

import 'pinned_checksums.dart';
import 'shader_flags.dart';
import 'version_update.dart';

Future<void> main(List<String> args) async {
  final VersionRequest request = resolveVersionRequest(args);
  final String version = request.version;

  print('Flutter version: $version');
  print('Flutter repo: ${request.flutterRepo}');

  final EngineRevisions engine = await readEngineRevisions(
    version,
    request.flutterRepo,
  );
  final String engineRev = engine.engineRev;
  final String materialFontsUrl = engine.materialFontsUrl;

  // Download artifacts and compute checksums.
  print('');
  print('Downloading artifacts and computing checksums...');
  print('(this may take a few minutes)');
  print('');

  // Archives already pinned for this version are not downloaded again.
  final String versionsBzl = File(
    '${request.workspaceDir}/flutter/private/versions.bzl',
  ).readAsStringSync();
  final Map<String, String> pinned = pinnedArtifactChecksums(
    versionsBzl,
    version,
  );
  final client = HttpClient();
  final ArtifactOutcome outcome = await downloadAllChecksums(
    client,
    DownloadSpec(
      version: version,
      engineRev: engineRev,
      materialFontsUrl: materialFontsUrl,
      pinned: pinned,
      pinnedSource: pinnedSourceSha256(versionsBzl, version),
    ),
  );
  client.close();
  final Map<String, String> checksums = outcome.checksums;
  final List<String> failures = outcome.failures;

  await reportSysrootChecksums(
    version,
    request.flutterRepo,
    request.workspaceDir,
  );

  _checkShaderFlags(version, request.flutterRepo, request.workspaceDir);

  if (failures.isNotEmpty) {
    stderr.write(renderFailuresReport(failures));
    exitCode = 1;
  }

  // Print Starlark snippet.
  stdout.write(
    renderVersionSnippet(
      version: version,
      engineRev: engineRev,
      materialFontsUrl: materialFontsUrl,
      checksums: checksums,
    ),
  );
}

/// Compares `SHADER_PLATFORM_FLAGS` with the runtime stages flutter_tools at
/// [version] compiles shaders for, and says which platforms moved.
void _checkShaderFlags(String version, String flutterRepo, String workspace) {
  print('');
  print('Checking shader compile flags...');
  const toolsPath =
      'packages/flutter_tools/lib/src/build_system/tools/shader_compiler.dart';
  final ProcessResult shown = Process.runSync('git', [
    'show',
    '$version:$toolsPath',
  ], workingDirectory: flutterRepo);
  if (shown.exitCode != 0) {
    print('  Could not read $toolsPath at $version: ${shown.stderr}');
    return;
  }
  const bzlPath = 'flutter/private/flutter_shader_compile.bzl';
  final List<String> mismatches = shaderFlagMismatches(
    flutterToolsShaderFlags(shown.stdout as String),
    rulesShaderFlags(File('$workspace/$bzlPath').readAsStringSync()),
  );
  if (mismatches.isEmpty) {
    print('  SHADER_PLATFORM_FLAGS matches flutter_tools.');
    return;
  }
  print('  WARNING: SHADER_PLATFORM_FLAGS in $bzlPath differs from');
  print('  flutter_tools at $version. Update it to match:');
  for (final line in mismatches) {
    print('    $line');
  }
}
