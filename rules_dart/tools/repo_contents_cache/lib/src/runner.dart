/// Bazel execution runner for repository contents cache verification.
library;

import 'dart:convert';
import 'dart:io';

import 'package:e2e_runner/bazel_env.dart';
import 'package:path/path.dart' as p;
import 'package:repo_contents_cache/src/verifier.dart';

final RegExp _relevantExtensionPrefix = RegExp(
  r'^(\+|ai_rules_dart\+[^+]*\+\+)[^+]+\+',
);

/// Runs repository contents cache verification with fresh output bases.
void runCheck(CheckConfig config, {String? bazelExecutable}) {
  final Map<String, String> cleanedEnv = innerEnvironment(Platform.environment);
  final String bazel =
      bazelExecutable ?? resolveExecutableInPath('bazel', cleanedEnv);
  final String startDir =
      Platform.environment['BUILD_WORKING_DIRECTORY'] ?? Directory.current.path;
  final String wsDir = p.canonicalize(
    p.isAbsolute(config.workspaceDir)
        ? config.workspaceDir
        : p.join(startDir, config.workspaceDir),
  );
  final Map<String, String> env = _buildCheckEnvironment(
    cleanedEnv,
    wsDir: wsDir,
    startDir: startDir,
  );

  final Directory tempDir = createCheckScratchDir(wsDir);
  final String tempPath = p.canonicalize(tempDir.path);
  final runEnv = _RunEnv(
    bazel: bazel,
    wsDir: wsDir,
    tempPath: tempPath,
    contentsDir: p.join(tempPath, 'contents'),
    env: env,
  );

  try {
    _executeCheck(runEnv, config);
  } finally {
    for (final name in const <String>['ob1', 'ob2', 'scan1', 'scan2']) {
      final String ob = p.join(tempPath, name);
      if (Directory(ob).existsSync()) {
        _shutdownServer(runEnv, ob);
      }
    }
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup of temporary test directory.
    }
  }
}

Map<String, String> _buildCheckEnvironment(
  Map<String, String> baseEnv, {
  required String wsDir,
  required String startDir,
}) {
  final env = <String, String>{...baseEnv, 'GIT_CONFIG_NOSYSTEM': '1'};
  if (!env.containsKey('USE_BAZEL_VERSION') &&
      !File(p.join(wsDir, '.bazelversion')).existsSync()) {
    final startVersionFile = File(p.join(startDir, '.bazelversion'));
    if (startVersionFile.existsSync()) {
      final String version = startVersionFile.readAsStringSync().trim();
      if (version.isNotEmpty) {
        env['USE_BAZEL_VERSION'] = version;
      }
    }
  }
  return env;
}

final class _RunEnv {
  const new({
    required this.bazel,
    required this.wsDir,
    required this.tempPath,
    required this.contentsDir,
    required this.env,
  });

  final String bazel;
  final String wsDir;
  final String tempPath;
  final String contentsDir;
  final Map<String, String> env;
}

void _executeCheck(_RunEnv runEnv, CheckConfig config) {
  final bool hasRepoChecks =
      config.reproducibleRepos.isNotEmpty || config.probeRepos.isNotEmpty;
  final String ob1 = p.join(runEnv.tempPath, 'ob1');
  final String ob2 = p.join(runEnv.tempPath, 'ob2');
  final String scan1 = p.join(runEnv.tempPath, 'scan1');
  final String scan2 = p.join(runEnv.tempPath, 'scan2');

  if (hasRepoChecks) {
    Directory(ob1).createSync(recursive: true);
    Directory(ob2).createSync(recursive: true);
    Directory(runEnv.contentsDir).createSync(recursive: true);
  }
  if (config.checkScanner) {
    Directory(scan1).createSync(recursive: true);
    Directory(scan2).createSync(recursive: true);
  }

  final mappingOb = hasRepoChecks ? ob1 : scan1;
  final String mappingRcc = hasRepoChecks ? runEnv.contentsDir : '';
  final Map<String, String> mapping = _dumpMergedRepoMapping(
    runEnv,
    outputBase: mappingOb,
    rcc: mappingRcc,
  );

  if (hasRepoChecks) {
    _runCachedRepoCheck(
      runEnv,
      config: config,
      mapping: mapping,
      ob1: ob1,
      ob2: ob2,
    );
  }

  if (config.checkScanner) {
    _runScannerDeterminismCheck(
      runEnv,
      mapping: mapping,
      scan1: scan1,
      scan2: scan2,
    );
  }
}

void _runCachedRepoCheck(
  _RunEnv runEnv, {
  required CheckConfig config,
  required Map<String, String> mapping,
  required String ob1,
  required String ob2,
}) {
  final List<String> canonicalReproducible = config.reproducibleRepos
      .map((String r) => resolveCanonicalRepo(r, mapping))
      .toList();
  final List<String> canonicalProbes = config.probeRepos
      .map((String r) => resolveCanonicalRepo(r, mapping))
      .toList();
  final List<String> reposToFetch = <String>{
    ...canonicalReproducible,
    ...canonicalProbes,
  }.toList();

  _fetchInOutputBase(
    runEnv,
    outputBase: ob1,
    rcc: runEnv.contentsDir,
    repos: reposToFetch,
  );
  _shutdownServer(runEnv, ob1);

  _fetchInOutputBase(
    runEnv,
    outputBase: ob2,
    rcc: runEnv.contentsDir,
    repos: reposToFetch,
  );
  _shutdownServer(runEnv, ob2);

  verifyOutputBases(
    outputBase1: ob1,
    outputBase2: ob2,
    reproducibleRepos: canonicalReproducible,
    probeRepos: canonicalProbes,
    repoContentsCache: runEnv.contentsDir,
  );
  stdout.writeln(
    'PASS: Verified ${canonicalReproducible.length} cached repo(s) '
    'and ${canonicalProbes.length} probe repo(s).',
  );
}

