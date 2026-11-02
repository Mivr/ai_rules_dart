import 'package:freezed_annotation/freezed_annotation.dart';

part 'point.freezed.dart';

/// A freezed value class that `library_builder_library` generates directly.
@freezed
abstract class Point with _$Point {
  /// Creates a point at ([x], [y]).
  const factory Point({required int x, required int y}) = _Point;
}
