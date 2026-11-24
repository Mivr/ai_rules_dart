// Fetches and pins every SHA-256 checksum an SDK version needs, in one run:
//
// - the SDK archive of each host platform (`TOOL_VERSIONS`), from the
//   `.sha256sum` file the Dart bucket publishes next to it;
// - the cross-compilation artifacts (`gen_snapshot_<host>_<target>` and
//   `dartaotruntime_<target>`), hashed as they are downloaded;
// - the module compiler's source archive, the tag archive of the SDK, hashed
//   as it is downloaded, with the SDK's commit read from the bucket's
//   `VERSION` file (`MODULE_COMPILER_SOURCES`).
//
// Usage:
//   bazel run //dart/private/tools:update_cross_sdk_versions -- [--drop=<version>]... [<version>]...
//
// Each `<version>` is added to `TOOL_VERSIONS` when it is not there, newest
// first; each `--drop=<version>` removes one. Every listed version then gets
// the pins it lacks, and a version no longer listed loses its pins, so the
// three tables always list the same versions. With no arguments it only
// fills what is missing. `--force` hashes every cross artifact again.
import 'dart:async';
import 'dart:convert';
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
  final (String, String)? host = hostPlatforms[hostPlatform];
  if (host == null) {
    throw ArgumentError.value(
      hostPlatform,
      'hostPlatform',
      'Unsupported host platform',
    );
  }
  final (String, String)? target = crossTargetPlatforms[targetPlatform];
  if (target == null) {
    throw ArgumentError.value(
      targetPlatform,
      'targetPlatform',
      'Unsupported cross target platform',
    );
  }
  final List<String> allowedTargets = crossTargets[hostPlatform] ?? const [];
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
  final (String, String)? target = crossTargetPlatforms[targetPlatform];
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
  final String filename = crossGenSnapshotFilename(
    hostPlatform,
    targetPlatform,
  );
  return '$_cdnReleaseBase/$version/sdk/$filename';
}

/// Returns the CDN download URL for a target `dartaotruntime` binary.
String crossDartaotruntimeUrl(String version, String targetPlatform) {
  final String filename = crossDartaotruntimeFilename(targetPlatform);
  return '$_cdnReleaseBase/$version/sdk/$filename';
}

