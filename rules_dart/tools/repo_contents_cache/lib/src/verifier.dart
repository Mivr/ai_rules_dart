/// Verification, CLI argument parsing, and repo-mapping helpers for repository
/// contents cache checks.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// An exception thrown when repository contents cache verification fails.
final class CheckFailure implements Exception {
  /// Creates a [CheckFailure] describing the failed invariant.
  const new(this.message);

  /// Human-readable description of the failure.
  final String message;

  @override
  String toString() => message;
}

/// Configuration for running repository contents cache checks across output bases.
final class CheckConfig {
  /// Creates a [CheckConfig] for verifying [workspaceDir].
  const new({
    required this.workspaceDir,
    required this.reproducibleRepos,
    this.probeRepos = const [],
    this.checkScanner = false,
  });

  /// Directory of the workspace under test.
  final String workspaceDir;

  /// Repositories expected to be reproducible and stored in the contents cache.
  final List<String> reproducibleRepos;

  /// Repositories expected to remain un-cached real directories (negative probe cases).
  final List<String> probeRepos;

  /// Whether to assert the scanner's snapshot is byte-identical across output bases.
  final bool checkScanner;
}

/// Parses command-line [args] into a [CheckConfig].
///
/// Throws a [FormatException] when arguments are missing or invalid.
CheckConfig parseCheckArgs(List<String> args) {
  if (args.isEmpty) {
    throw const FormatException(
      'Usage: check -- <ws> <repo>... [--probe <repo>] [--scanner]',
    );
  }

  String? wsDir;
  final repos = <String>[];
  final probes = <String>[];
  var checkScanner = false;

  for (var i = 0; i < args.length; i++) {
    final String arg = args[i];
    if (arg == '--scanner' ||
        arg == '--check-scanner' ||
        arg == '--mode=scanner') {
      checkScanner = true;
    } else if (arg.startsWith('--probe=')) {
      final String value = arg.substring('--probe='.length);
      if (value.isEmpty) {
        throw const FormatException('Missing repository name after --probe=.');
      }
      probes.add(value);
    } else if (arg == '--probe') {
      if (i + 1 >= args.length || args[i + 1].isEmpty) {
        throw const FormatException('Missing repository name after --probe.');
      }
      probes.add(args[++i]);
    } else if (arg.startsWith('-')) {
      throw FormatException('Unknown option: $arg');
    } else if (wsDir == null) {
      wsDir = arg;
    } else {
      repos.add(arg);
    }
  }

  if (wsDir == null || wsDir.isEmpty) {
    throw const FormatException('Missing workspace argument.');
  }
  if (repos.isEmpty && probes.isEmpty && !checkScanner) {
    throw const FormatException(
      'No repositories or --scanner specified to check.',
    );
  }

  return CheckConfig(
    workspaceDir: wsDir,
    reproducibleRepos: repos,
    probeRepos: probes,
    checkScanner: checkScanner,
  );
}

/// Verifies that reproducible repos are symlinks to the same cache entry,
/// that each cache entry's hash directory contains exactly one entry,
/// and that probe repos are real directories.
void verifyOutputBases({
  required String outputBase1,
  required String outputBase2,
  required List<String> reproducibleRepos,
  List<String> probeRepos = const [],
  String? repoContentsCache,
}) {
  final String ext1 = p.join(outputBase1, 'external');
  final String ext2 = p.join(outputBase2, 'external');

  for (final repo in reproducibleRepos) {
    _verifyCachedRepo(
      ext1: ext1,
      ext2: ext2,
      repo: repo,
      repoContentsCache: repoContentsCache,
    );
  }

  for (final probe in probeRepos) {
    _verifyProbeRepo(ext1: ext1, ext2: ext2, probe: probe);
  }
}

String _resolveLinkTarget(String linkPath) {
  final String raw = Link(linkPath).targetSync();
  return p.normalize(
    p.isAbsolute(raw) ? raw : p.join(p.dirname(linkPath), raw),
  );
}

