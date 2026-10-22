// Fetches and pins SHA-256 checksums for Dart cross-compilation SDK artifacts
// (`gen_snapshot_<host>_<target>` and `dartaotruntime_<target>`) across all
// versions in `TOOL_VERSIONS` and writes `dart/private/versions.bzl`.
//
// Run with:
//   bazel run //dart/private/tools:update_cross_sdk_versions
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Supported host platforms and their `(os, arch)` Dart SDK identifiers.
/// Mirrors `PLATFORMS` in `dart/private/toolchains_repo.bzl`.
const Map<String, (String, String)> hostPlatforms = {
  'macos-arm64': ('macos', 'arm64'),
  'macos-x64': ('macos', 'x64'),
  'linux-x64': ('linux', 'x64'),
  'linux-arm64': ('linux', 'arm64'),
  'windows-x64': ('windows', 'x64'),
};

/// Supported cross-compilation target platforms and their `(os, arch)` Dart SDK
/// identifiers. Mirrors `PLATFORMS` + `TARGET_ONLY_PLATFORMS` in
/// `dart/private/toolchains_repo.bzl`.
const Map<String, (String, String)> crossTargetPlatforms = {
  'linux-arm': ('linux', 'arm'),
  'linux-arm64': ('linux', 'arm64'),
  'linux-riscv64': ('linux', 'riscv64'),
  'linux-x64': ('linux', 'x64'),
};

/// Supported `(host -> targets)` cross-compilation pairs.
/// Mirrors `CROSS_TARGETS` in `dart/private/toolchains_repo.bzl`.
const Map<String, List<String>> crossTargets = {
  'macos-arm64': ['linux-x64', 'linux-arm64', 'linux-riscv64', 'linux-arm'],
  'macos-x64': ['linux-x64', 'linux-arm64', 'linux-riscv64', 'linux-arm'],
  'windows-x64': ['linux-x64', 'linux-arm64', 'linux-riscv64', 'linux-arm'],
  'linux-x64': ['linux-arm64', 'linux-riscv64', 'linux-arm'],
  'linux-arm64': ['linux-x64', 'linux-riscv64', 'linux-arm'],
};

const _cdnReleaseBase =
    'https://storage.googleapis.com/dart-archive/channels/stable/release';

/// Returns the CDN filename of the cross `gen_snapshot` binary for
/// [hostPlatform] targeting [targetPlatform].
String crossGenSnapshotFilename(String hostPlatform, String targetPlatform) {
  final host = hostPlatforms[hostPlatform];
  if (host == null) {
    throw ArgumentError.value(
      hostPlatform,
      'hostPlatform',
      'Unsupported host platform',
    );
  }
  final target = crossTargetPlatforms[targetPlatform];
  if (target == null) {
    throw ArgumentError.value(
      targetPlatform,
      'targetPlatform',
      'Unsupported cross target platform',
    );
  }
  final allowedTargets = crossTargets[hostPlatform] ?? const [];
  if (!allowedTargets.contains(targetPlatform)) {
    throw ArgumentError(
      'Unsupported cross-compilation pair: $hostPlatform -> $targetPlatform',
    );
  }
  final ext = host.$1 == 'windows' ? '.exe' : '';
  return 'gen_snapshot_${host.$1}_${host.$2}_${target.$1}_${target.$2}$ext';
}

/// Returns the CDN filename of the cross `dartaotruntime` binary for
/// [targetPlatform].
String crossDartaotruntimeFilename(String targetPlatform) {
  final target = crossTargetPlatforms[targetPlatform];
  if (target == null) {
    throw ArgumentError.value(
      targetPlatform,
      'targetPlatform',
      'Unsupported cross target platform',
    );
  }
  return 'dartaotruntime_${target.$1}_${target.$2}';
}

