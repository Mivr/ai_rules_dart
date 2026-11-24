// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'shape.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Circle _$CircleFromJson(Map<String, dynamic> json) => Circle(
  radius: (json['radius'] as num).toDouble(),
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$CircleToJson(Circle instance) => <String, dynamic>{
  'radius': instance.radius,
  'runtimeType': instance.$type,
};

Rectangle _$RectangleFromJson(Map<String, dynamic> json) => Rectangle(
  width: (json['width'] as num).toDouble(),
  height: (json['height'] as num).toDouble(),
  colour: json['colour'] as String? ?? '#000000',
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$RectangleToJson(Rectangle instance) => <String, dynamic>{
  'width': instance.width,
  'height': instance.height,
  'colour': instance.colour,
  'runtimeType': instance.$type,
};

Polygon _$PolygonFromJson(Map<String, dynamic> json) => Polygon(
  (json['points'] as List<dynamic>)
      .map((e) => Point.fromJson(e as Map<String, dynamic>))
      .toList(),
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$PolygonToJson(Polygon instance) => <String, dynamic>{
  'points': instance.points,
  'runtimeType': instance.$type,
};

_Point _$PointFromJson(Map<String, dynamic> json) =>
    _Point(x: (json['x'] as num).toDouble(), y: (json['y'] as num).toDouble());

Map<String, dynamic> _$PointToJson(_Point instance) => <String, dynamic>{
  'x': instance.x,
  'y': instance.y,
};
