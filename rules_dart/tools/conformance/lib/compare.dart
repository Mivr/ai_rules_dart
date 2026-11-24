/// Compares two sides' items and groups the differences by cause.
///
/// Every kind of output becomes a map from an item key to a value before it
/// gets here. A key is `<category>:<name>`: `asset:fonts/a.otf`,
/// `manifest:manifest/application@android:label`, `test:test/a_test.dart ::
/// adds`. An item on both sides with equal values is equal; anything else is a
/// difference whose cause is its category and what happened to it.
library;

import 'package:conformance/by_design.dart';
import 'package:conformance/layout.dart';

/// The value of one item: what is compared, and what to show when it differs.
class Value {
  const Value(this.digest, [this.note]);

  /// Equal values are equal items.
  final String digest;

  /// Shown next to a difference (a size, a result).
  final String? note;
}

typedef Items = Map<String, Value>;

/// One item that is not equal on the two sides.
class Difference {
  Difference(this.item, this.cause, this.detail);

  final String item;
  final String cause;
  final String detail;

  /// The reason, when the checked-in list says this difference is by design.
  String? byDesign;

  Map<String, Object?> toJson() => {
    'item': item,
    'cause': cause,
    if (detail.isNotEmpty) 'detail': detail,
    if (byDesign != null) 'by_design': byDesign,
  };
}

/// The category of an item key: the part before the first `:`.
String categoryOf(String key) {
  final int colon = key.indexOf(':');
  return colon < 0 ? key : key.substring(0, colon);
}

/// Compares [stock] and [rules] item by item, in key order.
({int compared, int equal, List<Difference> differences}) diffItems(
  Items stock,
  Items rules,
) {
  final keys = {...stock.keys, ...rules.keys}.toList()..sort();
  var equal = 0;
  final differences = <Difference>[];
  for (final key in keys) {
    final Value? s = stock[key];
    final Value? r = rules[key];
    final String category = categoryOf(key);
    if (s == null) {
      differences.add(
        Difference(key, '$category: only in rules', r!.note ?? ''),
      );
    } else if (r == null) {
      differences.add(
        Difference(key, '$category: only in stock', s.note ?? ''),
      );
    } else if (s.digest == r.digest) {
      equal++;
    } else {
      final detail = s.note == null && r.note == null
          ? ''
          : 'stock ${s.note ?? '?'}, rules ${r.note ?? '?'}';
      differences.add(Difference(key, '$category: differs', detail));
    }
  }
  return (compared: keys.length, equal: equal, differences: differences);
}

/// The outcome for one project and kind.
class KindResult {
  KindResult({
    required this.project,
    required this.kind,
    required this.stock,
    required this.rules,
    this.compared = 0,
    this.equal = 0,
    this.differences = const [],
    this.notCompared,
    this.applied = const {},
  });

  final String project;
  final Kind kind;

  /// Null when that side was not run at all.
  final Status? stock;
  final Status? rules;

  final int compared;
  final int equal;
  final List<Difference> differences;

  /// Why nothing was compared, when nothing was.
  final String? notCompared;

  /// How often each normaliser changed something.
  final Map<String, int> applied;

  int get byDesign => differences.where((d) => d.byDesign != null).length;
  int get counted => differences.length - byDesign;

  /// Equal or by design, over compared; null when nothing was compared.
  double? get score =>
      compared == 0 ? null : (equal + byDesign) / compared.toDouble();

  /// The differences that count, grouped by cause, largest group first.
  List<({String cause, List<Difference> items})> groups() {
    final byCause = <String, List<Difference>>{};
    for (final d in differences) {
      final String cause = d.byDesign != null
          ? 'by design: ${d.cause}'
          : d.cause;
      (byCause[cause] ??= []).add(d);
    }
    final List<String> causes = byCause.keys.toList()
      ..sort((a, b) {
        final int bySize = byCause[b]!.length.compareTo(byCause[a]!.length);
        return bySize != 0 ? bySize : a.compareTo(b);
      });
    return [for (final c in causes) (cause: c, items: byCause[c]!)];
  }
}

/// Marks the differences [list] covers; returns the entries it used.
Set<ByDesignEntry> applyByDesign(
  String project,
  Kind kind,
  List<Difference> differences,
  List<ByDesignEntry> list,
) {
  final used = <ByDesignEntry>{};
  for (final d in differences) {
    for (final e in list) {
      if (e.matches(project, kind, d.item, d.cause)) {
        d.byDesign = e.reason;
        used.add(e);
        break;
      }
    }
  }
  return used;
}