/// Returns the CDN download URL for a cross `gen_snapshot` binary.
String crossGenSnapshotUrl(
  String version,
  String hostPlatform,
  String targetPlatform,
) {
  final filename = crossGenSnapshotFilename(hostPlatform, targetPlatform);
  return '$_cdnReleaseBase/$version/sdk/$filename';
}

/// Returns the CDN download URL for a target `dartaotruntime` binary.
String crossDartaotruntimeUrl(String version, String targetPlatform) {
  final filename = crossDartaotruntimeFilename(targetPlatform);
  return '$_cdnReleaseBase/$version/sdk/$filename';
}

/// Extracts the ordered list of SDK version keys from `TOOL_VERSIONS` in
/// `versions.bzl`.
List<String> parseToolVersions(String versionsBzlContent) {
  final toolVersionsBlock = _extractTopLevelDict(
    versionsBzlContent,
    'TOOL_VERSIONS',
  );
  final versionEntryPattern = RegExp(r'^\s{4}"([^"]+)":\s*\{', multiLine: true);
  return [
    for (final match in versionEntryPattern.allMatches(toolVersionsBlock))
      match.group(1)!,
  ];
}

/// Extracts existing nested `version -> key -> sha256` entries from [dictName]
/// in [versionsBzlContent], or returns an empty map when [dictName] is absent.
Map<String, Map<String, String>> parseExistingNestedPins(
  String versionsBzlContent,
  String dictName,
) {
  if (!versionsBzlContent.contains('$dictName = {')) {
    return {};
  }
  final block = _extractTopLevelDict(versionsBzlContent, dictName);
  final result = <String, Map<String, String>>{};
  String? currentVersion;
  for (final rawLine in block.split('\n')) {
    final versionMatch = RegExp(r'^\s{4}"([^"]+)":\s*\{\s*$')
        .firstMatch(rawLine);
    if (versionMatch != null) {
      currentVersion = versionMatch.group(1)!;
      result[currentVersion] = <String, String>{};
      continue;
    }
    if (currentVersion != null) {
      final entryMatch = RegExp(r'^\s{8}"([^"]+)":\s*"([0-9a-fA-F]{64})",\s*$')
          .firstMatch(rawLine);
      if (entryMatch != null) {
        result[currentVersion]![entryMatch.group(1)!] = entryMatch
            .group(2)!
            .toLowerCase();
      } else if (RegExp(r'^\s{4}\},\s*$').hasMatch(rawLine)) {
        currentVersion = null;
      }
    }
  }
  return result;
}

String _extractTopLevelDict(String content, String dictName) {
  final startMarker = '$dictName = {';
  final start = content.indexOf(startMarker);
  if (start < 0) {
    throw FormatException('Could not find `$dictName = {` in versions.bzl');
  }
  final endMarker = '\n}\n';
  final end = content.indexOf(endMarker, start);
  if (end < 0) {
    throw FormatException('Could not find closing `}` for $dictName');
  }
  return content.substring(start, end + endMarker.length);
}

