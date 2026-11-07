/// Library for verifying repository contents cache symlinks and reproducibility.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:e2e_runner/bazel_env.dart';
import 'package:path/path.dart' as p;

/// Configuration for running repository contents cache checks across output bases.
class CheckConfig {
  /// Directory of the workspace under test.
  final String workspaceDir;

  /// Repositories expected to be reproducible and stored in the contents cache.
  final List<String> reproducibleRepos;

  /// Repositories expected to remain un-cached real directories (negative probe cases).
  final List<String> probeRepos;

  /// Whether to assert the scanner's snapshot is byte-identical across output bases.
  final bool checkScanner;

  CheckConfig({
    required this.workspaceDir,
    required this.reproducibleRepos,
    this.probeRepos = const [],
    this.checkScanner = false,
  });
}

/// Verifies that reproducible repos are symlinks to the same cache entry,
/// that each cache entry's hash directory contains exactly one entry,
/// and that probe repos are real directories.
void verifyOutputBases({
  required String outputBase1,
  required String outputBase2,
  required List<String> reproducibleRepos,
  List<String> probeRepos = const [],
}) {
  final ext1 = p.join(outputBase1, 'external');
  final ext2 = p.join(outputBase2, 'external');

  for (final repo in reproducibleRepos) {
    _verifyCachedRepo(ext1: ext1, ext2: ext2, repo: repo);
  }

  for (final probe in probeRepos) {
    _verifyProbeRepo(ext1: ext1, ext2: ext2, probe: probe);
  }
}