void _verifyCachedRepo({
  required String ext1,
  required String ext2,
  required String repo,
  String? repoContentsCache,
}) {
  final String entry1 = p.join(ext1, repo);
  final String entry2 = p.join(ext2, repo);

  if (!FileSystemEntity.isLinkSync(entry1)) {
    throw CheckFailure(
      'Expected external/$repo in output base 1 to be a symlink to '
      'repo contents cache, but it is a directory or does not exist.',
    );
  }
  if (!FileSystemEntity.isLinkSync(entry2)) {
    throw CheckFailure(
      'Expected external/$repo in output base 2 to be a symlink to '
      'repo contents cache, but it is a directory or does not exist.',
    );
  }

  final String target1 = _resolveLinkTarget(entry1);
  final String target2 = _resolveLinkTarget(entry2);
  if (target1 != target2) {
    throw CheckFailure(
      'Symlinks for $repo point to different cache entries: '
      '$target1 vs $target2',
    );
  }

  final cacheDir = Directory(target1);
  if (!cacheDir.existsSync()) {
    throw CheckFailure('Cache entry target $target1 does not exist.');
  }

  if (repoContentsCache != null) {
    final String canonicalRcc = p.canonicalize(repoContentsCache);
    final String canonicalTarget = p.canonicalize(target1);
    if (!p.isWithin(canonicalRcc, canonicalTarget)) {
      throw CheckFailure(
        'Expected external/$repo symlink target $canonicalTarget to reside '
        'inside repo contents cache $canonicalRcc.',
      );
    }
  }

  final Directory hashDir = cacheDir.parent;
  if (!hashDir.existsSync()) {
    throw CheckFailure('Cache hash directory ${hashDir.path} does not exist.');
  }

  final List<Directory> entriesInHash = hashDir
      .listSync()
      .whereType<Directory>()
      .toList();
  if (entriesInHash.length != 1) {
    final String names = entriesInHash
        .map((Directory e) => p.basename(e.path))
        .join(', ');
    throw CheckFailure(
      'Expected contents/${p.basename(hashDir.path)}/ to hold 1 entry, '
      'but found ${entriesInHash.length}: $names',
    );
  }
}

void _verifyProbeRepo({
  required String ext1,
  required String ext2,
  required String probe,
}) {
  _verifyRealDirectory(p.join(ext1, probe), 'probe repo $probe', 1);
  _verifyRealDirectory(p.join(ext2, probe), 'probe repo $probe', 2);
}

void _verifyRealDirectory(String path, String label, int baseNumber) {
  if (FileSystemEntity.isLinkSync(path)) {
    throw CheckFailure(
      'Expected $label in output base $baseNumber to be a real directory, '
      'but it is a symlink to ${Link(path).targetSync()}',
    );
  }
  if (!Directory(path).existsSync()) {
    throw CheckFailure(
      'Expected $label in output base $baseNumber to exist as a directory.',
    );
  }
}

/// Verifies that the scanner snapshot executable has identical sha256 checksums
/// in both output bases.
///
/// When [requireRealDirectory] is true, also asserts that neither scanner
/// repository directory is a symlink into a repo contents cache.
String verifyScannerSha256({
  required String outputBase1,
  required String outputBase2,
  required String scannerRepo,
  bool requireRealDirectory = false,
}) {
  if (requireRealDirectory) {
    _verifyRealDirectory(
      p.join(outputBase1, 'external', scannerRepo),
      'scanner repo $scannerRepo',
      1,
    );
    _verifyRealDirectory(
      p.join(outputBase2, 'external', scannerRepo),
      'scanner repo $scannerRepo',
      2,
    );
  }

  final File file1 = _findScannerFile(outputBase1, scannerRepo);
  final File file2 = _findScannerFile(outputBase2, scannerRepo);

  final sha1 = sha256.convert(file1.readAsBytesSync()).toString();
  final sha2 = sha256.convert(file2.readAsBytesSync()).toString();

  if (sha1 != sha2) {
    throw CheckFailure(
      'Scanner binary SHA-256 mismatch between output bases: $sha1 vs $sha2',
    );
  }
  return sha1;
}

File _findScannerFile(String outputBase, String scannerRepo) {
  final String dir = p.join(outputBase, 'external', scannerRepo);
  final candidates = <String>[
    p.join(dir, 'scanner'),
    p.join(dir, 'scanner.exe'),
  ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) {
      return file;
    }
  }
  throw CheckFailure('Scanner binary not found under $dir');
}

