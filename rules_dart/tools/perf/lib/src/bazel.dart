/// Bazel as the harness drives it: commands in one workspace, the numbers
/// Bazel reports about them, and what its execution log and profile say.
library;

import 'dart:convert';
import 'dart:io';

import 'proc.dart';

/// One Bazel workspace and the command that runs Bazel in it.
final class Bazel {
  /// Bazel run as [command] (a wrapper is fine) in [workspace], with [env]
  /// added to the environment of every command; an [outputBase] given here
  /// is not asked for.
  Bazel(
    this.command,
    this.workspace, {
    this.log,
    this.env = const {},
    String? outputBase,
  }) : _outputBase = outputBase;

  /// The Bazel executable and its startup options.
  final List<String> command;

  /// The workspace directory.
  final String workspace;

  /// Where every command's output is appended.
  final File? log;

  /// Variables added for every command. The client environment is part of
  /// a server's startup options (the Java of `JAVA_HOME`), so every command
  /// in a workspace gets the same.
  final Map<String, String> env;

  String? _outputBase;

  /// A [Cmd] for `bazel <args>` in the workspace.
  Cmd cmd(List<String> args) =>
      Cmd([...command, ...args], cwd: workspace, env: env);

  /// Runs `bazel <args>`.
  Future<Done> run(List<String> args, {void Function(int pid)? started}) =>
      runCmd(cmd(args), log: log, started: started);

  /// Runs `bazel <args>` and throws when it fails.
  Future<Done> must(List<String> args) async {
    final done = await run(args);
    if (!done.ok) {
      throw StateError(
        'bazel ${args.join(' ')} failed in $workspace (exit ${done.exitCode}):\n'
        '${done.tail()}',
      );
    }
    return done;
  }

  /// The output base (asks Bazel once).
  Future<String> outputBase() async =>
      _outputBase ??= (await must(['info', 'output_base'])).stdout.trim();

  /// Stops the server; errors are ignored.
  Future<void> shutdown() async {
    await run(['shutdown']);
  }
}

/// Bazel's own "Elapsed time" of a command, from its stderr, or null.
double? elapsedSeconds(String stderr) {
  final m = RegExp(r'Elapsed time: ([0-9.]+)s').allMatches(stderr);
  return m.isEmpty ? null : double.parse(m.last.group(1)!);
}

/// The counts in "Analyzed N targets (P packages loaded, C targets
/// configured, A aspect applications)", or null.
({int targets, int configured, int? aspects})? analyzedCounts(String stderr) {
  final m = RegExp(
    r'Analyzed (\d+) targets? \(\d+ packages? loaded, (\d+) targets? (?:and \d+ aspects? )?configured(?:, (\d+) aspect applications?)?',
  ).firstMatch(stderr);
  return m == null
      ? null
      : (
          targets: int.parse(m.group(1)!),
          configured: int.parse(m.group(2)!),
          aspects: m.group(3) == null ? null : int.parse(m.group(3)!),
        );
}

/// Splits concatenated JSON objects (Bazel's JSON execution log).
Iterable<Map<String, Object?>> jsonObjects(String text) sync* {
  var depth = 0;
  var start = -1;
  var inString = false;
  var escaped = false;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == 0x5c) {
        escaped = true;
      } else if (c == 0x22) {
        inString = false;
      }
      continue;
    }
    if (c == 0x22) {
      inString = true;
    } else if (c == 0x7b) {
      if (depth++ == 0) start = i;
    } else if (c == 0x7d && --depth == 0) {
      yield jsonDecode(text.substring(start, i + 1)) as Map<String, Object?>;
    }
  }
}

/// Actions that ran (not cache hits), counted by mnemonic, from a JSON
/// execution log; cache hits are counted under `<mnemonic> (cached)`.
Map<String, int> mnemonics(String execLogJson) {
  final counts = <String, int>{};
  for (final spawn in jsonObjects(execLogJson)) {
    final name = (spawn['mnemonic'] as String?) ?? '?';
    final key = spawn['cacheHit'] == true ? '$name (cached)' : name;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return Map.fromEntries(
    counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
}

/// Actions that ran (not cache hits) in a JSON execution log, counted by
/// their owner's label (`?` when the log names none) and mnemonic.
Map<({String owner, String mnemonic}), int> executedByOwner(
  String execLogJson,
) {
  final counts = <({String owner, String mnemonic}), int>{};
  for (final spawn in jsonObjects(execLogJson)) {
    if (spawn['cacheHit'] == true) continue;
    final key = (
      owner: (spawn['targetLabel'] as String?) ?? '?',
      mnemonic: (spawn['mnemonic'] as String?) ?? '?',
    );
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts;
}

/// Reads a JSON execution log file into [mnemonics]; an absent file gives an
/// empty map.
Map<String, int> mnemonicsOfFile(String path) {
  final f = File(path);
  return f.existsSync() ? mnemonics(f.readAsStringSync()) : const {};
}

/// The trace events of a Bazel JSON profile (gzipped or not).
List<Map<String, Object?>> profileEvents(String path) {
  final bytes = File(path).readAsBytesSync();
  final text = path.endsWith('.gz')
      ? utf8.decode(gzip.decode(bytes))
      : utf8.decode(bytes);
  final doc = jsonDecode(text);
  final events = doc is Map ? doc['traceEvents'] : doc;
  return [for (final e in events as List) (e as Map).cast<String, Object?>()];
}

/// Seconds of each build phase in a profile, by the phase marker's name.
Map<String, double> phaseSeconds(List<Map<String, Object?>> events) {
  final markers = [
    for (final e in events)
      if (e['cat'] == 'build phase marker')
        (name: e['name'] as String, ts: (e['ts'] as num).toDouble()),
  ]..sort((a, b) => a.ts.compareTo(b.ts));
  final end = events
      .map((e) => (e['ts'] as num? ?? 0) + (e['dur'] as num? ?? 0))
      .fold<num>(0, (a, b) => a > b ? a : b)
      .toDouble();
  return {
    for (var i = 0; i < markers.length; i++)
      markers[i].name:
          ((i + 1 < markers.length ? markers[i + 1].ts : end) - markers[i].ts) /
          1e6,
  };
}

/// Seconds spent evaluating module extensions whose name contains [needle].
double extensionSeconds(List<Map<String, Object?>> events, String needle) {
  var sum = 0.0;
  for (final e in events) {
    final name = e['name'] as String? ?? '';
    if (name.startsWith('evaluate module extension') && name.contains(needle)) {
      sum += (e['dur'] as num? ?? 0) / 1e6;
    }
  }
  return sum;
}
