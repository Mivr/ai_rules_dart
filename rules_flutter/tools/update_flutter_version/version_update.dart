/// Shared implementation for the Flutter version updater.
///
/// [`main.dart`](main.dart) stays a thin orchestrator; the cohesive steps live
/// here so each fits the tooling size limits and the pure ones are unit
/// testable. Behaviour (output text, exit codes, command arguments and their
/// order) is unchanged: this file only moves code.
library;

import 'dart:convert';
import 'dart:io';

import 'artifact_list.dart';

/// Base URL of the engine artifacts, keyed by engine revision.
const gcsBase = 'https://storage.googleapis.com/flutter_infra_release/flutter';

/// Where to run and what version to add, resolved from flags and environment.
class VersionRequest {
  /// Creates a resolved request.
  const new({
    required this.version,
    required this.workspaceDir,
    required this.flutterRepo,
  });

  /// The Flutter release tag, e.g. `3.42.0`.
  final String version;

  /// The rules_flutter checkout (`BUILD_WORKSPACE_DIRECTORY` under `bazel run`).
  final String workspaceDir;

  /// A clone of the Flutter repo (`FLUTTER_REPO`, else `references/flutter`).
  final String flutterRepo;
}

/// Resolves [args] to a [VersionRequest].
///
/// Prints usage and exits 1 when no version is given.
VersionRequest resolveVersionRequest(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: bazel run //tools/update_flutter_version -- <flutter-version>',
    );
    exit(1);
  }
  final String version = args[0];
  // Locate the Flutter repo. BUILD_WORKSPACE_DIRECTORY is set by `bazel run`.
  final String workspaceDir =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
      Directory.current.path;
  final String flutterRepo =
      Platform.environment['FLUTTER_REPO'] ??
      '$workspaceDir/references/flutter';
  return VersionRequest(
    version: version,
    workspaceDir: workspaceDir,
    flutterRepo: flutterRepo,
  );
}

/// The two revisions read out of the Flutter repo at the release tag.
class EngineRevisions {
  /// Creates both revisions.
  const new({
    required this.engineRev,
    required this.materialFontsUrl,
  });

  /// The engine commit `bin/internal/engine.version` points at.
  final String engineRev;

  /// The GCS path `bin/internal/material_fonts.version` points at.
  final String materialFontsUrl;
}

/// Reads the engine and material-fonts revisions for [version].
///
/// Prints both, and exits 1 when the tag (or either version file) is missing.
Future<EngineRevisions> readEngineRevisions(
  String version,
  String flutterRepo,
) async {
  // Get engine revision from the Flutter tag.
  final ProcessResult gitResult = Process.runSync(
    'git',
    ['show', '$version:bin/internal/engine.version'],
    workingDirectory: flutterRepo,
  );
  if (gitResult.exitCode != 0) {
    stderr.writeln(
      'ERROR: Could not find engine.version for tag $version in $flutterRepo',
    );
    stderr.writeln('Make sure the tag exists: git fetch --tags');
    exit(1);
  }
  final String engineRev = (gitResult.stdout as String).trim();
  print('Engine revision: $engineRev');

  // Get material fonts URL from the Flutter repo.
  final ProcessResult materialFontsResult = Process.runSync(
    'git',
    ['show', '$version:bin/internal/material_fonts.version'],
    workingDirectory: flutterRepo,
  );
  if (materialFontsResult.exitCode != 0) {
    stderr.writeln(
      'ERROR: Could not find material_fonts.version for tag $version',
    );
    exit(1);
  }
  final String materialFontsUrl = (materialFontsResult.stdout as String).trim();
  print('Material fonts URL: $materialFontsUrl');
  return EngineRevisions(
    engineRev: engineRev,
    materialFontsUrl: materialFontsUrl,
  );
}

/// What to download, grouped so the download step takes one argument.
class DownloadSpec {
  /// Creates the download inputs.
  const new({
    required this.version,
    required this.engineRev,
    required this.materialFontsUrl,
    required this.pinned,
    required this.pinnedSource,
  });

