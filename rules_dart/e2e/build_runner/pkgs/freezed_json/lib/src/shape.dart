import 'package:freezed_annotation/freezed_annotation.dart';

part 'shape.freezed.dart';
part 'shape.g.dart';

@freezed
sealed class Shape with _$Shape {
  const factory Shape.circle({required double radius}) = Circle;
  const factory Shape.rectangle({
    required double width,
    required double height,
    @Default('#000000') String colour,
  }) = Rectangle;
  const factory Shape.polygon(List<Point> points) = Polygon;

  factory Shape.fromJson(Map<String, dynamic> json) => _$ShapeFromJson(json);
}

@freezed
abstract class Point with _$Point {
  const factory Point({required double x, required double y}) = _Point;

  factory Point.fromJson(Map<String, dynamic> json) => _$PointFromJson(json);
}