void _verifyCachedRepo({
  required String ext1,
  required String ext2,
  required String repo,
}) {
  final entry1 = p.join(ext1, repo);
  final entry2 = p.join(ext2, repo);

  if (!FileSystemEntity.isLinkSync(entry1)) {
    throw StateError(
      'Expected external/$repo in output base 1 to be a symlink to '
      'repo contents cache, but it is a directory or does not exist.',
    );
  }
  if (!FileSystemEntity.isLinkSync(entry2)) {
    throw StateError(
      'Expected external/$repo in output base 2 to be a symlink to '
      'repo contents cache, but it is a directory or does not exist.',
    );
  }

  final target1 = Link(entry1).targetSync();
  final target2 = Link(entry2).targetSync();
  if (target1 != target2) {
    throw StateError(
      'Symlinks for $repo point to different cache entries: '
      '$target1 vs $target2',
    );
  }

  final cacheDir = Directory(target1);
  if (!cacheDir.existsSync()) {
    throw StateError('Cache entry target $target1 does not exist.');
  }

  final hashDir = cacheDir.parent;
  if (!hashDir.existsSync()) {
    throw StateError('Cache hash directory ${hashDir.path} does not exist.');
  }

  final entriesInHash = hashDir.listSync().whereType<Directory>().toList();
  if (entriesInHash.length != 1) {
    final names = entriesInHash.map((e) => p.basename(e.path)).join(', ');
    throw StateError(
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
  final p1 = p.join(ext1, probe);
  final p2 = p.join(ext2, probe);

  if (FileSystemEntity.isLinkSync(p1)) {
    throw StateError(
      'Expected probe repo $probe in output base 1 to be a real directory, '
      'but it is a symlink to ${Link(p1).targetSync()}',
    );
  }
  if (!Directory(p1).existsSync()) {
    throw StateError(
      'Expected probe repo $probe in output base 1 to exist as a directory.',
    );
  }

  if (FileSystemEntity.isLinkSync(p2)) {
    throw StateError(
      'Expected probe repo $probe in output base 2 to be a real directory, '
      'but it is a symlink to ${Link(p2).targetSync()}',
    );
  }
  if (!Directory(p2).existsSync()) {
    throw StateError(
      'Expected probe repo $probe in output base 2 to exist as a directory.',
    );
  }
}

/// Verifies that the scanner snapshot executable has identical sha256 checksums
/// in both output bases.
String verifyScannerSha256({
  required String outputBase1,
  required String outputBase2,
  required String scannerRepo,
}) {
  final file1 = _findScannerFile(outputBase1, scannerRepo);
  final file2 = _findScannerFile(outputBase2, scannerRepo);

  final sha1 = sha256.convert(file1.readAsBytesSync()).toString();
  final sha2 = sha256.convert(file2.readAsBytesSync()).toString();

  if (sha1 != sha2) {
    throw StateError(
      'Scanner binary SHA-256 mismatch between output bases: $sha1 vs $sha2',
    );
  }
  return sha1;
}

File _findScannerFile(String outputBase, String scannerRepo) {
  final dir = p.join(outputBase, 'external', scannerRepo);
  final candidates = [p.join(dir, 'scanner'), p.join(dir, 'scanner.exe')];
  for (final path in candidates) {
    final f = File(path);
    if (f.existsSync()) return f;
  }
  throw StateError('Scanner binary not found under $dir');
}

/// Resolves a repository name against a Bzlmod apparent-to-canonical mapping.
String resolveCanonicalRepo(String name, Map<String, dynamic> mapping) {
  var stripped = name;
  if (stripped.startsWith('@@')) {
    stripped = stripped.substring(2);
  } else if (stripped.startsWith('@')) {
    stripped = stripped.substring(1);
  }

  if (stripped.startsWith('+') || stripped.contains('++')) {
    return stripped;
  }
  if (mapping.containsKey(stripped)) {
    return mapping[stripped] as String;
  }

  if (stripped.startsWith('ext_pub_deps__')) {
    stripped = 'dart_pub__${stripped.substring('ext_pub_deps__'.length)}';
  } else if (stripped.startsWith('pub_deps__')) {
    stripped = 'dart_pub__${stripped.substring('pub_deps__'.length)}';
  }

  var dartPrefix = '+dart+';
  for (final val in mapping.values) {
    if (val is String && val.contains('dart+dart_toolchains')) {
      final idx = val.indexOf('dart+dart_toolchains');
      dartPrefix = val.substring(0, idx + 'dart+'.length);
      break;
    }
  }

  var pubPrefix = '+pub+';
  for (final val in mapping.values) {
    if (val is String &&
        (val.contains('pub+ext_pub_deps') || val.contains('pub+pub_deps'))) {
      final idx = val.indexOf('pub+');
      pubPrefix = val.substring(0, idx + 'pub+'.length);
      break;
    }
  }

  if (stripped.startsWith('dart_') && !stripped.startsWith('dart_pub_')) {
    return '$dartPrefix$stripped';
  }
  if (stripped.startsWith('dart_pub_')) {
    return '$pubPrefix$stripped';
  }
  return stripped;
}

/// Resolves candidate base directories for scratch storage outside [canonicalWs].
List<String> _scratchCandidateBases(
  String canonicalWs,
  Map<String, String> env,
) {
  return [
    if (env['RUNNER_TEMP'] != null) env['RUNNER_TEMP']!,
    if (env['TEST_TMPDIR'] != null) env['TEST_TMPDIR']!,
    Directory.systemTemp.path,
    if (Platform.isWindows) ...[
      if (env['TEMP'] != null) env['TEMP']!,
      if (env['TMP'] != null) env['TMP']!,
    ] else ...[
      '/tmp',
      '/var/tmp',
    ],
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
  if (candidate.isEmpty) return null;
  try {
    final absoluteCandidate = p.isAbsolute(candidate)
        ? candidate
        : p.canonicalize(p.join(startDir, candidate));
    final canonicalCandidate = p.canonicalize(absoluteCandidate);
    if (canonicalCandidate == canonicalWs ||
        p.isWithin(canonicalWs, canonicalCandidate)) {
      return null;
    }
    final baseDir = Directory(canonicalCandidate);
    if (!baseDir.existsSync()) {
      return null;
    }
    final created = baseDir.createTempSync('rcc_check_');
    final canonicalCreated = p.canonicalize(created.path);
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
  final env = environment ?? Platform.environment;
  final canonicalWs = p.canonicalize(wsDir);
  final startDir = env['BUILD_WORKING_DIRECTORY'] ?? Directory.current.path;

  for (final candidate in _scratchCandidateBases(canonicalWs, env)) {
    final scratch = _tryCandidateScratch(candidate, canonicalWs, startDir);
    if (scratch != null) {
      return scratch;
    }
  }

  throw StateError(
    'Could not create a temporary scratch directory outside workspace: $wsDir',
  );
}

/// Runs repository contents cache verification with two fresh output bases.
void runCheck(CheckConfig config, {String? bazelExecutable}) {
  final bazel =
      bazelExecutable ??
      resolveExecutableInPath('bazel', innerEnvironment(Platform.environment));
  final env = {
    ...innerEnvironment(Platform.environment),
    'GIT_CONFIG_NOSYSTEM': '1',
  };

  final startDir =
      Platform.environment['BUILD_WORKING_DIRECTORY'] ?? Directory.current.path;
  final wsDir = p.canonicalize(
    p.isAbsolute(config.workspaceDir)
        ? config.workspaceDir
        : p.join(startDir, config.workspaceDir),
  );

  final tempDir = createCheckScratchDir(wsDir);
  final tempPath = p.canonicalize(tempDir.path);
  final ob1 = p.join(tempPath, 'ob1');
  final ob2 = p.join(tempPath, 'ob2');
  final rcc = p.join(tempPath, 'rcc');

  Directory(ob1).createSync(recursive: true);
  Directory(ob2).createSync(recursive: true);
  Directory(rcc).createSync(recursive: true);

  final paths = _CheckPaths(wsDir: wsDir, ob1: ob1, ob2: ob2, rcc: rcc);

  try {
    _executeCheck(bazel: bazel, env: env, paths: paths, config: config);
  } finally {
    _shutdownServer(bazel, ob1, wsDir, env);
    _shutdownServer(bazel, ob2, wsDir, env);
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup of temporary test directory.
    }
  }
}

final class _CheckPaths {
  const _CheckPaths({
    required this.wsDir,
    required this.ob1,
    required this.ob2,
    required this.rcc,
  });

  final String wsDir;
  final String ob1;
  final String ob2;
  final String rcc;
}

Map<String, dynamic> _dumpRepoMapping(
  String bazel,
  String wsDir,
  String outputBase,
  Map<String, String> env,
) {
  final mappingResult = Process.runSync(
    bazel,
    [
      '--max_idle_secs=60',
      '--output_base=$outputBase',
      'mod',
      'dump_repo_mapping',
      '',
    ],
    workingDirectory: wsDir,
    environment: env,
  );
  if (mappingResult.exitCode != 0) {
    throw StateError('mod dump_repo_mapping failed: ${mappingResult.stderr}');
  }
  return jsonDecode(mappingResult.stdout as String) as Map<String, dynamic>;
}

void _executeCheck({
  required String bazel,
  required Map<String, String> env,
  required _CheckPaths paths,
  required CheckConfig config,
}) {
  final mapping = _dumpRepoMapping(bazel, paths.wsDir, paths.ob1, env);

  final canonicalReproducible = config.reproducibleRepos
      .map((r) => resolveCanonicalRepo(r, mapping))
      .toList();
  final canonicalProbes = config.probeRepos
      .map((r) => resolveCanonicalRepo(r, mapping))
      .toList();

  var scannerCanonical = '';
  if (config.checkScanner ||
      canonicalReproducible.any((r) => r.contains('scanner'))) {
    scannerCanonical = resolveCanonicalRepo('dart_pub_scanner', mapping);
  }

  final allReposToFetch = {
    ...canonicalReproducible,
    ...canonicalProbes,
    if (scannerCanonical.isNotEmpty) scannerCanonical,
  }.toList();

  _fetchInOutputBase(
    bazel: bazel,
    env: env,
    wsDir: paths.wsDir,
    outputBase: paths.ob1,
    rcc: paths.rcc,
    repos: allReposToFetch,
  );
  _shutdownServer(bazel, paths.ob1, paths.wsDir, env);

  _fetchInOutputBase(
    bazel: bazel,
    env: env,
    wsDir: paths.wsDir,
    outputBase: paths.ob2,
    rcc: paths.rcc,
    repos: allReposToFetch,
  );
  _shutdownServer(bazel, paths.ob2, paths.wsDir, env);

  if (canonicalReproducible.isNotEmpty || canonicalProbes.isNotEmpty) {
    verifyOutputBases(
      outputBase1: paths.ob1,
      outputBase2: paths.ob2,
      reproducibleRepos: canonicalReproducible,
      probeRepos: canonicalProbes,
    );
  }

  if (scannerCanonical.isNotEmpty) {
    final sha = verifyScannerSha256(
      outputBase1: paths.ob1,
      outputBase2: paths.ob2,
      scannerRepo: scannerCanonical,
    );
    stdout.writeln(
      'PASS: Scanner SHA-256 byte-identical across output bases ($sha)',
    );
  }

  stdout.writeln(
    'PASS: Verified ${canonicalReproducible.length} cached repo(s) '
    'and ${canonicalProbes.length} probe repo(s).',
  );
}

void _fetchInOutputBase({
  required String bazel,
  required Map<String, String> env,
  required String wsDir,
  required String outputBase,
  required String rcc,
  required List<String> repos,
}) {
  final args = [
    '--max_idle_secs=60',
    '--output_base=$outputBase',
    'fetch',
    '--repo_contents_cache=$rcc',
    for (final repo in repos) '--repo=@@$repo',
  ];
  final result = Process.runSync(
    bazel,
    args,
    workingDirectory: wsDir,
    environment: env,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'bazel fetch failed (exit ${result.exitCode}):\n${result.stderr}\n${result.stdout}',
    );
  }
}

void _shutdownServer(
  String bazel,
  String outputBase,
  String wsDir,
  Map<String, String> env,
) {
  try {
    Process.runSync(
      bazel,
      ['--max_idle_secs=60', '--output_base=$outputBase', 'shutdown'],
      workingDirectory: wsDir,
      environment: env,
    );
  } on ProcessException {
    // Best-effort shutdown.
  }
}
