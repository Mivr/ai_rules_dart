/// What a rule reports and how a source line can allow it.
library;

import 'package:inventory/starlark.dart';

/// The lint cannot run: a scope it checks has no files, or a file it needs is
/// missing, so a pass would mean nothing.
class SetupException implements Exception {
  /// A setup problem described by [message].
  const new(this.message);

  /// What is missing.
  final String message;

  @override
  String toString() => message;
}

/// One violation of one rule.
class Finding {
  /// A violation of [rule] at [file]:[line].
  ///
  /// [key] identifies the violation across edits that only move it: the
  /// trimmed source line for a rule that flags a line, the message otherwise.
  const new({
    required this.rule,
    required this.file,
    required this.line,
    required this.message,
    required this.key,
  });

  /// The rule's name, as the debt list and an allow comment spell it.
  final String rule;

  /// The repository-relative path.
  final String file;

  /// The 1-based line.
  final int line;

  /// What is wrong and what to do about it.
  final String message;

  /// The stable identity within [rule] and [file].
  final String key;

  /// `file:line: [rule] message`.
  String get display => '$file:$line: [$rule] $message';
}

/// Whether the line [line] of [lines], or the line above it, carries a
/// `lint-allow: <rule> <reason>` comment with a reason.
bool isAllowed(Lines lines, String rule, int line) {
  final allow = RegExp('#\\s*lint-allow:\\s*${RegExp.escape(rule)}\\s+\\S');
  return allow.hasMatch(lines.raw(line)) || allow.hasMatch(lines.raw(line - 1));
}

/// A finding for the line of `lines` that holds `offset`, or null when an
/// allow comment covers it. The finding's key is that line, trimmed.
Finding? findingAt({
  required String rule,
  required String file,
  required Lines lines,
  required int offset,
  required String message,
}) {
  final int line = lines.of(offset);
  if (isAllowed(lines, rule, line)) return null;
  return Finding(
    rule: rule,
    file: file,
    line: line,
    message: message,
    key: lines.trimmed(line),
  );
}
