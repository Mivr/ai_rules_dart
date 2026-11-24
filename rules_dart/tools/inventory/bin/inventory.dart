/// Counts production and test lines per subsystem.
///
///     bazel run //inventory:inventory -- [--ledger=FILE] [--root=DIR]
///
/// Prints a table and, with `--ledger`, appends the same numbers as one JSON
/// line. The subsystems are the paths in `rules_dart/tools/inventory/subsystems.json`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:inventory/cli.dart';
import 'package:inventory/source_tree.dart';
import 'package:inventory/subsystems.dart';

void main(List<String> args) {
  try {
    final flags = Flags.parse(args, {'ledger', 'root', 'subsystems'});
    final String root = repositoryRoot(flags);
    final table = SubsystemTable.parse(
      File(flags.value('subsystems') ?? '$root/$dataDir/subsystems.json')
          .readAsStringSync(),
    );
    final Map<String, Count> counts = countSubsystems(
      SourceTree.onDisk(root),
      table,
    );
    stdout.write(_table(counts));
    final String? ledger = flags.value('ledger');
    if (ledger != null && ledger.isNotEmpty) {
      final Map<String, Object?> row = ledgerRow(
        counts: counts,
        date: DateTime.now().toUtc().toIso8601String(),
        commit: _git(root, ['rev-parse', 'HEAD']),
        branch: _git(root, ['rev-parse', '--abbrev-ref', 'HEAD']),
      );
      File(ledger)
          .writeAsStringSync('${jsonEncode(row)}\n', mode: FileMode.append);
      stdout.writeln('appended one row to $ledger');
    }
  } on FormatException catch (e) {
    stderr.writeln('inventory: ${e.message}');
    exit(2);
  }
}

String _table(Map<String, Count> counts) {
  final int width = counts.keys.fold(0, (w, k) => k.length > w ? k.length : w);
  final out = StringBuffer(
    '${'subsystem'.padRight(width)}  ${'production'.padLeft(10)}  ${'test'.padLeft(10)}\n',
  );
  var production = 0;
  var test = 0;
  for (final MapEntry<String, Count> e in counts.entries) {
    production += e.value.production;
    test += e.value.test;
    out.writeln(
      '${e.key.padRight(width)}  ${'${e.value.production}'.padLeft(10)}  ${'${e.value.test}'.padLeft(10)}',
    );
  }
  out.writeln(
    '${'total'.padRight(width)}  ${'$production'.padLeft(10)}  ${'$test'.padLeft(10)}',
  );
  return out.toString();
}

String? _git(String root, List<String> args) {
  final ProcessResult result = Process.runSync(
    'git',
    ['-C', root, ...args],
    environment: Platform.environment,
    includeParentEnvironment: false,
  );
  return result.exitCode == 0 ? (result.stdout as String).trim() : null;
}
