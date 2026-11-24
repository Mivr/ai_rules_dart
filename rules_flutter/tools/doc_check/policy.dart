/// The two checked-in lists that bend the rules, and how they are enforced.
library;

import 'rules.dart';

/// Parsed entries of a checked-in list, each with the reason it is there.
class Entries {
  /// Parses [text] with [split], which cuts a line into key and reason.
  ///
  /// Blank lines and `#` comments are skipped. An entry with no reason, or a
  /// key listed twice, is reported in [problems] naming [source].
  factory parse(
    String text,
    String source,
    (String, String) Function(String line) split,
  ) {
    final reasons = <String, String>{};
    final problems = <String>[];
    for (final String raw in text.split('\n')) {
      final String line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final (String key, String reason) = split(line);
      if (reason.isEmpty) {
        problems.add('$source: entry "$key" has no reason');
      } else if (reasons.containsKey(key)) {
        problems.add('$source: entry "$key" is listed twice');
      } else {
        reasons[key] = reason;
      }
    }
    return Entries._(reasons, problems);
  }

  const new _(this.reasons, this.problems);

  /// A list with no entries.
  static const empty = Entries._({}, []);

  /// The reason given for each key.
  final Map<String, String> reasons;

  /// Malformed entries found while parsing.
  final List<String> problems;
}

/// Splits an allowlist line, `symbol[.attr] reason`, at the first space.
(String, String) splitAllowlistLine(String line) {
  final int cut = line.indexOf(RegExp(r'\s'));
  return cut < 0
      ? (line, '')
      : (line.substring(0, cut), line.substring(cut).trim());
}

/// Splits a shared-phrasing line, `phrasing | reason`, at the last bar.
(String, String) splitPhrasingLine(String line) {
  final int cut = line.lastIndexOf('|');
  if (cut < 0) return (DocChecker.normalise(line), '');
  return (
    DocChecker.normalise(line.substring(0, cut)),
    line.substring(cut + 1).trim(),
  );
}

/// The outcome of applying the lists to the raw findings.
class Verdict {
  /// Creates a verdict.
  const new({required this.errors, required this.warnings});

  /// Report lines that fail the check.
  final List<String> errors;

  /// Report lines that are printed but not fatal.
  final List<String> warnings;

  /// Whether the check passed.
  bool get ok => errors.isEmpty;
}

/// Splits [findings] into errors and warnings, applying [allowlist].
///
/// An allowlist entry that covers no blocking finding is itself an error, so
/// the list can only shrink.
Verdict judge(
  List<Violation> findings,
  Entries allowlist,
  List<String> otherProblems,
) {
  final used = <String>{};
  final List<String> errors = [...allowlist.problems, ...otherProblems];
  final warnings = <String>[];
  for (final v in findings) {
    if (v.warning) {
      warnings.add('warning: ${v.format()}');
    } else if (allowlist.reasons.containsKey(v.symbol)) {
      used.add(v.symbol);
    } else {
      errors.add(v.format());
    }
  }
  for (final String symbol in allowlist.reasons.keys.where(
    (s) => !used.contains(s),
  )) {
    errors.add('allowlist entry $symbol covers no violation; delete it');
  }
  return Verdict(errors: errors..sort(), warnings: warnings..sort());
}

/// Errors for shared phrasings in [phrasings] that no group of more than 3
/// attributes uses, so that list can only shrink too.
List<String> staleShared(Entries phrasings, Map<String, int> usage) => [
  for (final phrase in phrasings.reasons.keys)
    if ((usage[phrase] ?? 0) <= 3)
      'shared phrasing "$phrase" is on 3 or fewer attributes; delete it',
];
