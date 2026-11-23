/// Lock file validation for the Maven pin guard.
///
/// A lock must be valid JSON of version 2 or 3, carry a 64-hex sha256 for
/// every artifact entry, and pin every coordinate the module declares at the
/// declared version (directly or through `conflict_resolution`).
library;

import 'dart:convert';

import 'module_parse.dart';

final RegExp _hex64Pattern = RegExp(r'^[0-9a-fA-F]{64}$');

/// Identifies the install a message is about.
typedef InstallSource = ({
  String workspacePath,
  String filePath,
  String installName,
});

/// Formats [message] with the workspace, file and install name in front.
String describeProblem(InstallSource source, String message) =>
    "workspace '${source.workspacePath}', file '${source.filePath}', "
    "install '${source.installName}': $message";

bool _hasValidSha256(Object? shasums) {
  if (shasums is! Map<String, Object?> || shasums.isEmpty) return false;
  for (final Object? sha in shasums.values) {
    if (sha is! String || !_hex64Pattern.hasMatch(sha)) return false;
  }
  return true;
}

/// Reports declared coordinates that lack a group, artifact or version.
List<String> validateDeclaredShape(
  InstallSource source,
  List<DeclaredCoordinate> declared,
) {
  return <String>[
    for (final DeclaredCoordinate c in declared)
      if (c.group.isEmpty || c.artifact.isEmpty || c.version.isEmpty)
        describeProblem(
          source,
          "declared artifact '${c.text}' needs an explicit non-empty group, "
          'artifact and version',
        ),
  ];
}

/// Checks every artifact entry for sha256s and collects the pinned versions
/// of each `group:artifact` into [versionsByGa].
List<String> _validateEntries(
  InstallSource source,
  Map<String, Object?> artifacts,
  Map<String, Set<String>> versionsByGa,
) {
  final errors = <String>[];
  for (final MapEntry<String, Object?> entry in artifacts.entries) {
    final Object? val = entry.value;
    final Object? shasums = val is Map<String, Object?> ? val['shasums'] : null;
    if (!_hasValidSha256(shasums)) {
      errors.add(
        describeProblem(
          source,
          "artifact '${entry.key}' has no 64-hex sha256 under shasums",
        ),
      );
    }
    final List<String> parts = entry.key.split(':');
    final Object? version = val is Map<String, Object?> ? val['version'] : null;
    if (parts.length >= 2 && version is String) {
      versionsByGa
          .putIfAbsent('${parts[0]}:${parts[1]}', () => <String>{})
          .add(version);
    }
  }
  return errors;
}

bool _isPinned(
  String ga,
  String version,
  Set<String> pinned,
  Object? conflictResolution,
) {
  if (pinned.contains(version)) return true;
  if (conflictResolution is! Map<String, Object?>) return false;
  final Object? resolved = conflictResolution['$ga:$version'];
  if (resolved is! String || !resolved.startsWith('$ga:')) return false;
  return pinned.contains(resolved.substring(ga.length + 1));
}

List<String> _validateVersions(
  InstallSource source,
  List<DeclaredCoordinate> declared,
  Map<String, Set<String>> versionsByGa,
  Object? conflictResolution,
) {
  final errors = <String>[];
  for (final c in declared) {
    if (c.group.isEmpty || c.artifact.isEmpty || c.version.isEmpty) continue;
    final ga = '${c.group}:${c.artifact}';
    final Set<String>? pinned = versionsByGa[ga];
    if (pinned == null) {
      errors.add(
        describeProblem(
          source,
          "declared artifact '${c.text}' ($ga) is absent from lock",
        ),
      );
    } else if (!_isPinned(ga, c.version, pinned, conflictResolution)) {
      errors.add(
        describeProblem(
          source,
          "declared artifact '${c.text}' ($ga) version '${c.version}' is not "
          'pinned in lock (lock has ${(pinned.toList()..sort()).join(', ')})',
        ),
      );
    }
  }
  return errors;
}

/// Validates the JSON content and entries of a Maven lock file against the
/// coordinates [declared] by the install.
List<String> validateLockContent({
  required InstallSource source,
  required String lockJsonContent,
  required List<DeclaredCoordinate> declared,
}) {
  Object? decoded;
  try {
    decoded = jsonDecode(lockJsonContent);
  } on FormatException {
    return [describeProblem(source, 'lock file is not valid JSON')];
  }
  if (decoded is! Map<String, Object?>) {
    return [
      describeProblem(
        source,
        'lock file is not valid JSON (expected JSON object)',
      ),
    ];
  }

  final errors = <String>[];
  final Object? rawVersion = decoded['version'];
  if (rawVersion != '2' && rawVersion != '3') {
    errors.add(
      describeProblem(
        source,
        "expected lock version 2 or 3, got '$rawVersion'",
      ),
    );
  }
  final Object? artifacts = decoded['artifacts'];
  if (artifacts is! Map<String, Object?> || artifacts.isEmpty) {
    errors.add(describeProblem(source, 'lock file has no valid artifacts map'));
    return errors;
  }

  final versionsByGa = <String, Set<String>>{};
  errors
    ..addAll(_validateEntries(source, artifacts, versionsByGa))
    ..addAll(
      _validateVersions(
        source,
        declared,
        versionsByGa,
        decoded['conflict_resolution'],
      ),
    );
  return errors;
}