  /// The Flutter release tag (keys the GitHub source tarball).
  final String version;

  /// The engine commit (keys the GCS engine artifacts).
  final String engineRev;

  /// The GCS path of the material fonts archive.
  final String materialFontsUrl;

  /// Already-pinned engine artifact checksums, reused without downloading.
  final Map<String, String> pinned;

  /// The already-pinned source tarball checksum, if any.
  final String? pinnedSource;
}

/// The outcome of a download-and-hash step.
typedef ArtifactOutcome = ({
  Map<String, String> checksums,
  List<String> failures,
});

/// One download: where it comes from, what it is called, and which checksum
/// map key its hash is recorded under.
class HashTarget {
  /// Creates one download target.
  const new({
    required this.label,
    required this.url,
    required this.key,
  });

  /// The name printed in the progress line.
  final String label;

  /// Where to fetch the archive.
  final String url;

  /// The checksum map key for the resulting hash.
  final String key;
}

/// Downloads [target.url], hashes it, and prints the progress line.
///
/// Returns the hex digest, or null when the download or hash failed (after
/// printing `FAILED`). Never throws: failures are the caller's to record.
Future<String?> hashUrlInto(HttpClient client, HashTarget target) async {
  stdout.write('  ${target.label} ... ');
  try {
    final String sha = await _downloadAndHash(client, target.url);
    print(sha);
    return sha;
  } catch (e) {
    print('FAILED ($e)');
    return null;
  }
}

/// Downloads every artifact for [spec] and computes SHA-256.
///
/// Archives already pinned for this version are reused, not downloaded again.
/// Prints one progress line per artifact, in engine, source, fonts order.
Future<ArtifactOutcome> downloadAllChecksums(
  HttpClient client,
  DownloadSpec spec,
) async {
  final checksums = <String, String>{};
  final failures = <String>[];
  for (final String artifact in artifacts) {
    final String? known = spec.pinned[artifact];
    if (known != null) {
      checksums[artifact] = known;
      print('  $artifact ... $known (pinned)');
      continue;
    }
    final String? sha = await hashUrlInto(
      client,
      HashTarget(
        label: artifact,
        url: '$gcsBase/${spec.engineRev}/$artifact',
        key: artifact,
      ),
    );
    if (sha != null) {
      checksums[artifact] = sha;
    } else {
      failures.add(artifact);
    }
  }

  // The Flutter source tarball. Not an engine artifact — it comes from GitHub,
  // keyed by release tag rather than engine revision. Every rule that needs
  // Flutter's own Dart source pins this one checksum: the per-package SDK
  // spokes, the vendored gen-l10n generator, and the FLUTTER_ROOT tree behind
  // `flutter:pub`. A version entry without it cannot be built.
  if (spec.pinnedSource != null) {
    checksums['__source__'] = spec.pinnedSource!;
    print(
      '  flutter-${spec.version}.tar.gz (source) ... '
      '${spec.pinnedSource} (pinned)',
    );
  } else {
    final String? sha = await hashUrlInto(
      client,
      HashTarget(
        label: 'flutter-${spec.version}.tar.gz (source)',
        url:
            'https://github.com/flutter/flutter/archive/refs/tags/${spec.version}.tar.gz',
        key: '__source__',
      ),
    );
    if (sha != null) {
      checksums['__source__'] = sha;
    } else {
      failures.add('flutter-${spec.version}.tar.gz');
    }
  }

  // Download material fonts and compute checksum.
  final String? pinnedFonts = spec.pinned['material_fonts.zip'];
  if (pinnedFonts != null) {
    checksums['material_fonts.zip'] = pinnedFonts;
    print('  material_fonts.zip ... $pinnedFonts (pinned)');
  } else {
    final String? sha = await hashUrlInto(
      client,
      HashTarget(
        label: 'material_fonts.zip',
        url: 'https://storage.googleapis.com/${spec.materialFontsUrl}',
        key: 'material_fonts.zip',
      ),
    );
    if (sha != null) {
      checksums['material_fonts.zip'] = sha;
    } else {
      failures.add('material_fonts.zip');
    }
  }
  return (checksums: checksums, failures: failures);
}

