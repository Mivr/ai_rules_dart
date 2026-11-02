import 'package:copy_with_extension/copy_with_extension.dart';

part 'point.g.dart';

/// A point whose `copyWith` the `shared_part_library` macro generates.
@CopyWith()
class Point {
  /// Creates a point at ([x], [y]).
  const Point({required this.x, required this.y});

  /// The horizontal coordinate.
  final int x;

  /// The vertical coordinate.
  final int y;
}
