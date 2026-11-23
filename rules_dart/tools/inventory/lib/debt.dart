/// The checked-in list of violations that exist today.
library;

import 'dart:convert';

import 'package:inventory/finding.dart';

/// The debt entries of one rule in one file with one key, and how many
/// violations they cover.
typedef DebtEntry = ({String rule, String file, String key, int count});

/// Findings split by whether the debt list covers them.
typedef DebtReport = ({
  List<Finding> fresh,
  List<DebtEntry> stale,
  int covered,
});

/// Parses a debt file, a JSON object with an `entries` array.
List<DebtEntry> parseDebt(String json) {
  if (json.trim().isEmpty) return const [];
  final Object? decoded = jsonDecode(json);
  final Object? entries = decoded is Map<String, Object?>
      ? decoded['entries']
      : null;
  if (entries is! List<Object?>) {
    throw const FormatException('debt file needs an "entries" array');
  }
  return [
    for (final Object? entry in entries)
      if (entry is Map<String, Object?>)
        (
          rule: entry['rule']! as String,
          file: entry['file']! as String,
          key: entry['key']! as String,
          count: entry['count']! as int,
        ),
  ];
}

/// Renders [entries] one per line, sorted, so a diff shows what changed.
String renderDebt(List<DebtEntry> entries) {
  final sorted = <DebtEntry>[...entries]
    ..sort((a, b) => _id(a).compareTo(_id(b)));
  final out = StringBuffer('{\n  "entries": [\n');
  for (var i = 0; i < sorted.length; i++) {
    final DebtEntry e = sorted[i];
    final comma = i == sorted.length - 1 ? '' : ',';
    out.writeln(
      '    ${jsonEncode({'rule': e.rule, 'file': e.file, 'key': e.key, 'count': e.count})}$comma',
    );
  }
  out.write('  ]\n}\n');
  return out.toString();
}

/// The debt list that covers exactly [findings].
List<DebtEntry> debtFor(List<Finding> findings) {
  final counts = <String, DebtEntry>{};
  for (final f in findings) {
    final DebtEntry? seen = counts[_findingId(f)];
    counts[_findingId(f)] = (
      rule: f.rule,
      file: f.file,
      key: f.key,
      count: (seen?.count ?? 0) + 1,
    );
  }
  return counts.values.toList();
}

/// Splits [findings] into those beyond [debt] and the entries of [debt] that
/// cover fewer violations than they claim.
DebtReport applyDebt(List<Finding> findings, List<DebtEntry> debt) {
  final remaining = <String, int>{for (final e in debt) _id(e): e.count};
  final fresh = <Finding>[];
  var covered = 0;
  for (final f in findings) {
    final int left = remaining[_findingId(f)] ?? 0;
    if (left > 0) {
      remaining[_findingId(f)] = left - 1;
      covered++;
    } else {
      fresh.add(f);
    }
  }
  return (
    fresh: fresh,
    stale: [
      for (final DebtEntry e in debt)
        if ((remaining[_id(e)] ?? 0) > 0)
          (rule: e.rule, file: e.file, key: e.key, count: remaining[_id(e)]!),
    ],
    covered: covered,
  );
}

String _id(DebtEntry e) => '${e.rule}\u0000${e.file}\u0000${e.key}';

String _findingId(Finding f) => '${f.rule}\u0000${f.file}\u0000${f.key}';
