/// Bazel execution log parsing, spawn filtering and dependency ordering.
library;

import 'dart:convert';

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
    if (commandArgs.isEmpty) return false;
    final cmd = commandArgs.first;
    return cmd.contains('test_runner') ||
        commandArgs.any((arg) => arg.contains('TestRunner')) ||
        declaredOutputs.any((out) => out.endsWith('/test.log'));
  }
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
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == '"') {
        inString = false;
      }
    } else {
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
}

/// Checks whether an output path belongs to an exec configuration.
bool isExecConfigPath(String path) {
  // Matches bazel-out/*-exec*/*
  final normalized = path.replaceAll(r'\', '/');
  return RegExp(r'^bazel-out/[^/]+-exec[^/]*/').hasMatch(normalized);
}

/// Parses a single spawn JSON map into a [SpawnRecord].
SpawnRecord? parseSpawnMap(Map<String, dynamic> map) {
  final args = <String>[];
  final rawArgs = map['commandArgs'];
  if (rawArgs is List) {
    for (final a in rawArgs) {
      if (a != null) args.add(a.toString());
    }
  }

  final env = <String, String>{};
  final rawEnv = map['environmentVariables'];
  if (rawEnv is List) {
    for (final e in rawEnv) {
      if (e is Map && e['name'] != null && e['value'] != null) {
        env[e['name'].toString()] = e['value'].toString();
      }
    }
  } else if (rawEnv is Map) {
    for (final entry in rawEnv.entries) {
      env[entry.key.toString()] = entry.value.toString();
    }
  }

  final inputs = <String>[];
  final rawInputs = map['inputs'];
  if (rawInputs is List) {
    for (final inp in rawInputs) {
      if (inp is String) {
        inputs.add(inp);
      } else if (inp is Map && inp['path'] != null) {
        inputs.add(inp['path'].toString());
      }
    }
  }

  final listed = <String>[];
  final rawListed = map['listedOutputs'];
  if (rawListed is List) {
    for (final out in rawListed) {
      if (out is String) {
        listed.add(out);
      } else if (out is Map && out['path'] != null) {
        listed.add(out['path'].toString());
      }
    }
  }

  final actual = <String>[];
  final rawActual = map['actualOutputs'];
  if (rawActual is List) {
    for (final out in rawActual) {
      if (out is String) {
        actual.add(out);
      } else if (out is Map && out['path'] != null) {
        actual.add(out['path'].toString());
      }
    }
  }

  final runner = (map['runner'] as String? ?? '').trim();
  final exitCode = map['exitCode'] as int?;
  final isCached =
      map['cachedLocally'] == true ||
      map['remoteCacheHit'] == true ||
      map['cacheHit'] == true;

  return SpawnRecord(
    commandArgs: args,
    environmentVariables: env,
    inputs: inputs,
    listedOutputs: listed,
    actualOutputs: actual,
    runner: runner,
    exitCode: exitCode,
    isCached: isCached,
  );
}

/// Parsed results of an execution log.
final class ParsedExecutionLog {
  /// Creates a parsed execution log container.
  const ParsedExecutionLog({
    required this.allSpawns,
    required this.chainSpawns,
    required this.workerSteps,
  });

  /// All parsed spawns in the log.
  final List<SpawnRecord> allSpawns;

  /// Selected non-exec, non-cached, exit-0 chain spawns.
  final List<SpawnRecord> chainSpawns;

  /// Count of persistent worker spawns.
  final int workerSteps;
}

/// Parses an entire execution log text and extracts candidate chain spawns.
ParsedExecutionLog parseExecutionLog(String text) {
  final allSpawns = <SpawnRecord>[];
  final chainSpawns = <SpawnRecord>[];
  var workerSteps = 0;

  for (final jsonStr in extractConcatenatedJsonObjects(text)) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map<String, dynamic>) continue;
      final record = parseSpawnMap(decoded);
      if (record == null) continue;

      allSpawns.add(record);
      if (record.isWorker) workerSteps++;

      // Non-zero exit code: exclude from chain
      if (record.exitCode != null && record.exitCode != 0) continue;
      // Cached spawns: exclude from chain
      if (record.isCached) continue;

      // Exec configuration check
      final declared = record.declaredOutputs;
      if (declared.isNotEmpty && declared.any(isExecConfigPath)) {
        continue;
      }

      chainSpawns.add(record);
    } catch (_) {
      // Ignore malformed JSON objects in log.
    }
  }

  return ParsedExecutionLog(
    allSpawns: allSpawns,
    chainSpawns: chainSpawns,
    workerSteps: workerSteps,
  );
}

/// Orders chain spawns by declared input/output dependencies.
List<SpawnRecord> orderChainSpawns(List<SpawnRecord> spawns) {
  final outputToProducer = <String, int>{};
  for (var i = 0; i < spawns.length; i++) {
    for (final out in spawns[i].declaredOutputs) {
      outputToProducer[out] = i;
    }
  }

  final adjacency = List.generate(spawns.length, (_) => <int>{});
  final inDegree = List.filled(spawns.length, 0);

  for (var i = 0; i < spawns.length; i++) {
    final current = spawns[i];
    for (final inp in current.inputs) {
      final producer = outputToProducer[inp];
      if (producer != null && producer != i) {
        if (adjacency[producer].add(i)) {
          inDegree[i]++;
        }
      }
    }
  }

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
    for (final out in spawn.declaredOutputs) {
      if (out.endsWith('.dill')) {
        verifyPaths.add(out);
      }
    }
  }
  return verifyPaths;
}