/// Extracts the ordered list of SDK version keys from `TOOL_VERSIONS` in
/// `versions.bzl`.
List<String> parseToolVersions(String versionsBzlContent) {
  final String toolVersionsBlock = _extractTopLevelDict(
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
  final String block = _extractTopLevelDict(versionsBzlContent, dictName);
  final result = <String, Map<String, String>>{};
  String? currentVersion;
  for (final String rawLine in block.split('\n')) {
    final RegExpMatch? versionMatch = RegExp(r'^\s{4}"([^"]+)":\s*\{\s*$')
        .firstMatch(rawLine);
    if (versionMatch != null) {
      currentVersion = versionMatch.group(1)!;
      result[currentVersion] = <String, String>{};
      continue;
    }
    if (currentVersion != null) {
      final RegExpMatch? entryMatch = RegExp(
        r'^\s{8}"([^"]+)":\s*"([0-9a-fA-F]{64})",\s*$',
      ).firstMatch(rawLine);
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
  final int start = content.indexOf(startMarker);
  if (start < 0) {
    throw FormatException('Could not find `$dictName = {` in versions.bzl');
  }
  final endMarker = '\n}\n';
  final int end = content.indexOf(endMarker, start);
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
  final int toolVersionsEnd = existingContent.indexOf('\n}\n');
  if (toolVersionsEnd < 0) {
    throw const FormatException(
      'Could not find end of TOOL_VERSIONS in versions.bzl',
    );
  }
  final String prefix = existingContent.substring(0, toolVersionsEnd + 3);
  final buf = StringBuffer(prefix)
    ..writeln()
    ..writeln('# SHA256 checksums for cross-compilation gen_snapshot binaries,')
    ..writeln('# keyed by SDK version and `<exec_platform>_<target_platform>`.')
    ..writeln(
      '# Refresh with: bazel run //dart/private/tools:update_cross_sdk_versions',
    )
    ..writeln('CROSS_GEN_SNAPSHOT_VERSIONS = {');

  for (final version in versions) {
    final Map<String, String>? pairs = genSnapshotVersions[version];
    if (pairs == null) {
      throw StateError('Missing gen_snapshot pins for version $version');
    }
    buf.writeln('    "$version": {');
    final List<String> sortedKeys = pairs.keys.toList()..sort();
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
    final Map<String, String>? targets = dartaotruntimeVersions[version];
    if (targets == null) {
      throw StateError('Missing dartaotruntime pins for version $version');
    }
    buf.writeln('    "$version": {');
    final List<String> sortedKeys = targets.keys.toList()..sort();
    for (final key in sortedKeys) {
      buf.writeln('        "$key": "${targets[key]!}",');
    }
    buf.writeln('    },');
  }
  buf.writeln('}');
  return buf.toString();
}

const _tagArchiveBase = 'https://github.com/dart-lang/sdk/archive/refs/tags';

/// The CDN URL of the SDK archive for [platform].
String sdkArchiveUrl(String version, String platform) =>
    '$_cdnReleaseBase/$version/sdk/dartsdk-$platform-release.zip';

/// The URL of the `VERSION` file the bucket publishes for a release.
String releaseVersionUrl(String version) => '$_cdnReleaseBase/$version/VERSION';

/// The URL of the source archive of an SDK tag.
String tagArchiveUrl(String version) => '$_tagArchiveBase/$version.tar.gz';

/// The digest in the body of a `.sha256sum` file (`<hex>  <name>`), or null.
String? parseSha256sum(String body) {
  final String token = body.trim().split(RegExp(r'\s+')).first.toLowerCase();
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(token) ? token : null;
}

/// The commit the `VERSION` file in [body] names for [version].
///
/// Throws a [FormatException] when the file is not that release's.
String parseReleaseRevision(String body, String version) {
  final Object? json = jsonDecode(body);
  if (json is Map && json['version'] == version) {
    final Object? revision = json['revision'];
    if (revision is String && RegExp(r'^[0-9a-f]{40}$').hasMatch(revision)) {
      return revision;
    }
  }
  throw FormatException('no commit for Dart SDK $version in its VERSION file');
}

List<int> _releaseParts(String version) {
  final RegExpMatch? match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$')
      .firstMatch(version);
  if (match == null) {
    throw FormatException('not a release version (major.minor.patch)', version);
  }
  return [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
}

/// Orders two `<major>.<minor>.<patch>` release versions.
int compareReleaseVersions(String a, String b) {
  final List<int> left = _releaseParts(a);
  final List<int> right = _releaseParts(b);
  for (var i = 0; i < 3; i++) {
    if (left[i] != right[i]) return left[i].compareTo(right[i]);
  }
  return 0;
}

/// The SDK archive checksums of one version, as a `TOOL_VERSIONS` entry.
String renderToolVersionEntry(String version, Map<String, String> hashes) {
  final buf = StringBuffer('    "$version": {\n');
  for (final String platform in hostPlatforms.keys) {
    final String? hash = hashes[platform];
    if (hash == null) throw StateError('no $platform checksum for $version');
    buf.writeln('        "$platform": "$hash",');
  }
  buf.writeln('    },');
  return buf.toString();
}

/// The language versions of the five SDK packages in the first (newest) row of
/// `MODULE_COMPILER_SOURCES`.
Map<String, String> parseLanguageVersions(String moduleCompilerBzl) {
  final RegExpMatch? block = RegExp(
    r'language_versions = \{\n((?:            "[^"]+": "[^"]+",\n)+)        \},',
  ).firstMatch(moduleCompilerBzl);
  if (block == null) {
    throw const FormatException(
      'no language_versions in MODULE_COMPILER_SOURCES',
    );
  }
  return {
    for (final RegExpMatch m in RegExp(
      '"([^"]+)": "([^"]+)"',
    ).allMatches(block.group(1)!))
      m.group(1)!: m.group(2)!,
  };
}

/// One `MODULE_COMPILER_SOURCES` row.
String renderModuleCompilerRow({
  required String version,
  required String sha256,
  required String revision,
  required Map<String, String> languageVersions,
}) {
  final buf = StringBuffer()
    ..writeln('    "$version": struct(')
    ..writeln('        sha256 = "$sha256",')
    ..writeln('        revision = "$revision",')
    ..writeln('        language_versions = {');
  for (final String name in languageVersions.keys.toList()..sort()) {
    buf.writeln('            "$name": "${languageVersions[name]}",');
  }
  buf
    ..writeln('        },')
    ..writeln('    ),');
  return buf.toString();
}

/// The versions `MODULE_COMPILER_SOURCES` has a row for, newest first.
List<String> parseModuleCompilerVersions(String moduleCompilerBzl) => [
  for (final RegExpMatch m in RegExp(
    r'^    "([^"]+)": struct\(',
    multiLine: true,
  ).allMatches(_dictBody(moduleCompilerBzl, 'MODULE_COMPILER_SOURCES')))
    m.group(1)!,
];

const _toolVersionsTable = 'TOOL_VERSIONS';
const _moduleCompilerTable = 'MODULE_COMPILER_SOURCES';

/// `TOOL_VERSIONS` of [versionsBzl] with [entry] (from [renderToolVersionEntry])
/// added in order, newest first.
String insertToolVersion(String versionsBzl, String version, String entry) =>
    _insertRow(versionsBzl, _toolVersionsTable, version, entry, r'\{');

/// `TOOL_VERSIONS` of [versionsBzl] without [version].
String removeToolVersion(String versionsBzl, String version) =>
    _removeRow(versionsBzl, _toolVersionsTable, version, r'\{', '},');

/// `MODULE_COMPILER_SOURCES` of [moduleCompilerBzl] with [row] added in order.
String insertModuleCompilerRow(
  String moduleCompilerBzl,
  String version,
  String row,
) => _insertRow(
  moduleCompilerBzl,
  _moduleCompilerTable,
  version,
  row,
  r'struct\(',
);

/// `MODULE_COMPILER_SOURCES` of [moduleCompilerBzl] without [version].
String removeModuleCompilerRow(String moduleCompilerBzl, String version) =>
    _removeRow(
      moduleCompilerBzl,
      _moduleCompilerTable,
      version,
      r'struct\(',
      '),',
    );

/// The text between `<name> = {` and the closing brace of a top-level dict.
String _dictBody(String content, String name) {
  final int start = _dictStart(content, name);
  return content.substring(start, _dictEnd(content, start));
}

/// The index just after `<name> = {`.
int _dictStart(String content, String name) {
  final marker = '$name = {';
  final int at = content.indexOf(marker);
  if (at < 0) throw FormatException('Could not find `$marker`');
  return at + marker.length;
}

/// The index of the closing `}` of the dict whose body starts at [bodyStart].
int _dictEnd(String content, int bodyStart) {
  final int at = content.indexOf('\n}\n', bodyStart);
  if (at < 0) throw const FormatException('Could not find the closing `}`');
  return at + 1;
}

String _insertRow(
  String content,
  String table,
  String version,
  String row,
  String opener,
) {
  final int bodyStart = _dictStart(content, table);
  final int end = _dictEnd(content, bodyStart);
  var at = end;
  for (final RegExpMatch m in RegExp(
    '^    "([^"]+)": $opener',
    multiLine: true,
  ).allMatches(content, bodyStart)) {
    if (m.start >= end) break;
    final int order = compareReleaseVersions(m.group(1)!, version);
    if (order == 0) throw StateError('$version is already in $table');
    if (order < 0) {
      at = m.start;
      break;
    }
  }
  return content.substring(0, at) + row + content.substring(at);
}

String _removeRow(
  String content,
  String table,
  String version,
  String opener,
  String closer,
) {
  final int bodyStart = _dictStart(content, table);
  final int end = _dictEnd(content, bodyStart);
  final RegExpMatch? header = RegExp(
    '^    "${RegExp.escape(version)}": $opener\\s*\$',
    multiLine: true,
  ).firstMatch(content.substring(bodyStart, end));
  if (header == null) throw StateError('$version is not in $table');
  final int from = bodyStart + header.start;
  final closing = '\n    $closer\n';
  final int close = content.indexOf(closing, from);
  if (close < 0 || close >= end) {
    throw FormatException('Could not find the end of $version in $table');
  }
  return content.substring(0, from) + content.substring(close + closing.length);
}

Future<String> _fetchText(HttpClient client, Uri url) async {
  for (var attempt = 1; attempt <= 3; attempt++) {
    try {
      final HttpClientRequest request = await client.getUrl(url);
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException(
          'HTTP ${response.statusCode} fetching $url',
          uri: url,
        );
      }
      return await utf8.decodeStream(response);
    } on Object {
      if (attempt == 3) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
    }
  }
  throw StateError('unreachable');
}

/// The digest of the SDK archive of [platform]: the one the bucket publishes
/// in the `.sha256sum` file beside it, or, when there is none, the digest of
/// the archive as downloaded.
Future<String> _fetchSdkChecksum(
  HttpClient client,
  String version,
  String platform,
) async {
  final Uri archive = Uri.parse(sdkArchiveUrl(version, platform));
  try {
    final String? published = parseSha256sum(
      await _fetchText(client, Uri.parse('$archive.sha256sum')),
    );
    if (published != null) return published;
  } on HttpException {
    // Fall through to hashing the download.
  }
  stdout.writeln('No published checksum for $platform; hashing the download.');
  return await _fetchSha256(client, archive);
}

Future<String> _fetchSha256(HttpClient client, Uri url) async {
  for (var attempt = 1; attempt <= 3; attempt++) {
    try {
      final HttpClientRequest request = await client.getUrl(url);
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException(
          'HTTP ${response.statusCode} fetching $url',
          uri: url,
        );
      }
      final Digest digest = await sha256.bind(response).first;
      return digest.toString();
    } on Object {
      if (attempt == 3) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
    }
  }
  throw StateError('unreachable');
}

Future<void> main(List<String> args) async {
  final _Args parsed = _parseArgs(args);
  final String versionsBzlPath = _resolveWorkspaceFile(
    parsed.versionsBzlPath,
    'versions.bzl',
  );
  final String moduleCompilerBzlPath = _resolveWorkspaceFile(
    parsed.moduleCompilerBzlPath,
    'module_compiler_versions.bzl',
  );
  for (final path in [versionsBzlPath, moduleCompilerBzlPath]) {
    if (!File(path).existsSync()) {
      stderr.writeln('update_cross_sdk_versions: $path not found');
      exit(1);
    }
  }

  String versionsBzl = File(versionsBzlPath).readAsStringSync();
  String moduleCompilerBzl = File(moduleCompilerBzlPath).readAsStringSync();
  // Taken before any row goes: the newest row's package language versions are
  // what a new row starts from.
  final Map<String, String> languageVersions = parseLanguageVersions(
    moduleCompilerBzl,
  );
  final String languageVersionsFrom = parseModuleCompilerVersions(
    moduleCompilerBzl,
  ).first;

  for (final String version in parsed.drop) {
    versionsBzl = removeToolVersion(versionsBzl, version);
  }

  final client = HttpClient();
  try {
    // 1. The SDK archives of every version asked for and not listed.
    final List<String> listed = parseToolVersions(versionsBzl);
    final List<String> added = [
      for (final String version in parsed.add)
        if (!listed.contains(version)) version,
    ];
    final sdkHashes = <String, Map<String, String>>{
      for (final String version in added) version: {},
    };
    await _runFetchTasks([
      for (final String version in added)
        for (final String platform in hostPlatforms.keys)
          () async {
            final String digest = await _fetchSdkChecksum(
              client,
              version,
              platform,
            );
            sdkHashes[version]![platform] = digest;
            stdout.writeln('Pinned $version $platform -> $digest');
          },
    ]);
    for (final version in added) {
      versionsBzl = insertToolVersion(
        versionsBzl,
        version,
        renderToolVersionEntry(version, sdkHashes[version]!),
      );
    }
    final List<String> versions = parseToolVersions(versionsBzl);

    // 2. The cross-compilation artifacts of every listed version.
    final ({
      Map<String, Map<String, String>> dartaotruntime,
      Map<String, Map<String, String>> genSnapshot,
    })
    pins = _loadExistingPins(versionsBzl, force: parsed.force);
    final List<Future<void> Function()> crossTasks = _planFetchTasks(
      versions: versions,
      genSnapshotPins: pins.genSnapshot,
      dartaotruntimePins: pins.dartaotruntime,
      client: client,
    );
    await _runFetchTasks(crossTasks);
    versionsBzl = renderVersionsBzl(
      existingContent: versionsBzl,
      versions: versions,
      genSnapshotVersions: pins.genSnapshot,
      dartaotruntimeVersions: pins.dartaotruntime,
    );

    // 3. The module compiler's sources of every listed version.
    for (final String version in parseModuleCompilerVersions(
      moduleCompilerBzl,
    )) {
      if (!versions.contains(version)) {
        moduleCompilerBzl = removeModuleCompilerRow(moduleCompilerBzl, version);
      }
    }
    final List<String> pinned = parseModuleCompilerVersions(moduleCompilerBzl);
    final List<String> unpinned = [
      for (final String version in versions)
        if (!pinned.contains(version)) version,
    ];
    final rows = <String, ({String sha256, String revision})>{};
    await _runFetchTasks([
      for (final String version in unpinned)
        () async {
          final String revision = parseReleaseRevision(
            await _fetchText(client, Uri.parse(releaseVersionUrl(version))),
            version,
          );
          final String digest = await _fetchSha256(
            client,
            Uri.parse(tagArchiveUrl(version)),
          );
          rows[version] = (sha256: digest, revision: revision);
          stdout.writeln('Pinned $version module compiler sources -> $digest');
        },
    ]);
    for (final version in unpinned) {
      moduleCompilerBzl = insertModuleCompilerRow(
        moduleCompilerBzl,
        version,
        renderModuleCompilerRow(
          version: version,
          sha256: rows[version]!.sha256,
          revision: rows[version]!.revision,
          languageVersions: languageVersions,
        ),
      );
    }

    // Everything was fetched: only now do the files change.
    File(versionsBzlPath).writeAsStringSync(versionsBzl);
    File(moduleCompilerBzlPath).writeAsStringSync(moduleCompilerBzl);
    stdout.writeln(
      'Updated $versionsBzlPath (${versions.length} SDK versions, '
      '${added.length * hostPlatforms.length + crossTasks.length} '
      'artifacts fetched) and $moduleCompilerBzlPath '
      '(${unpinned.length} rows added).',
    );
    if (unpinned.isNotEmpty) {
      stdout.writeln(
        'The language_versions of the new rows are those of '
        '$languageVersionsFrom: they are the `sdk:` lower bounds in '
        'pkg/{_fe_analyzer_shared,build_integration,front_end,kernel,vm}/'
        'pubspec.yaml of the tag. If one moved, the module compiler does not '
        'build until the row says so.',
      );
    }
  } finally {
    client.close(force: true);
  }
}

/// Parsed `update_cross_sdk_versions` command line.
typedef _Args = ({
  List<String> add,
  List<String> drop,
  String? versionsBzlPath,
  String? moduleCompilerBzlPath,
  bool force,
});

/// Parses the command line, rejecting unknown arguments and versions that are
/// not releases.
_Args _parseArgs(List<String> args) {
  final add = <String>[];
  final drop = <String>[];
  String? versionsBzlPath;
  String? moduleCompilerBzlPath;
  var force = false;
  for (final arg in args) {
    if (arg == '--force') {
      force = true;
    } else if (arg.startsWith('--versions-bzl=')) {
      versionsBzlPath = arg.substring('--versions-bzl='.length);
    } else if (arg.startsWith('--module-compiler-bzl=')) {
      moduleCompilerBzlPath = arg.substring('--module-compiler-bzl='.length);
    } else if (arg.startsWith('--drop=')) {
      drop.add(arg.substring('--drop='.length));
    } else if (!arg.startsWith('-')) {
      add.add(arg);
    } else {
      stderr.writeln('update_cross_sdk_versions: unknown argument: $arg');
      exit(64);
    }
  }
  for (final version in [...add, ...drop]) {
    try {
      compareReleaseVersions(version, version);
    } on FormatException {
      stderr.writeln(
        'update_cross_sdk_versions: $version is not a release version '
        '(major.minor.patch)',
      );
      exit(64);
    }
  }
  return (
    add: add,
    drop: drop,
    versionsBzlPath: versionsBzlPath,
    moduleCompilerBzlPath: moduleCompilerBzlPath,
    force: force,
  );
}

/// The `dart/private/<name>` to update: the flag, or the workspace checkout's.
String _resolveWorkspaceFile(String? flagPath, String name) {
  if (flagPath != null) return flagPath;
  final String? workspace = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (workspace != null && workspace.isNotEmpty) {
    return '$workspace/dart/private/$name';
  }
  return 'dart/private/$name';
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
    final Map<String, String> gsMap = genSnapshotPins.putIfAbsent(
      version,
      () => {},
    );
    final Map<String, String> rtMap = dartaotruntimePins.putIfAbsent(
      version,
      () => {},
    );
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
  for (final MapEntry<String, List<String>> entry in crossTargets.entries) {
    final String host = entry.key;
    for (final String target in entry.value) {
      final pairKey = '${host}_$target';
      if (gsMap[pairKey] == null || gsMap[pairKey]!.isEmpty) {
        final Uri url = Uri.parse(crossGenSnapshotUrl(version, host, target));
        tasks.add(() async {
          final String digest = await _fetchSha256(client, url);
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
  for (final String target in crossTargetPlatforms.keys) {
    if (rtMap[target] == null || rtMap[target]!.isEmpty) {
      final Uri url = Uri.parse(crossDartaotruntimeUrl(version, target));
      tasks.add(() async {
        final String digest = await _fetchSha256(client, url);
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
      final int idx = nextIndex++;
      if (idx >= tasks.length) break;
      await tasks[idx]();
    }
  }

  await Future.wait([
    for (var i = 0; i < concurrency && i < tasks.length; i++) worker(),
  ]);
}
