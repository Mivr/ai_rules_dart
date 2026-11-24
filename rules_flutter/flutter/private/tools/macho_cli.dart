/// Shared `macho_edit` command-line helpers.
///
/// Usage errors, path allow-listing, the flag-word cursor, comma-list and
/// platform-version parsing used by every `macho_edit` subcommand.

import 'dart:io';

import 'macho_fat.dart' show parsePackedVersion, parsePlatform;

/// Prints a `macho_edit` usage error to stderr and exits with status 64.
Never usageError(String message) {
  stderr.writeln('macho_edit: $message');
  exit(64);
}

String _basename(String path) {
  final String normalized = path.replaceAll(r'\', '/');
  final Iterable<String> parts = normalized
      .split('/')
      .where((s) => s.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

String _stripExtension(String name) {
  final int dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// Checks whether a non-Mach-O or 32-bit binary is explicitly named in [allowList].
bool isAllowedNonMacho(
  Set<String> allowList, {
  required String inputPath,
  String? outputPath,
  String? installName,
}) {
  if (allowList.isEmpty) return false;
  if (allowList.contains('*')) return true;

  final candidates = <String>{};
  void addPathCandidates(String? p) {
    if (p == null || p.isEmpty) return;
    candidates.add(p);
    final String base = _basename(p);
    candidates.add(base);
    final String stem = _stripExtension(base);
    candidates.add(stem);
    if (stem.startsWith('lib') && stem.length > 3) {
      candidates.add(stem.substring(3));
    }
    for (final String seg in p.replaceAll(r'\', '/').split('/')) {
      if (seg.endsWith('.framework')) {
        candidates.add(seg);
        candidates.add(seg.substring(0, seg.length - '.framework'.length));
      }
    }
  }

  addPathCandidates(inputPath);
  addPathCandidates(outputPath);
  addPathCandidates(installName);
  return candidates.any(allowList.contains);
}

/// Cursor over CLI flag words with take/peek helpers for `--flag value` pairs.
class FlagCursor {
  new(this.args);

  /// The flag words being scanned.
  final List<String> args;
  int _index = -1;

  /// Advances to the next flag word; false when the words are exhausted.
  bool moveNext() {
    _index++;
    return _index < args.length;
  }

  /// The current flag word.
  String get current => args[_index];

  /// The next word without consuming it, or null when exhausted.
  String? peek() => _index + 1 < args.length ? args[_index + 1] : null;

  /// Consumes the next word as [flag]'s value, failing usage when absent.
  String take(String flag) {
    if (++_index >= args.length) usageError('$flag requires a value');
    return args[_index];
  }
}

/// Appends the comma-separated parts of [value] to [into], skipping empties.
void addCommaParts(Set<String> into, String value) {
  for (final String part in value.split(',')) {
    if (part.isNotEmpty) into.add(part);
  }
}

/// Parses the `--platform`/`--min-os`/`--sdk-version` triple shared by the
/// `patch`, `stub` and `copy-files` subcommands. Returns nulls when neither
/// `--platform` nor `--min-os` was given; `--sdk-version` defaults to the
/// minimum OS version.
({int? platform, int? minOs, int? sdkVersion}) parsePlatformVersions(
  String? platformName,
  String? minOsStr,
  String? sdkVersionStr,
) {
  if (platformName == null && minOsStr == null) {
    return (platform: null, minOs: null, sdkVersion: null);
  }
  if (platformName == null || minOsStr == null) {
    usageError('--platform and --min-os must be provided together');
  }
  final int platform = parsePlatform(platformName);
  final int minOs = parsePackedVersion(minOsStr);
  return (
    platform: platform,
    minOs: minOs,
    sdkVersion: sdkVersionStr != null
        ? parsePackedVersion(sdkVersionStr)
        : minOs,
  );
}
