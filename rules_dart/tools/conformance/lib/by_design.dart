/// The checked-in list of differences that are by design, each with a reason.
///
/// A difference this list covers does not count against the score. An entry
/// that covers nothing in a run is reported, so the list shrinks when the
/// difference goes away.
///
///     {"entries": [
///       {"projects": ["*"], "kinds": ["apk"], "item": "entry:META-INF/*",
///        "cause": "only in stock", "reason": "..."}
///     ]}
///
/// `item` is a glob over the item key (`*` matches anything, `/` included);
/// `cause`, when given, must be contained in the difference's cause.
library;

import 'dart:convert';

import 'package:conformance/layout.dart';

/// One by-design difference.
class ByDesignEntry {
  ByDesignEntry({
    required this.projects,
    required this.kinds,
    required this.item,
    required this.reason,
    this.cause,
  }) : _item = globToRegExp(item);

  factory ByDesignEntry.fromJson(Map<String, Object?> json) {
    final reason = json['reason'] as String? ?? '';
    if (reason.trim().isEmpty) {
      throw FormatException('by-design entry without a reason: $json');
    }
    return ByDesignEntry(
      projects: [
        for (final p in json['projects'] as List? ?? ['*']) '$p',
      ],
      kinds: [for (final k in json['kinds'] as List) Kind.parse('$k')],
      item: json['item'] as String,
      cause: json['cause'] as String?,
      reason: reason,
    );
  }

  final List<String> projects;
  final List<Kind> kinds;
  final String item;
  final String? cause;
  final String reason;
  final RegExp _item;

  bool matches(String project, Kind kind, String itemKey, String diffCause) =>
      kinds.contains(kind) &&
      projects.any((p) => p == '*' || p == project) &&
      _item.hasMatch(itemKey) &&
      (cause == null || diffCause.contains(cause!));

  String get display =>
      '${projects.join(',')} ${kinds.map((k) => k.name).join(',')} $item'
      '${cause == null ? '' : ' ($cause)'}';
}

/// Parses the list.
List<ByDesignEntry> parseByDesign(String text) {
  final json = jsonDecode(text) as Map<String, Object?>;
  return [
    for (final e in json['entries'] as List)
      ByDesignEntry.fromJson(e as Map<String, Object?>),
  ];
}

/// An anchored pattern for [glob]: `*` is any run of characters, `?` one.
RegExp globToRegExp(String glob) {
  final out = StringBuffer('^');
  for (final rune in glob.runes) {
    final c = String.fromCharCode(rune);
    out.write(switch (c) {
      '*' => '.*',
      '?' => '.',
      _ => RegExp.escape(c),
    });
  }
  out.write(r'$');
  return RegExp(out.toString(), dotAll: true);
}
