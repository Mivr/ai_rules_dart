/// Maps a requested library count onto the generator's layers x fanout grid.
library;

import 'dart:math';

import 'cli_args.dart';

/// Largest fanout (packages per layer) `--libraries` will pick.
const int maxLibrariesFanout = 50;

/// A layered package DAG shape.
final class LibraryShape {
  /// Creates a shape of [layers] layers with [fanout] packages each.
  const LibraryShape(this.layers, this.fanout);

  /// Number of DAG layers.
  final int layers;

  /// Packages per layer.
  final int fanout;

  /// Total number of `dart_library` targets.
  int get libraries => layers * fanout;
}

/// Picks `layers` and `fanout` with `layers * fanout == libraries`.
///
/// Fanout is at most [maxLibrariesFanout] and layers at least 2. Among the
/// possible splits the one closest to a square wins, ties go to the smaller
/// fanout. When no split exists the next larger product is used.
LibraryShape shapeForLibraries(int libraries) {
  if (libraries < 2) {
    throw ArgumentError.value(libraries, 'libraries', 'must be at least 2');
  }
  for (var product = libraries; ; product++) {
    final shape = _closestSplit(product);
    if (shape != null) return shape;
  }
}

LibraryShape? _closestSplit(int product) {
  final root = sqrt(product);
  LibraryShape? best;
  for (
    var fanout = 1;
    fanout <= min(maxLibrariesFanout, product ~/ 2);
    fanout++
  ) {
    if (product % fanout != 0) continue;
    final bestFanout = best?.fanout;
    if (bestFanout == null ||
        (fanout - root).abs() < (bestFanout - root).abs()) {
      best = LibraryShape(product ~/ fanout, fanout);
    }
  }
  return best;
}

/// Result of resolving the shape flags of `generate`.
typedef ShapeResolution = ({LibraryShape? shape, String? error});

/// Resolves `--libraries` or `--layers`/`--fanout` (default 8 x 4).
ShapeResolution resolveShapeFlags(Map<String, List<String>> flags) {
  if (flags.containsKey('libraries')) {
    if (flags.containsKey('layers') || flags.containsKey('fanout')) {
      return (
        shape: null,
        error: '--libraries cannot be combined with --layers or --fanout',
      );
    }
    final libraries = intFlagValue(flags, const ['libraries']);
    if (libraries == null || libraries < 2) {
      return (shape: null, error: '--libraries must be an integer >= 2');
    }
    return (shape: shapeForLibraries(libraries), error: null);
  }
  final layers = intFlagValue(flags, const ['layers'], defaultValue: 8);
  final fanout = intFlagValue(flags, const ['fanout'], defaultValue: 4);
  if (layers == null || layers < 2 || fanout == null || fanout < 1) {
    return (shape: null, error: 'invalid --layers or --fanout');
  }
  return (shape: LibraryShape(layers, fanout), error: null);
}