/// Resolves a repository [name] against a Bzlmod apparent-to-canonical [mapping].
String resolveCanonicalRepo(String name, Map<String, Object?> mapping) {
  final String stripped = _stripRepoSigils(name);
  if (stripped.startsWith('+') || stripped.contains('++')) {
    return stripped;
  }

  final Object? direct = mapping[stripped];
  if (direct is String && direct.isNotEmpty) {
    return direct;
  }

  final String? spokeMatch = _resolveSharedHubSpoke(stripped, mapping);
  if (spokeMatch != null) {
    return spokeMatch;
  }

  if (stripped == 'dart_pub_scanner' ||
      (stripped.startsWith('dart_') && !stripped.startsWith('dart_pub_'))) {
    final String dartPrefix =
        _findExtensionPrefix(mapping, '+dart+') ?? '+dart+';
    return '$dartPrefix$stripped';
  }
  if (stripped.startsWith('dart_pub_')) {
    final String pubPrefix = _findExtensionPrefix(mapping, '+pub+') ?? '+pub+';
    return '$pubPrefix$stripped';
  }
  return stripped;
}

String _stripRepoSigils(String name) {
  if (name.startsWith('@@')) {
    return name.substring(2);
  }
  if (name.startsWith('@')) {
    return name.substring(1);
  }
  return name;
}

String? _resolveSharedHubSpoke(String stripped, Map<String, Object?> mapping) {
  final int sep = stripped.indexOf('__');
  if (sep <= 0) {
    return null;
  }
  final String hub = stripped.substring(0, sep);
  final String rest = stripped.substring(sep + 2);
  final Object? hubCanonical = mapping[hub];
  if (hubCanonical is! String || hubCanonical.isEmpty) {
    return null;
  }
  final Object? sharedSpoke = mapping['dart_pub__$rest'];
  if (sharedSpoke is String && sharedSpoke.isNotEmpty) {
    return sharedSpoke;
  }
  final int pubIdx = hubCanonical.indexOf('+pub+');
  if (pubIdx >= 0) {
    final String pubPrefix = hubCanonical.substring(0, pubIdx + '+pub+'.length);
    return '${pubPrefix}dart_pub__$rest';
  }
  return null;
}

String? _findExtensionPrefix(Map<String, Object?> mapping, String marker) {
  for (final Object? val in mapping.values) {
    if (val is String) {
      final int idx = val.indexOf(marker);
      if (idx >= 0) {
        return val.substring(0, idx + marker.length);
      }
    }
  }
  return null;
}

List<String> _scratchCandidateBases(
  String canonicalWs,
  Map<String, String> env,
) {
  return <String>[
    if (env['RUNNER_TEMP'] != null) env['RUNNER_TEMP']!,
    Directory.systemTemp.path,
    if (Platform.isWindows) ...<String>[
      if (env['TEMP'] != null) env['TEMP']!,
      if (env['TMP'] != null) env['TMP']!,
    ] else ...<String>['/tmp', '/var/tmp'],
    if (env['HOME'] != null) p.join(env['HOME']!, '.tmp'),
    if (env['HOME'] != null) env['HOME']!,
    p.dirname(canonicalWs),
  ];
}

Directory? _tryCandidateScratch(
  String candidate,
  String canonicalWs,
  String startDir,
) {
  if (candidate.isEmpty) {
    return null;
  }
  try {
    final String absoluteCandidate = p.isAbsolute(candidate)
        ? candidate
        : p.canonicalize(p.join(startDir, candidate));
    final String canonicalCandidate = p.canonicalize(absoluteCandidate);
    if (canonicalCandidate == canonicalWs ||
        p.isWithin(canonicalWs, canonicalCandidate)) {
      return null;
    }
    final baseDir = Directory(canonicalCandidate);
    if (!baseDir.existsSync()) {
      return null;
    }
    final Directory created = baseDir.createTempSync('rcc_check_');
    final String canonicalCreated = p.canonicalize(created.path);
    if (canonicalCreated != canonicalWs &&
        !p.isWithin(canonicalWs, canonicalCreated)) {
      return Directory(canonicalCreated);
    }
    created.deleteSync(recursive: true);
  } on FileSystemException {
    // Candidate directory cannot be created or is not writable; reject it.
  }
  return null;
}

/// Creates a temporary scratch directory guaranteed to reside outside [wsDir].
Directory createCheckScratchDir(
  String wsDir, {
  Map<String, String>? environment,
}) {
  final Map<String, String> env = environment ?? Platform.environment;
  final String canonicalWs = p.canonicalize(wsDir);
  final String startDir =
      env['BUILD_WORKING_DIRECTORY'] ?? Directory.current.path;

  for (final String candidate in _scratchCandidateBases(canonicalWs, env)) {
    final Directory? scratch = _tryCandidateScratch(
      candidate,
      canonicalWs,
      startDir,
    );
    if (scratch != null) {
      return scratch;
    }
  }

  throw CheckFailure(
    'Could not create a temporary scratch directory outside workspace: $wsDir',
  );
}
