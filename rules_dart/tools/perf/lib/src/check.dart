/// The regression check of the merge gate: each flow against its baseline
/// row, failing on a slower median or on an action of a new kind.
library;

import 'ledger.dart';

/// The verdict on one flow.
final class Verdict {
  /// A verdict on [id]; it passes when [failures] is empty.
  const Verdict(this.id, this.failures, this.summary);

  /// The flow.
  final String id;

  /// Why it fails.
  final List<String> failures;

  /// The figures compared.
  final String summary;

  /// Whether the flow passes.
  bool get pass => failures.isEmpty;
}

/// The latest usable baseline row of each flow id in [rows]: status `ok`
/// and not noisy (a noisy row is never a baseline).
Map<String, Row> baselines(List<Row> rows) => {
  for (final r in rows)
    if (r.status == 'ok' && !r.noisy && r.runs.isNotEmpty) r.id: r,
};

String _kind(String mnemonic) => mnemonic.endsWith(' (cached)')
    ? mnemonic.substring(0, mnemonic.length - ' (cached)'.length)
    : mnemonic;

/// Compares [current] rows with [baseline] rows. A timed flow fails when
/// its median is above the baseline's by more than [margin] (a fraction)
/// and by more than [floor] seconds; a count flow fails when its count
/// grows; any flow fails when an action mnemonic appears that the baseline
/// did not have, or when it has no usable baseline.
List<Verdict> compareRows(
  List<Row> current,
  List<Row> baseline, {
  double margin = 0.25,
  double floor = 0.05,
}) {
  final base = baselines(baseline);
  return [for (final r in current) _verdict(r, base[r.id], margin, floor)];
}

Verdict _verdict(Row r, Row? b, double margin, double floor) {
  final failures = <String>[];
  if (r.status != 'ok' || r.median == null) {
    return Verdict(r.id, ['the flow did not run: ${r.notes}'], '');
  }
  if (b == null) {
    return Verdict(r.id, [
      'no baseline row (status ok, not noisy) for ${r.id}',
    ], '');
  }
  final now = r.median!;
  final then = b.median!;
  final unit = r.unit;
  final summary =
      '$now $unit against $then $unit${r.noisy ? ' (this run is noisy)' : ''}';
  if (unit == 's') {
    if (now > then * (1 + margin) && now - then > floor) {
      failures.add(
        'slower: median $now s against $then s (more than ${(margin * 100).round()}% and ${floor}s)',
      );
    }
  } else if (now > then) {
    failures.add('more $unit: $now against $then');
  }
  final had = {for (final m in b.mnemonics.keys) _kind(m)};
  final added = {
    for (final m in r.mnemonics.keys)
      if (!had.contains(_kind(m))) _kind(m),
  };
  if (added.isNotEmpty) {
    failures.add(
      'new action mnemonics: ${(added.toList()..sort()).join(', ')}',
    );
  }
  return Verdict(r.id, failures, summary);
}