/// Checks the Linux sysroot checksums against the engine's sysroots.json.
///
/// Reads the sysroots file at [version] from [flutterRepo] and compares it
/// with `LINUX_SYSROOT_CHECKSUMS` in versions.bzl under [workspaceDir],
/// printing either the suggested replacement block or that nothing moved.
Future<void> reportSysrootChecksums(
  String version,
  String flutterRepo,
  String workspaceDir,
) async {
  // Check Linux sysroot checksums from the engine's sysroots.json.
  // The file lives in the Flutter monorepo at the version tag, under
  // engine/src/build/linux/sysroot_scripts/sysroots.json.
  print('');
  print('Checking Linux sysroot checksums...');
  final sysrootsRef =
      '$version:engine/src/build/linux/sysroot_scripts/sysroots.json';
  final ProcessResult sysrootsResult = Process.runSync(
    'git',
    ['show', sysrootsRef],
    workingDirectory: flutterRepo,
  );
  if (sysrootsResult.exitCode == 0) {
    // Read current checksums from versions.bzl so we compare against the
    // actual committed values, not hardcoded copies. Deliberately outside the
    // try below, which reports whatever it catches as a sysroots.json parse
    // failure: a versions.bzl that can't be read is a different fact.
    final Map<String, String> currentChecksums = readCurrentSysrootChecksums(
      workspaceDir,
    );

    // The try covers the decode alone, which is the only step its message
    // describes. Reading the entries outside it is what lets them throw:
    // jsonDecode raises FormatException too, so a catch spanning both could
    // not tell a malformed file from one that simply lacks what we pin.
    Map<String, dynamic>? sysroots;
    try {
      sysroots =
          jsonDecode(sysrootsResult.stdout as String) as Map<String, dynamic>;
    } catch (e) {
      print('  WARNING: Failed to parse sysroots.json: $e');
    }

    if (sysroots != null) {
      final Map<String, String> newChecksums = readEngineSysrootChecksums(
        sysroots,
        sysrootsRef,
      );
      final bool changed =
          newChecksums['amd64'] != currentChecksums['amd64'] ||
          newChecksums['arm64'] != currentChecksums['arm64'];
      if (changed) {
        print('  WARNING: Sysroot checksums have changed!');
        print(
          '  Update LINUX_SYSROOT_CHECKSUMS in flutter/private/versions.bzl:',
        );
        print('');
        print('LINUX_SYSROOT_CHECKSUMS = {');
        print('    "amd64": "${newChecksums['amd64']}",');
        print('    "arm64": "${newChecksums['arm64']}",');
        print('}');
      } else {
        print('  Sysroot checksums unchanged.');
      }
    }
  } else {
    print(
      '  Could not read sysroots.json for tag $version (path may differ in older Flutter versions).',
    );
  }
}

/// Renders the failure report for [failures] (the caller sets the exit code).
String renderFailuresReport(List<String> failures) {
  final out = StringBuffer();
  out.writeln('');
  out.writeln(
    'ERROR: ${failures.length} artifact(s) could not be downloaded and hashed:',
  );
  for (final artifact in failures) {
    out.writeln('  $artifact');
  }
  out.writeln('Their entries above read MISSING. Fix the download and re-run.');
  return out.toString();
}