/// Renders the complete `dart/private/versions.bzl` content preserving the
/// existing `TOOL_VERSIONS` prefix and appending `CROSS_GEN_SNAPSHOT_VERSIONS`
/// and `CROSS_DARTAOTRUNTIME_VERSIONS`.
String renderVersionsBzl({
  required String existingContent,
  required List<String> versions,
  required Map<String, Map<String, String>> genSnapshotVersions,
  required Map<String, Map<String, String>> dartaotruntimeVersions,
}) {
  final toolVersionsEnd = existingContent.indexOf('\n}\n');
  if (toolVersionsEnd < 0) {
    throw const FormatException(
      'Could not find end of TOOL_VERSIONS in versions.bzl',
    );
  }
  final prefix = existingContent.substring(0, toolVersionsEnd + 3);
  final buf = StringBuffer(prefix)
    ..writeln()
    ..writeln('# SHA256 checksums for cross-compilation gen_snapshot binaries,')
    ..writeln('# keyed by SDK version and `<exec_platform>_<target_platform>`.')
    ..writeln(
      '# Refresh with: bazel run //dart/private/tools:update_cross_sdk_versions',
    )
    ..writeln('CROSS_GEN_SNAPSHOT_VERSIONS = {');

  for (final version in versions) {
    final pairs = genSnapshotVersions[version];
    if (pairs == null) {
      throw StateError('Missing gen_snapshot pins for version $version');
    }
    buf.writeln('    "$version": {');
    final sortedKeys = pairs.keys.toList()..sort();
    for (final key in sortedKeys) {
      buf.writeln('        "$key": "${pairs[key]!}",');
    }
    buf.writeln('    },');
  }
  buf
    ..writeln('}')
    ..writeln()
    ..writeln(
      '# SHA256 checksums for cross-compilation target dartaotruntime binaries,',
    )
    ..writeln('# keyed by SDK version and `<target_platform>`.')
    ..writeln(
      '# Refresh with: bazel run //dart/private/tools:update_cross_sdk_versions',
    )
    ..writeln('CROSS_DARTAOTRUNTIME_VERSIONS = {');

  for (final version in versions) {
    final targets = dartaotruntimeVersions[version];
    if (targets == null) {
      throw StateError('Missing dartaotruntime pins for version $version');
    }
    buf.writeln('    "$version": {');
    final sortedKeys = targets.keys.toList()..sort();
    for (final key in sortedKeys) {
      buf.writeln('        "$key": "${targets[key]!}",');
    }
    buf.writeln('    },');
  }
  buf.writeln('}');
  return buf.toString();
}

Future<String> _fetchSha256(HttpClient client, Uri url) async {
  for (var attempt = 1; attempt <= 3; attempt++) {
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException(
          'HTTP ${response.statusCode} fetching $url',
          uri: url,
        );
      }
      final digest = await sha256.bind(response).first;
      return digest.toString();
    } on Object {
      if (attempt == 3) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
    }
  }
  throw StateError('unreachable');
}

Future<void> main(List<String> args) async {
  final parsed = _parseVersionsArgs(args);
  final versionsBzlPath = _resolveVersionsBzl(parsed.versionsBzlPath);

  final file = File(versionsBzlPath);
  if (!file.existsSync()) {
    stderr.writeln(
      'update_cross_sdk_versions: versions.bzl not found at $versionsBzlPath',
    );
    exit(1);
  }

  final existingContent = file.readAsStringSync();
  final versions = parseToolVersions(existingContent);
  final pins = _loadExistingPins(existingContent, force: parsed.force);

  final client = HttpClient();
  try {
    final tasks = _planFetchTasks(
      versions: versions,
      genSnapshotPins: pins.genSnapshot,
      dartaotruntimePins: pins.dartaotruntime,
      client: client,
    );
    await _runFetchTasks(tasks);
    final rendered = renderVersionsBzl(
      existingContent: existingContent,
      versions: versions,
      genSnapshotVersions: pins.genSnapshot,
      dartaotruntimeVersions: pins.dartaotruntime,
    );
    file.writeAsStringSync(rendered);
    stdout.writeln(
      'Updated $versionsBzlPath (${versions.length} SDK versions, '
      '${tasks.length} artifacts fetched).',
    );
  } finally {
    client.close(force: true);
  }
}

/// Parsed `update_cross_sdk_versions` command line.
typedef _VersionsArgs = ({String? versionsBzlPath, bool force});

/// Parses the command line, rejecting unknown arguments.
_VersionsArgs _parseVersionsArgs(List<String> args) {
  String? versionsBzlPath;
  var force = false;
  for (final arg in args) {
    if (arg == '--force') {
      force = true;
    } else if (arg.startsWith('--versions-bzl=')) {
      versionsBzlPath = arg.substring('--versions-bzl='.length);
    } else {
      stderr.writeln('update_cross_sdk_versions: unknown argument: $arg');
      exit(64);
    }
  }
  return (versionsBzlPath: versionsBzlPath, force: force);
}

