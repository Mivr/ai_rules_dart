/// Bazel execution log parsing, spawn filtering and dependency ordering.
library;

import 'dart:convert';
import 'dart:io';

/// Normalizes a workspace-relative path to forward slashes.
String _normalizePath(String path) {
  var normalized = path.trim().replaceAll(r'\', '/');
  while (normalized.startsWith('./')) {
    normalized = normalized.substring(2);
  }
  if (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

bool _pathMatchesOrContained(String candidate, String target) {
  return candidate == target ||
      candidate.startsWith('$target/') ||
      target.startsWith('$candidate/');
}

/// A parsed Bazel spawn entry from the execution log.
final class SpawnRecord {
  /// Creates a spawn record.
  const SpawnRecord({
    required this.commandArgs,
    required this.environmentVariables,
    required this.inputs,
    required this.listedOutputs,
    required this.actualOutputs,
    required this.runner,
    this.mnemonic = '',
    required this.exitCode,
    required this.isCached,
  });

  /// Command argv.
  final List<String> commandArgs;

  /// Environment variables for this command.
  final Map<String, String> environmentVariables;

  /// Input paths.
  final List<String> inputs;

  /// Declared listed output paths.
  final List<String> listedOutputs;

  /// Actual output paths.
  final List<String> actualOutputs;

  /// Runner name (e.g. "worker", "linux-sandbox", "local").
  final String runner;

  /// Action mnemonic (e.g. "DartKernel", "DartCompile", "TestRunner").
  final String mnemonic;

  /// Exit code (null or 0 indicates success).
  final int? exitCode;

  /// Whether this spawn hit a cache.
  final bool isCached;

  /// Combined declared outputs from listedOutputs and actualOutputs.
  Set<String> get declaredOutputs => {...listedOutputs, ...actualOutputs};

  /// Whether the runner is a persistent worker.
  bool get isWorker => runner.toLowerCase().contains('worker');

  /// Whether this spawn represents the `TestRunner` action.
  bool get isTestRunner {
    if (mnemonic == 'TestRunner') return true;
    if (declaredOutputs.any(
      (out) => out == 'test.log' || out.endsWith('/test.log'),
    )) {
      return true;
    }
    if (commandArgs.isEmpty) return false;
    final cmd = commandArgs.first;
    return cmd.contains('test_runner') ||
        cmd.contains('test-setup') ||
        commandArgs.any((arg) => arg.contains('TestRunner'));
  }
}

(bool, bool) _nextStringState(String char, {required bool escaped}) {
  if (escaped) return (true, false);
  if (char == r'\') return (true, true);
  if (char == '"') return (false, false);
  return (true, false);
}

/// Scans concatenated top-level JSON objects from text.
Iterable<String> extractConcatenatedJsonObjects(String text) sync* {
  var depth = 0;
  var inString = false;
  var escaped = false;
  var startIndex = -1;

  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (inString) {
      (inString, escaped) = _nextStringState(char, escaped: escaped);
      continue;
    }
    if (char == '"') {
      inString = true;
    } else if (char == '{') {
      if (depth == 0) startIndex = i;
      depth++;
    } else if (char == '}') {
      depth--;
      if (depth == 0 && startIndex != -1) {
        yield text.substring(startIndex, i + 1);
        startIndex = -1;
      }
    }
  }
}

/// Checks whether an output path belongs to an exec configuration.
bool isExecConfigPath(String path) {
  final normalized = _normalizePath(path);
  return RegExp(r'^bazel-out/[^/]+-exec[^/]*/').hasMatch(normalized);
}

List<String> _parseStringList(dynamic raw) {
  final result = <String>[];
  if (raw is List) {
    for (final item in raw) {
      if (item != null) result.add(item.toString());
    }
  }
  return result;
}

Map<String, String> _parseEnvMap(dynamic raw) {
  final env = <String, String>{};
  if (raw is List) {
    for (final item in raw) {
      if (item is Map && item['name'] != null && item['value'] != null) {
        env[item['name'].toString()] = item['value'].toString();
      }
    }
  } else if (raw is Map) {
    for (final entry in raw.entries) {
      env[entry.key.toString()] = entry.value.toString();
    }
  }
  return env;
}

List<String> _parsePathList(dynamic raw) {
  final paths = <String>[];
  if (raw is List) {
    for (final item in raw) {
      if (item is String) {
        final norm = _normalizePath(item);
        if (norm.isNotEmpty) paths.add(norm);
      } else if (item is Map && item['path'] != null) {
        final norm = _normalizePath(item['path'].toString());
        if (norm.isNotEmpty) paths.add(norm);
      }
    }
  }
  return paths;
}

/// Parses a single spawn JSON map into a [SpawnRecord].
SpawnRecord? parseSpawnMap(Map<String, dynamic> map) {
  final status = (map['status'] as String? ?? '').trim();
  var exitCode = (map['exitCode'] as num?)?.toInt();
  if (exitCode == null && status.isNotEmpty && status != 'SUCCESS') {
    exitCode = 1;
  }
  return SpawnRecord(
    commandArgs: _parseStringList(map['commandArgs']),
    environmentVariables: _parseEnvMap(map['environmentVariables']),
    inputs: _parsePathList(map['inputs']),
    listedOutputs: _parsePathList(map['listedOutputs']),
    actualOutputs: _parsePathList(map['actualOutputs']),
    runner: (map['runner'] as String? ?? '').trim(),
    mnemonic: (map['mnemonic'] as String? ?? '').trim(),
    exitCode: exitCode,
    isCached:
        map['cachedLocally'] == true ||
        map['remoteCacheHit'] == true ||
        map['cacheHit'] == true,
  );
}

/// Parsed results of an execution log.
final class ParsedExecutionLog {
  /// Creates a parsed execution log container.
  const ParsedExecutionLog({
    required this.allSpawns,
    required this.chainSpawns,
    required this.workerSteps,
    this.blockedOutputs = const {},
  });

  /// All parsed spawns in the log.
  final List<SpawnRecord> allSpawns;

  /// Selected non-exec, non-cached, exit-0 chain spawns.
  final List<SpawnRecord> chainSpawns;

  /// Count of persistent worker spawns in the chain.
  final int workerSteps;

  /// Declared outputs of failed spawns in the log.
  final Set<String> blockedOutputs;
}

/// Parses an entire execution log text and extracts candidate chain spawns.
ParsedExecutionLog parseExecutionLog(String text) {
  final allSpawns = <SpawnRecord>[];
  final chainSpawns = <SpawnRecord>[];
  final blockedOutputs = <String>{};
  var workerSteps = 0;

  for (final jsonStr in extractConcatenatedJsonObjects(text)) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map<String, dynamic>) continue;
      final record = parseSpawnMap(decoded);
      if (record == null) continue;

      allSpawns.add(record);
      final declared = record.declaredOutputs;

      if (record.exitCode != null && record.exitCode != 0) {
        blockedOutputs.addAll(declared);
        continue;
      }
      if (record.isCached) continue;
      if (declared.isNotEmpty && declared.any(isExecConfigPath)) continue;

      if (record.isWorker) workerSteps++;
      chainSpawns.add(record);
    } on FormatException catch (e) {
      stderr.writeln('Malformed JSON object in execution log: $e');
    }
  }

  return ParsedExecutionLog(
    allSpawns: allSpawns,
    chainSpawns: chainSpawns,
    workerSteps: workerSteps,
    blockedOutputs: blockedOutputs,
  );
}