/// Renders the Starlark snippet for [version], byte for byte as printed.
///
/// Unhashed artifacts read `MISSING`, as the failure report says they do.
String renderVersionSnippet({
  required String version,
  required String engineRev,
  required String materialFontsUrl,
  required Map<String, String> checksums,
}) {
  String line(String artifact) =>
      '        "$artifact": "${checksums[artifact] ?? 'MISSING'}",';
  final out = StringBuffer();
  out.writeln('');
  out.writeln(
    '=== Add to FLUTTER_VERSIONS in flutter/private/versions.bzl ===',
  );
  out.writeln('');
  out.writeln('    "$version": struct(');
  out.writeln('        engine_revision = "$engineRev",');
  out.writeln('        material_fonts_url = "$materialFontsUrl",');
  out.writeln('        # sha256 of the GitHub source tarball. Required: every');
  out.writeln('        # fetch of the framework source is pinned against it.');
  out.writeln(
    '        source_sha256 = "${checksums['__source__'] ?? 'FIXME'}",',
  );
  out.writeln('    ),');
  out.writeln('');
  out.writeln(
    '=== Add to ARTIFACT_CHECKSUMS in flutter/private/versions.bzl ===',
  );
  out.writeln('');
  out.writeln('    "$version": {');
  for (final ArtifactSection section in artifactSections) {
    out.writeln('        # ${section.comment}');
    for (final String path in section.paths) {
      out.writeln(line(path));
    }
  }
  out.writeln(
    '        # Material design fonts (MaterialIcons-Regular.otf, Roboto family)',
  );
  out.writeln(line('material_fonts.zip'));
  out.writeln('    },');
  return out.toString();
}

/// A failure to produce an artifact's SHA-256, in either the download or the
/// hashing step.
///
/// A named type rather than a thrown `String`, because a raw string is neither
/// an `Exception` nor an `Error`: `on Exception` never matches one, so a caller
/// that ever catches selectively would miss these entirely. `toString` returns
/// the bare message, so the reports below print it unadorned.
class ArtifactChecksumException implements Exception {
  /// Creates the failure with its report text.
  new(this.message);

  /// The report text, printed unadorned.
  final String message;

  @override
  String toString() => message;
}

Future<String> _downloadAndHash(HttpClient client, String url) async {
  final Uri uri = Uri.parse(url);
  final HttpClientRequest request = await client.getUrl(uri);
  final HttpClientResponse response = await request.close();

  // Follow redirects manually if needed.
  if (response.statusCode == 302 || response.statusCode == 301) {
    final String? location = response.headers['location']?.first;
    if (location != null) {
      await response.drain<void>();
      return _downloadAndHash(client, location);
    }
  }

  if (response.statusCode != 200) {
    await response.drain<void>();
    throw ArtifactChecksumException('HTTP ${response.statusCode}');
  }

  // Download to a temp file, then compute SHA-256 using a platform-appropriate tool.
  final Directory tempDir = await Directory.systemTemp.createTemp(
    'flutter_hash_',
  );
  final tempFile = File('${tempDir.path}/artifact');
  final IOSink sink = tempFile.openWrite();
  await response.pipe(sink);

  try {
    final String hash = await _sha256OfFile(tempFile.path);
    return hash;
  } finally {
    await tempDir.delete(recursive: true);
  }
}

