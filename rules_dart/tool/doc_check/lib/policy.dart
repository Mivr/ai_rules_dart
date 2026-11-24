/// The checked-in allowlist and approved shared-phrasings list.
///
/// Both lists may only shrink. The allowlist holds `symbol[.attr] reason`
/// lines that suppress the blocking gaps of that key; an entry that
/// suppresses nothing is itself a failure, so a fixed gap forces its entry
/// out. The shared-phrasings list holds `phrasing => reason` lines for a doc
/// that genuinely belongs on several attributes.
library;

import 'package:doc_check/doc_rules.dart';

/// The parsed allowlist: key to reason.
typedef Allowlist = Map<String, String>;

/// Parses `symbol[.attr] reason` lines; `#` starts a comment line.
///
/// Throws a [FormatException] for a line without a reason.
Allowlist parseAllowlist(String text) {
  final entries = <String, String>{};
  for (final String line in _content(text)) {
    final int split = line.indexOf(RegExp(r'\s'));
    final String reason = split < 0 ? '' : line.substring(split).trim();
    if (reason.isEmpty) {
      throw FormatException('allowlist entry has no reason: $line');
    }
    entries[line.substring(0, split)] = reason;
  }
  return entries;
}

/// Parses `phrasing => reason` lines into the approved phrasings.
///
/// Throws a [FormatException] for a line without a reason.
Set<String> parseSharedPhrasings(String text) {
  final phrasings = <String>{};
  for (final String line in _content(text)) {
    final List<String> parts = line.split('=>');
    if (parts.length != 2 ||
        parts[0].trim().isEmpty ||
        parts[1].trim().isEmpty) {
      throw FormatException(
        'shared phrasing needs `phrasing => reason`: $line',
      );
    }
    phrasings.add(parts[0].trim());
  }
  return phrasings;
}

Iterable<String> _content(String text) sync* {
  for (final String raw in text.split('\n')) {
    final String line = raw.trim();
    if (line.isNotEmpty && !line.startsWith('#')) yield line;
  }
}

/// The outcome of applying an allowlist to a set of gaps.
class Filtered {
  /// Creates a filtered result.
  const new(this.errors, this.warnings, this.staleEntries);

  /// Blocking gaps the allowlist does not cover.
  final List<Gap> errors;

  /// Advisory gaps.
  final List<Gap> warnings;

  /// Allowlist keys that cover no blocking gap.
  final List<String> staleEntries;
}

/// Splits [gaps] into blocking and advisory, applying [allowlist].
Filtered applyAllowlist(List<Gap> gaps, Allowlist allowlist) {
  final used = <String>{};
  final errors = <Gap>[];
  for (final Gap gap in gaps.where((g) => !g.warning)) {
    if (allowlist.containsKey(gap.symbol)) {
      used.add(gap.symbol);
    } else {
      errors.add(gap);
    }
  }
  return Filtered(errors, gaps.where((g) => g.warning).toList(), [
    for (final key in allowlist.keys)
      if (!used.contains(key)) key,
  ]);
}
