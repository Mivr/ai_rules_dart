/// The modules of this repository that are released, and their tags.
///
/// `.github/release.json` at the repository root names, for each module, the
/// prefix of its tags (`rules_dart-v` for `rules_dart-v0.29.0`) and the last
/// release made before the module moved here, which is the version a first
/// tag must beat and the commit the first release notes start at.
library;

import 'dart:convert';

/// A release version: `v1.2.3`.
typedef Version = ({int major, int minor, int patch});

final _semver = RegExp(r'^v(\d+)\.(\d+)\.(\d+)$');

/// The version of `vMAJOR.MINOR.PATCH`, or null for any other text.
Version? parseVersion(String text) {
  final RegExpMatch? m = _semver.firstMatch(text.trim());
  if (m == null) return null;
  return (
    major: int.parse(m[1]!),
    minor: int.parse(m[2]!),
    patch: int.parse(m[3]!),
  );
}

/// `vMAJOR.MINOR.PATCH`.
String showVersion(Version v) => 'v${v.major}.${v.minor}.${v.patch}';

/// Negative when [a] is older than [b], zero when equal, positive when newer.
int compareVersions(Version a, Version b) {
  if (a.major != b.major) return a.major - b.major;
  if (a.minor != b.minor) return a.minor - b.minor;
  return a.patch - b.patch;
}

/// One released module.
final class ReleaseModule {
  /// Creates a module record.
  const ReleaseModule({
    required this.name,
    required this.tagPrefix,
    required this.baseline,
    required this.baselineCommit,
  });

  /// The module's directory and name: `rules_dart`.
  final String name;

  /// What a tag starts with before the version: `rules_dart-v`.
  final String tagPrefix;

  /// The last release before the module moved into this repository.
  final Version baseline;

  /// The commit of [baseline] in this repository's history.
  final String baselineCommit;

  /// The tag of [version]: `rules_dart-v0.29.0`.
  String tagOf(Version version) =>
      '$tagPrefix${version.major}.${version.minor}.${version.patch}';

  /// The version a tag of this module names, or null for any other tag
  /// (another module's, an old `v0.28.3`, a tag of no release shape).
  Version? versionOfTag(String tag) {
    final String t = tag.trim();
    if (!t.startsWith(tagPrefix)) return null;
    return parseVersion('v${t.substring(tagPrefix.length)}');
  }
}

/// Reads `.github/release.json`: an object of module name to
/// `{"tag_prefix": ..., "baseline": {"tag": "v0.28.3", "commit": "<sha>"}}`.
Map<String, ReleaseModule> parseModules(String json) {
  final Object? doc = jsonDecode(json);
  if (doc is! Map<String, Object?> || doc.isEmpty) {
    throw const FormatException('release.json must be a non-empty object');
  }
  final modules = <String, ReleaseModule>{};
  for (final MapEntry<String, Object?> e in doc.entries) {
    final Object? entry = e.value;
    final Object? baseline = entry is Map<String, Object?>
        ? entry['baseline']
        : null;
    if (entry is! Map<String, Object?> || baseline is! Map<String, Object?>) {
      throw FormatException(
        'release.json: ${e.key} needs tag_prefix, baseline',
      );
    }
    final Object? prefix = entry['tag_prefix'];
    final Object? tag = baseline['tag'];
    final Object? commit = baseline['commit'];
    final Version? version = tag is String ? parseVersion(tag) : null;
    if (prefix is! String ||
        prefix.isEmpty ||
        version == null ||
        commit is! String ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(commit)) {
      throw FormatException(
        'release.json: ${e.key} needs a tag_prefix and a baseline with a '
        'vX.Y.Z tag and a 40-digit commit',
      );
    }
    modules[e.key] = ReleaseModule(
      name: e.key,
      tagPrefix: prefix,
      baseline: version,
      baselineCommit: commit,
    );
  }
  return modules;
}