final RegExp _runfilesInputPattern = RegExp(
  r'^(bazel-out/[^/]+/bin/).+?\.runfiles/([^/]+)/(.+)$',
);

Iterable<String> _expandInputCandidates(String normInp) sync* {
  yield normInp;
  final match = _runfilesInputPattern.firstMatch(normInp);
  if (match != null) {
    final binPrefix = match.group(1)!;
    final repo = match.group(2)!;
    final rel = match.group(3)!;
    yield '$binPrefix$rel';
    if (repo != '_main') {
      yield '${binPrefix}external/$repo/$rel';
    }
  }
}

void _validateNoBlockedInputs(
  List<SpawnRecord> spawns,
  Set<String> blockedOutputs,
) {
  final allBlocked = <String>{...blockedOutputs.map(_normalizePath)};
  for (final spawn in spawns) {
    if (spawn.exitCode != null && spawn.exitCode != 0) {
      allBlocked.addAll(spawn.declaredOutputs.map(_normalizePath));
      throw StateError(
        'Cannot order failed spawn with exitCode ${spawn.exitCode}',
      );
    }
  }
  if (allBlocked.isEmpty) return;

  for (final spawn in spawns) {
    for (final inp in spawn.inputs) {
      for (final candidate in _expandInputCandidates(_normalizePath(inp))) {
        for (final blocked in allBlocked) {
          if (_pathMatchesOrContained(candidate, blocked)) {
            throw StateError(
              'Spawn input $candidate is blocked by failed output',
            );
          }
        }
      }
    }
  }
}

