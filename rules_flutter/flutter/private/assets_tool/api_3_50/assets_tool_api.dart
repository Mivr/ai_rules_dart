// The calls of the asset tool into `package:flutter_tools` whose API differs
// between Flutter release lines: this file for the 3.50 line. The line's
// `assets_tool_api` (`//flutter/private:sdk_lines.bzl`) names the directory
// the build compiles the tool with, as `package:flutter_assets_tool_api`.

import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/asset.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/bundle_builder.dart';
import 'package:flutter_tools/src/device.dart' show ImpellerStatus;

/// The target platform a `--platform` name stands for
/// (`TargetPlatform.fromName` since 3.50).
TargetPlatform targetPlatformNamed(String name) =>
    TargetPlatform.fromName(name);

/// The engine tools of this line the tool places where `Artifacts` looks for
/// them, beside `impellerc` and `font_subset`: none, since the icon tree
/// shaker reads the compilers' recorded uses (flutter/flutter#190225).
Map<String, String> lineEngineTools(Artifacts artifacts) => <String, String>{};

/// Writes a tester bundle as `flutter test` does (`writeBundle` takes the
/// platform since 3.50).
Future<void> writeTesterBundle(
  Directory outputDir,
  Map<String, AssetBundleEntry> entries,
  Environment environment,
  BuildMode buildMode,
) => writeBundle(
  outputDir,
  entries,
  targetPlatform: TargetPlatform.tester,
  impellerStatus: ImpellerStatus.platformDefault,
  processManager: environment.processManager,
  fileSystem: environment.fileSystem,
  artifacts: environment.artifacts,
  logger: environment.logger,
  projectDir: environment.projectDir,
  buildMode: buildMode,
  platform: environment.platform,
);
