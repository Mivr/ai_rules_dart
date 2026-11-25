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
///   4. With FLUTTER_SDK_DIR (the release's stock SDK, extracted), also prints
///      the asset tool's source pin row: the hosted packages the tool compiled
///      against that SDK's flutter_tools reads, with their checksums
library;

import 'dart:io';

import 'assets_tool_pin.dart';
import 'pinned_checksums.dart';
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

  final String? flutterSdk = Platform.environment['FLUTTER_SDK_DIR'];
  if (flutterSdk == null) {
    stdout.writeln(
      '\nThe pin row of the asset tool is not printed: set FLUTTER_SDK_DIR to '
      'the Flutter SDK of the release (the stock archive, extracted) to print it.',
    );
  } else {
    stdout.writeln(
      '\n=== Add to FLUTTER_ASSETS_TOOL_SOURCES in '
      'flutter/private/flutter_assets_tool_versions.bzl ===\n',
    );
    stdout.write(
      await readAssetsToolPin(
        version: version,
        flutterSdk: flutterSdk,
        assetsToolMain:
            '${request.workspaceDir}/flutter/private/assets_tool/'
            'flutter_assets_tool.dart',
      ),
    );
  }
}