Iterable<int> _findInputProducers(
  String inp,
  Map<String, int> exactProducer,
  List<(String, int)> allOutputs,
) sync* {
  for (final candidate in _expandInputCandidates(inp)) {
    final exact = exactProducer[candidate];
    if (exact != null) {
      yield exact;
      continue;
    }
    for (final (out, prodIdx) in allOutputs) {
      if (_pathMatchesOrContained(candidate, out)) {
        yield prodIdx;
      }
    }
  }
}

(List<Set<int>>, List<int>) _buildDependencyGraph(List<SpawnRecord> spawns) {
  final exactProducer = <String, int>{};
  final allOutputs = <(String, int)>[];
  for (var i = 0; i < spawns.length; i++) {
    for (final rawOut in spawns[i].declaredOutputs) {
      final out = _normalizePath(rawOut);
      exactProducer[out] = i;
      allOutputs.add((out, i));
    }
  }

  final adjacency = List.generate(spawns.length, (_) => <int>{});
  final inDegree = List.filled(spawns.length, 0);

  for (var i = 0; i < spawns.length; i++) {
    for (final rawInp in spawns[i].inputs) {
      final inp = _normalizePath(rawInp);
      for (final prodIdx in _findInputProducers(
        inp,
        exactProducer,
        allOutputs,
      )) {
        if (prodIdx == i) {
          throw StateError('Self-dependency in spawn $i on $inp');
        }
        if (adjacency[prodIdx].add(i)) inDegree[i]++;
      }
    }
  }
  return (adjacency, inDegree);
}

/// Orders chain spawns by declared input/output dependencies.
List<SpawnRecord> orderChainSpawns(
  List<SpawnRecord> spawns, {
  Set<String> blockedOutputs = const {},
}) {
  _validateNoBlockedInputs(spawns, blockedOutputs);
  final (adjacency, inDegree) = _buildDependencyGraph(spawns);

  final queue = <int>[];
  for (var i = 0; i < spawns.length; i++) {
    if (inDegree[i] == 0) queue.add(i);
  }

  final ordered = <SpawnRecord>[];
  while (queue.isNotEmpty) {
    final idx = queue.removeAt(0);
    ordered.add(spawns[idx]);
    for (final succ in adjacency[idx]) {
      inDegree[succ]--;
      if (inDegree[succ] == 0) {
        queue.add(succ);
      }
    }
  }

  if (ordered.length != spawns.length) {
    throw StateError(
      'Blocked input or circular dependency detected in chain spawns',
    );
  }

  return ordered;
}

/// Determines the verification paths for `dart-test-leaf`.
Set<String> selectLeafTestVerifyPaths(List<SpawnRecord> chainSpawns) {
  final verifyPaths = <String>{};
  for (final spawn in chainSpawns) {
    if (spawn.isTestRunner) continue;
    for (final rawOut in spawn.declaredOutputs) {
      final out = _normalizePath(rawOut);
      if (out.endsWith('/test.log') ||
          out.endsWith('/test.xml') ||
          out.endsWith('/test.cache_status') ||
          out.contains('/testlogs/')) {
        continue;
      }
      verifyPaths.add(out);
    }
  }
  return verifyPaths;
}
