/// Least-squares growth exponent of a cost against the library count.
library;

import 'dart:math';

/// Fits `cost ~ libraries ^ e` and returns the exponent `e`.
///
/// `e` is the least-squares slope of `log(cost)` against `log(libraries)` over
/// all [points], given as `(libraries, cost)`. The result is rounded to 12
/// decimals so inputs that are exact powers give exact exponents. Throws an
/// [ArgumentError] for fewer than two points, a non-positive library count or
/// cost, a non-finite cost, or points that all share one library count.
double fitGrowthExponent(List<(int, double)> points) {
  if (points.length < 2) {
    throw ArgumentError.value(
      points.length,
      'points',
      'need at least two points to fit a growth exponent',
    );
  }
  final xs = <double>[];
  final ys = <double>[];
  for (final (libraries, cost) in points) {
    if (libraries <= 0 || !cost.isFinite || cost <= 0) {
      throw ArgumentError.value(
        '($libraries, $cost)',
        'points',
        'libraries and cost must be positive and finite',
      );
    }
    xs.add(log(libraries));
    ys.add(log(cost));
  }
  final meanX = xs.reduce((a, b) => a + b) / xs.length;
  final meanY = ys.reduce((a, b) => a + b) / ys.length;
  var sxx = 0.0;
  var sxy = 0.0;
  for (var i = 0; i < xs.length; i++) {
    sxx += (xs[i] - meanX) * (xs[i] - meanX);
    sxy += (xs[i] - meanX) * (ys[i] - meanY);
  }
  if (sxx == 0) {
    throw ArgumentError.value(
      points,
      'points',
      'need at least two distinct library counts',
    );
  }
  return (sxy / sxx * 1e12).roundToDouble() / 1e12;
}
