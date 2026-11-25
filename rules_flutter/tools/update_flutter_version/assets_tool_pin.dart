/// The pin of the asset tool's source closure for one Flutter release
/// (`FLUTTER_ASSETS_TOOL_SOURCES` in `flutter/private/flutter_assets_tool_versions.bzl`).
///
/// The asset tool is compiled against `packages/flutter_tools` of the release,
/// so the hosted packages its import closure reaches are pinned by hash. The
/// closure is what the Dart front end reads, so it is taken from a compile of
/// the tool against the release's own resolved package config: the depfile of
/// `dart compile kernel` names every file read. Versions and checksums come
/// from the release's `packages/flutter_tools/pubspec.lock`, language versions
/// from its `.dart_tool/package_config.json`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

/// The hosted package (`name` to `version`) every file in [depfile] names.
///
/// A path of the pub cache looks like `.../hosted/pub.dev/<name>-<version>/lib/...`.
Map<String, String> hostedPackagesOf(String depfile) {
  final found = <String, String>{};
  final cached = RegExp(r'/hosted/pub\.dev/([^/\s]+?)-(\d[^/\s]*)/');
  for (final RegExpMatch match in cached.allMatches(depfile)) {
    found[match[1]!] = match[2]!;
  }
  return found;
}

/// The path packages of `packages/flutter_tools/packages/` that [depfile]
/// reads files of.
Set<String> sourcePackagesOf(String depfile) {
  final inTree = RegExp(r'/packages/flutter_tools/packages/([^/\s]+)/');
  return {for (final m in inTree.allMatches(depfile)) m[1]!};
}

/// Renders the pin row of [version].
///
/// [lock] is the text of `packages/flutter_tools/pubspec.lock` and
/// [packageConfig] that of `.dart_tool/package_config.json` beside it.
String renderAssetsToolPin({
  required String version,
  required String depfile,
  required String lock,
  required String packageConfig,
}) {
  final languageVersions = <String, String>{
    for (final Object? entry
        in (json.decode(packageConfig) as Map<String, Object?>)['packages']!
            as List<Object?>)
      (entry! as Map<String, Object?>)['name']! as String:
          (entry as Map<String, Object?>)['languageVersion']! as String,
  };
  final locked = (loadYaml(lock) as YamlMap)['packages'] as YamlMap;
  final Map<String, String> hosted = hostedPackagesOf(depfile);
  final Set<String> inTree = sourcePackagesOf(depfile);
  final out = StringBuffer()
    ..writeln('    "$version": struct(')
    ..writeln(
      '        flutter_tools_language_version = '
      '"${languageVersions['flutter_tools']}",',
    )
    ..writeln(
      '        source_packages = {'
      '${[for (final String name in inTree.toList()..sort()) '"$name": "${languageVersions[name]}"'].join(', ')}},',
    )
    ..writeln('        packages = {');
  for (final String name in hosted.keys.toList()..sort()) {
    final description = (locked[name] as YamlMap?)?['description'] as YamlMap?;
    final Object? lockedVersion = (locked[name] as YamlMap?)?['version'];
    if (description == null || lockedVersion != hosted[name]) {
      throw StateError(
        'the compile read $name ${hosted[name]}, but the pubspec.lock of '
        'flutter_tools has ${lockedVersion ?? 'no entry'}',
      );
    }
    out.writeln(
      '            "$name": struct(version = "${hosted[name]}", '
      'sha256 = "${description['sha256']}", '
      'language_version = "${languageVersions[name]}"),',
    );
  }
  out
    ..writeln('        },')
    ..writeln('    ),');
  return out.toString();
}

/// Compiles the asset tool [assetsToolMain] against the `flutter_tools` of the
/// Flutter SDK at [flutterSdk] and renders its pin row for [version].
///
/// Runs the SDK's own Dart (`dart pub get` for `flutter_tools`, then `dart
/// compile kernel --depfile`), as the pin step of the ecosystem's tool.
Future<String> readAssetsToolPin({
  required String version,
  required String flutterSdk,
  required String assetsToolMain,
}) async {
  final dart = '$flutterSdk/bin/cache/dart-sdk/bin/dart';
  final tools = '$flutterSdk/packages/flutter_tools';
  final ProcessResult get = Process.runSync(
    dart,
    ['pub', 'get'],
    workingDirectory: tools,
    environment: Platform.environment,
    includeParentEnvironment: false,
  );
  if (get.exitCode != 0) {
    throw StateError('dart pub get in $tools failed:\n${get.stderr}');
  }
  // Beside the package config the compile reads, so it is no host-wide path.
  final scratch = Directory('$tools/.dart_tool/rules_flutter_assets_tool_pin')
    ..createSync(recursive: true);
  try {
    final depfile = '${scratch.path}/tool.d';
    final ProcessResult compile = Process.runSync(
      dart,
      [
        'compile',
        'kernel',
        '--packages=$tools/.dart_tool/package_config.json',
        '--depfile=$depfile',
        '-o',
        '${scratch.path}/tool.dill',
        assetsToolMain,
      ],
      environment: Platform.environment,
      includeParentEnvironment: false,
    );
    if (compile.exitCode != 0) {
      throw StateError(
        'the asset tool does not compile against the flutter_tools of '
        '$version:\n${compile.stdout}${compile.stderr}',
      );
    }
    return renderAssetsToolPin(
      version: version,
      depfile: File(depfile).readAsStringSync(),
      lock: File('$tools/pubspec.lock').readAsStringSync(),
      packageConfig: File(
        '$tools/.dart_tool/package_config.json',
      ).readAsStringSync(),
    );
  } finally {
    scratch.deleteSync(recursive: true);
  }
}