void _runScannerDeterminismCheck(
  _RunEnv runEnv, {
  required Map<String, String> mapping,
  required String scan1,
  required String scan2,
}) {
  final String scannerCanonical = resolveCanonicalRepo(
    'dart_pub_scanner',
    mapping,
  );

  _fetchInOutputBase(
    runEnv,
    outputBase: scan1,
    rcc: '',
    repos: <String>[scannerCanonical],
  );
  _shutdownServer(runEnv, scan1);

  _fetchInOutputBase(
    runEnv,
    outputBase: scan2,
    rcc: '',
    repos: <String>[scannerCanonical],
  );
  _shutdownServer(runEnv, scan2);

  final String sha = verifyScannerSha256(
    outputBase1: scan1,
    outputBase2: scan2,
    scannerRepo: scannerCanonical,
    requireRealDirectory: true,
  );
  stdout.writeln(
    'PASS: Scanner SHA-256 byte-identical across output bases ($sha)',
  );
}

Map<String, String> _dumpMergedRepoMapping(
  _RunEnv runEnv, {
  required String outputBase,
  required String rcc,
}) {
  final Map<String, String> rootMap = _dumpRepoMappingCall(
    runEnv,
    outputBase: outputBase,
    rcc: rcc,
    canonicalRepos: const <String>[''],
  );

  final String? rulesDartModule =
      rootMap['rules_dart'] ?? rootMap['ai_rules_dart'];
  final Map<String, String> rulesDartMap =
      (rulesDartModule != null && rulesDartModule.isNotEmpty)
      ? _dumpRepoMappingCall(
          runEnv,
          outputBase: outputBase,
          rcc: rcc,
          canonicalRepos: <String>[rulesDartModule],
        )
      : const <String, String>{};

  final List<String> extensionReps = _collectExtensionRepresentatives(
    <Iterable<String>>[rootMap.values, rulesDartMap.values],
  );
  final Map<String, String> extMap = extensionReps.isEmpty
      ? const <String, String>{}
      : _dumpRepoMappingCall(
          runEnv,
          outputBase: outputBase,
          rcc: rcc,
          canonicalRepos: extensionReps,
        );

  return <String, String>{...rulesDartMap, ...extMap, ...rootMap};
}

List<String> _collectExtensionRepresentatives(
  List<Iterable<String>> valueGroups,
) {
  final seenPrefixes = <String>{};
  final reps = <String>[];
  for (final group in valueGroups) {
    for (final value in group) {
      final RegExpMatch? match = _relevantExtensionPrefix.firstMatch(value);
      if (match != null && seenPrefixes.add(match.group(0)!)) {
        reps.add(value);
      }
    }
  }
  return reps;
}

Map<String, String> _dumpRepoMappingCall(
  _RunEnv runEnv, {
  required String outputBase,
  required String rcc,
  required List<String> canonicalRepos,
}) {
  final ProcessResult result = Process.runSync(
    runEnv.bazel,
    <String>[
      '--max_idle_secs=60',
      '--output_base=$outputBase',
      'mod',
      'dump_repo_mapping',
      '--repo_contents_cache=$rcc',
      ...canonicalRepos,
    ],
    workingDirectory: runEnv.wsDir,
    environment: runEnv.env,
  );
  if (result.exitCode != 0) {
    throw CheckFailure('mod dump_repo_mapping failed: ${result.stderr}');
  }

  final merged = <String, String>{};
  for (final String line in LineSplitter.split(result.stdout.toString())) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    final Object? decoded = jsonDecode(trimmed);
    if (decoded is Map<String, Object?>) {
      decoded.forEach((String key, Object? val) {
        if (val is String && !merged.containsKey(key)) {
          merged[key] = val;
        }
      });
    }
  }
  return merged;
}

void _fetchInOutputBase(
  _RunEnv runEnv, {
  required String outputBase,
  required String rcc,
  required List<String> repos,
}) {
  final args = <String>[
    '--max_idle_secs=60',
    '--output_base=$outputBase',
    'fetch',
    '--repo_contents_cache=$rcc',
    for (final String repo in repos) '--repo=@@$repo',
  ];
  final ProcessResult result = Process.runSync(
    runEnv.bazel,
    args,
    workingDirectory: runEnv.wsDir,
    environment: runEnv.env,
  );
  if (result.exitCode != 0) {
    throw CheckFailure(
      'bazel fetch failed (exit ${result.exitCode}):\n'
      '${result.stderr}\n${result.stdout}',
    );
  }
}

void _shutdownServer(_RunEnv runEnv, String outputBase) {
  try {
    Process.runSync(
      runEnv.bazel,
      <String>['--max_idle_secs=60', '--output_base=$outputBase', 'shutdown'],
      workingDirectory: runEnv.wsDir,
      environment: runEnv.env,
    );
  } on ProcessException {
    // Best-effort shutdown when server cannot be invoked.
  }
}
