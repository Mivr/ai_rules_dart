/// Median, range and agreement of a flow's runs.
library;

/// The median of [values]; the mean of the middle two for an even count.
double medianOf(List<double> values) {
  if (values.isEmpty) throw ArgumentError('no values');
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// Rounds [v] to three decimals, for the ledger.
double round3(double v) => (v * 1000).roundToDouble() / 1000;

/// The runs of one flow: median and range.
final class Summary {
  /// Summarises [runs], which must not be empty.
  Summary(List<double> runs)
    : runs = List.unmodifiable(runs),
      median = medianOf(runs),
      min = runs.reduce((a, b) => a < b ? a : b),
      max = runs.reduce((a, b) => a > b ? a : b);

  /// Every run, in order.
  final List<double> runs;

  /// The median of [runs].
  final double median;

  /// The smallest run.
  final double min;

  /// The largest run.
  final double max;

  /// Whether [value] lies within this summary's range.
  bool contains(double value) => value >= min && value <= max;
}

/// Whether two passes of one flow agree with each other: the median of one
/// lies within the range of the other.
bool agree(Summary a, Summary b) =>
    a.contains(b.median) || b.contains(a.median);
