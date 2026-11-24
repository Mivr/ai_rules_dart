/// Checks the rules that would otherwise need a test that reads the
/// repository as text.
///
///     bazel run //inventory:lint -- [--update-debt] [--root=DIR]
///
/// Exits 1 on a violation that `debt.json` does not list, printing
/// `file:line: [rule] message`. Debt entries that no longer match anything
/// are reported so the list shrinks. `--update-debt` rewrites `debt.json` to
/// exactly today's violations.
library;

import 'dart:io';

import 'package:inventory/cli.dart';
import 'package:inventory/debt.dart';
import 'package:inventory/finding.dart';
import 'package:inventory/lint.dart';
import 'package:inventory/rules/file_length.dart';
import 'package:inventory/source_tree.dart';
import 'package:inventory/subsystems.dart';

void main(List<String> args) {
  try {
    final flags = Flags.parse(args, {
      'debt',
      'root',
      'subsystems',
      'update-debt',
    });
    final String root = repositoryRoot(flags);
    final table = SubsystemTable.parse(
      File(flags.value('subsystems') ?? '$root/$dataDir/subsystems.json')
          .readAsStringSync(),
    );
    final debtFile = File(flags.value('debt') ?? '$root/$dataDir/debt.json');
    final LintResult result = runLint(SourceTree.onDisk(root), table);
    if (flags.has('update-debt')) {
      _updateDebt(debtFile, result.findings);
      return;
    }
    exit(_report(result, parseDebt(debtFile.readAsStringSync())));
  } on FormatException catch (e) {
    stderr.writeln('lint: ${e.message}');
    exit(2);
  } on SetupException catch (e) {
    stderr.writeln('lint: ${e.message}');
    exit(2);
  }
}

int _report(LintResult result, List<DebtEntry> debt) {
  final DebtReport report = applyDebt(result.findings, debt);
  for (final Finding f in report.fresh) {
    stderr.writeln(f.display);
  }
  for (final DebtEntry e in report.stale) {
    stdout.writeln(
      'stale debt: ${e.rule} ${e.file} x${e.count}: ${e.key}  '
      '(fixed or moved; run with --update-debt)',
    );
  }
  for (final LongFile longFile in result.longFiles.take(_notesShown)) {
    stdout.writeln('note: ${longFile.path} has ${longFile.lines} lines');
  }
  stdout.writeln(
    '${result.findings.length} violations: ${report.covered} in debt, '
    '${report.fresh.length} new; ${report.stale.length} stale debt entries; '
    '${result.longFiles.length} production files over $maxFileLines lines (not a failure)',
  );
  return report.fresh.isEmpty ? 0 : 1;
}

void _updateDebt(File file, List<Finding> findings) {
  final List<DebtEntry> before = file.existsSync()
      ? parseDebt(file.readAsStringSync())
      : const [];
  final List<DebtEntry> after = debtFor(findings);
  file.writeAsStringSync(renderDebt(after));
  final DebtReport added = applyDebt(findings, before);
  stdout.writeln(
    'wrote ${file.path}: ${after.length} entries for ${findings.length} '
    'violations (${added.fresh.length} added, ${added.stale.length} dropped)',
  );
  final counts = <String, int>{};
  for (final f in findings) {
    counts[f.rule] = (counts[f.rule] ?? 0) + 1;
  }
  for (final String rule in ruleNames) {
    stdout.writeln('  $rule: ${counts[rule] ?? 0}');
  }
}

/// How many of the longest files a run lists.
const int _notesShown = 10;