/// The `versions.bzl` to update: the flag, or the workspace checkout's.
String _resolveVersionsBzl(String? flagPath) {
  if (flagPath != null) return flagPath;
  final workspace = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (workspace != null && workspace.isNotEmpty) {
    return '$workspace/dart/private/versions.bzl';
  }
  return 'dart/private/versions.bzl';
}

/// Existing cross pins, or empty maps under `--force`.
({
  Map<String, Map<String, String>> genSnapshot,
  Map<String, Map<String, String>> dartaotruntime,
})
_loadExistingPins(String existingContent, {required bool force}) {
  if (force) {
    return (
      genSnapshot: <String, Map<String, String>>{},
      dartaotruntime: <String, Map<String, String>>{},
    );
  }
  return (
    genSnapshot: parseExistingNestedPins(
      existingContent,
      'CROSS_GEN_SNAPSHOT_VERSIONS',
    ),
    dartaotruntime: parseExistingNestedPins(
      existingContent,
      'CROSS_DARTAOTRUNTIME_VERSIONS',
    ),
  );
}

/// One fetch per unpinned artifact, writing its digest into [genSnapshotPins]
/// or [dartaotruntimePins] when run.
List<Future<void> Function()> _planFetchTasks({
  required List<String> versions,
  required Map<String, Map<String, String>> genSnapshotPins,
  required Map<String, Map<String, String>> dartaotruntimePins,
  required HttpClient client,
}) {
  final tasks = <Future<void> Function()>[];
  for (final version in versions) {
    final gsMap = genSnapshotPins.putIfAbsent(version, () => {});
    final rtMap = dartaotruntimePins.putIfAbsent(version, () => {});
    _planGenSnapshotFetches(version, gsMap, client, tasks);
    _planDartaotruntimeFetches(version, rtMap, client, tasks);
  }
  return tasks;
}

/// Queues a fetch for each unpinned `(host -> target)` gen_snapshot binary.
void _planGenSnapshotFetches(
  String version,
  Map<String, String> gsMap,
  HttpClient client,
  List<Future<void> Function()> tasks,
) {
  for (final entry in crossTargets.entries) {
    final host = entry.key;
    for (final target in entry.value) {
      final pairKey = '${host}_$target';
      if (gsMap[pairKey] == null || gsMap[pairKey]!.isEmpty) {
        final url = Uri.parse(crossGenSnapshotUrl(version, host, target));
        tasks.add(() async {
          final digest = await _fetchSha256(client, url);
          gsMap[pairKey] = digest;
          stdout.writeln('Pinned $version $pairKey -> $digest');
        });
      }
    }
  }
}

/// Queues a fetch for each unpinned target dartaotruntime binary.
void _planDartaotruntimeFetches(
  String version,
  Map<String, String> rtMap,
  HttpClient client,
  List<Future<void> Function()> tasks,
) {
  for (final target in crossTargetPlatforms.keys) {
    if (rtMap[target] == null || rtMap[target]!.isEmpty) {
      final url = Uri.parse(crossDartaotruntimeUrl(version, target));
      tasks.add(() async {
        final digest = await _fetchSha256(client, url);
        rtMap[target] = digest;
        stdout.writeln('Pinned $version dartaotruntime $target -> $digest');
      });
    }
  }
}

/// Runs fetch tasks with bounded concurrency.
Future<void> _runFetchTasks(List<Future<void> Function()> tasks) async {
  const concurrency = 16;
  var nextIndex = 0;
  Future<void> worker() async {
    while (true) {
      final idx = nextIndex++;
      if (idx >= tasks.length) break;
      await tasks[idx]();
    }
  }

  await Future.wait([
    for (var i = 0; i < concurrency && i < tasks.length; i++) worker(),
  ]);
}