/// Reads LINUX_SYSROOT_CHECKSUMS from versions.bzl.
///
/// Returns a map like `{'amd64': '<sha256>', 'arm64': '<sha256>'}`, always with
/// both keys.
///
/// Throws [FileSystemException] if versions.bzl cannot be read, and
/// [FormatException] if it carries no `LINUX_SYSROOT_CHECKSUMS` block or that
/// block is missing an architecture. None of those states has a defensible
/// stand-in value: the caller compares what it gets here against the engine's
/// current checksums, so any placeholder reports "changed" — making a file this
/// tool failed to read indistinguishable from a checksum that genuinely moved,
/// at the moment that distinction matters most.
Map<String, String> readCurrentSysrootChecksums(String workspaceDir) {
  final path = '$workspaceDir/flutter/private/versions.bzl';
  final String content = File(path).readAsStringSync();

  // Bound the scan to this block's own braces, anchored at the top-level
  // assignment. Scanning from the marker to end of file instead would let any
  // later block carrying these keys overwrite the real values and win silently;
  // anchoring at line start keeps a differently-named block that merely ends in
  // this name (`OLD_LINUX_SYSROOT_CHECKSUMS`) from claiming the match.
  final RegExpMatch? block = RegExp(
    r'^LINUX_SYSROOT_CHECKSUMS\s*=\s*\{([^}]*)\}',
    multiLine: true,
  ).firstMatch(content);
  if (block == null) {
    throw FormatException('No LINUX_SYSROOT_CHECKSUMS block in $path');
  }

  // Match lines like:   "amd64": "abc123...",
  final pattern = RegExp(r'"(amd64|arm64)":\s*"([a-f0-9]+)"');
  final result = <String, String>{
    for (final match in pattern.allMatches(block.group(1)!))
      match.group(1)!: match.group(2)!,
  };

  for (final arch in const ['amd64', 'arm64']) {
    if (!result.containsKey(arch)) {
      throw FormatException(
        'No "$arch" checksum in LINUX_SYSROOT_CHECKSUMS in $path',
      );
    }
  }
  return result;
}

/// Reads the sysroot checksums we pin out of the engine's decoded sysroots.json.
///
/// Returns a map like `{'amd64': '<sha256>', 'arm64': '<sha256>'}`, always with
/// both keys — the mirror of [readCurrentSysrootChecksums], so the caller
/// compares two complete maps and can print both lines of its suggested
/// replacement block unconditionally.
///
/// Throws [FormatException] naming [source] if either bullseye entry is absent
/// or carries no string `Sha256Sum`. An absent entry is a state upstream really
/// ships: Flutter through 3.35.x keyed this file `sid_*`, 3.38 onward
/// `bullseye_*`, and today's file already carries a `trixie_riscv64` from the
/// next such migration. So a missing entry means the sysroot generation we pin
/// moved, not that the file is corrupt — and no replacement checksum exists to
/// suggest, because the entry it would come from is gone. The keys that were
/// found go in the message, since those are the new names.
Map<String, String> readEngineSysrootChecksums(
  Map<String, dynamic> sysroots,
  String source,
) {
  final result = <String, String>{};
  for (final arch in const ['amd64', 'arm64']) {
    final dynamic entry = sysroots['bullseye_$arch'];
    if (entry == null) {
      throw FormatException(
        'No "bullseye_$arch" entry in $source '
        '(found: ${sysroots.keys.join(', ')})',
      );
    }
    final dynamic sha = entry is Map ? entry['Sha256Sum'] : null;
    if (sha is! String) {
      throw FormatException(
        'No string "Sha256Sum" for "bullseye_$arch" in $source',
      );
    }
    result[arch] = sha;
  }
  return result;
}

Future<String> _sha256OfFile(String path) async {
  if (Platform.isWindows) {
    // certutil outputs multiple lines; the hash is on the second line.
    final ProcessResult result = await Process.run('certutil', [
      '-hashfile',
      path,
      'SHA256',
    ]);
    if (result.exitCode != 0) {
      throw ArtifactChecksumException('certutil failed: ${result.stderr}');
    }
    final List<String> lines = (result.stdout as String).trim().split('\n');
    if (lines.length < 2) {
      throw ArtifactChecksumException('Unexpected certutil output');
    }
    return lines[1].trim().replaceAll(' ', '');
  } else {
    // macOS and Linux: use sha256sum (Linux) or shasum -a 256 (macOS).
    ProcessResult result;
    if (Platform.isMacOS) {
      result = await Process.run('shasum', ['-a', '256', path]);
    } else {
      result = await Process.run('sha256sum', [path]);
    }
    if (result.exitCode != 0) {
      throw ArtifactChecksumException('sha256 hash failed: ${result.stderr}');
    }
    return (result.stdout as String).split(' ').first;
  }
}
