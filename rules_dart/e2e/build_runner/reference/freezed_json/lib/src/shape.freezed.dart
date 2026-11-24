// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'shape.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
Shape _$ShapeFromJson(
  Map<String, dynamic> json
) {
        switch (json['runtimeType']) {
                  case 'circle':
          return Circle.fromJson(
            json
          );
                case 'rectangle':
          return Rectangle.fromJson(
            json
          );
                case 'polygon':
          return Polygon.fromJson(
            json
          );
        
          default:
            throw CheckedFromJsonException(
  json,
  'runtimeType',
  'Shape',
  'Invalid union type "${json['runtimeType']}"!'
);
        }
      
}

/// @nodoc
mixin _$Shape {



  /// Serializes this Shape to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Shape);
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'Shape()';
}


}

/// @nodoc
class $ShapeCopyWith<$Res>  {
$ShapeCopyWith(Shape _, $Res Function(Shape) __);
}


/// Adds pattern-matching-related methods to [Shape].
extension ShapePatterns on Shape {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( Circle value)?  circle,TResult Function( Rectangle value)?  rectangle,TResult Function( Polygon value)?  polygon,required TResult orElse(),}){
final _that = this;
switch (_that) {
case Circle() when circle != null:
return circle(_that);case Rectangle() when rectangle != null:
return rectangle(_that);case Polygon() when polygon != null:
return polygon(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( Circle value)  circle,required TResult Function( Rectangle value)  rectangle,required TResult Function( Polygon value)  polygon,}){
final _that = this;
switch (_that) {
case Circle():
return circle(_that);case Rectangle():
return rectangle(_that);case Polygon():
return polygon(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( Circle value)?  circle,TResult? Function( Rectangle value)?  rectangle,TResult? Function( Polygon value)?  polygon,}){
final _that = this;
switch (_that) {
case Circle() when circle != null:
return circle(_that);case Rectangle() when rectangle != null:
return rectangle(_that);case Polygon() when polygon != null:
return polygon(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( double radius)?  circle,TResult Function( double width,  double height,  String colour)?  rectangle,TResult Function( List<Point> points)?  polygon,required TResult orElse(),}) {final _that = this;
switch (_that) {
case Circle() when circle != null:
return circle(_that.radius);case Rectangle() when rectangle != null:
return rectangle(_that.width,_that.height,_that.colour);case Polygon() when polygon != null:
return polygon(_that.points);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( double radius)  circle,required TResult Function( double width,  double height,  String colour)  rectangle,required TResult Function( List<Point> points)  polygon,}) {final _that = this;
switch (_that) {
case Circle():
return circle(_that.radius);case Rectangle():
return rectangle(_that.width,_that.height,_that.colour);case Polygon():
return polygon(_that.points);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( double radius)?  circle,TResult? Function( double width,  double height,  String colour)?  rectangle,TResult? Function( List<Point> points)?  polygon,}) {final _that = this;
switch (_that) {
case Circle() when circle != null:
return circle(_that.radius);case Rectangle() when rectangle != null:
return rectangle(_that.width,_that.height,_that.colour);case Polygon() when polygon != null:
return polygon(_that.points);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class Circle implements Shape {
  const Circle({required this.radius,  String? $type}): $type = $type ?? 'circle';
  factory Circle.fromJson(Map<String, dynamic> json) => _$CircleFromJson(json);

 final  double radius;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of Shape
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CircleCopyWith<Circle> get copyWith => _$CircleCopyWithImpl<Circle>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$CircleToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Circle&&(identical(other.radius, radius) || other.radius == radius));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,radius);
}

@override
String toString() {
    return 'Shape.circle(radius: $radius)';
}


}

/// @nodoc
abstract mixin class $CircleCopyWith<$Res> implements $ShapeCopyWith<$Res> {
  factory $CircleCopyWith(Circle value, $Res Function(Circle) _then) = _$CircleCopyWithImpl;
@useResult
$Res call({
 double radius
});




}
/// @nodoc
class _$CircleCopyWithImpl<$Res>
    implements $CircleCopyWith<$Res> {
  _$CircleCopyWithImpl(this._self, this._then);

  final Circle _self;
  final $Res Function(Circle) _then;

/// Create a copy of Shape
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? radius = null,}) {
  return _then(Circle(
radius: null == radius ? _self.radius : radius // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc
@JsonSerializable()

class Rectangle implements Shape {
  const Rectangle({required this.width, required this.height, this.colour = '#000000',  String? $type}): $type = $type ?? 'rectangle';
  factory Rectangle.fromJson(Map<String, dynamic> json) => _$RectangleFromJson(json);

 final  double width;
 final  double height;
@JsonKey() final  String colour;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of Shape
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RectangleCopyWith<Rectangle> get copyWith => _$RectangleCopyWithImpl<Rectangle>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$RectangleToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Rectangle&&(identical(other.width, width) || other.width == width)&&(identical(other.height, height) || other.height == height)&&(identical(other.colour, colour) || other.colour == colour));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,width,height,colour);
}

@override
String toString() {
    return 'Shape.rectangle(width: $width, height: $height, colour: $colour)';
}


}

/// @nodoc
abstract mixin class $RectangleCopyWith<$Res> implements $ShapeCopyWith<$Res> {
  factory $RectangleCopyWith(Rectangle value, $Res Function(Rectangle) _then) = _$RectangleCopyWithImpl;
@useResult
$Res call({
 double width, double height, String colour
});




}
/// @nodoc
class _$RectangleCopyWithImpl<$Res>
    implements $RectangleCopyWith<$Res> {
  _$RectangleCopyWithImpl(this._self, this._then);

  final Rectangle _self;
  final $Res Function(Rectangle) _then;

/// Create a copy of Shape
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? width = null,Object? height = null,Object? colour = null,}) {
  return _then(Rectangle(
width: null == width ? _self.width : width // ignore: cast_nullable_to_non_nullable
as double,height: null == height ? _self.height : height // ignore: cast_nullable_to_non_nullable
as double,colour: null == colour ? _self.colour : colour // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
@JsonSerializable()

class Polygon implements Shape {
  const Polygon( List<Point> points, { String? $type}): _points = points,$type = $type ?? 'polygon';
  factory Polygon.fromJson(Map<String, dynamic> json) => _$PolygonFromJson(json);

 final  List<Point> _points;
 List<Point> get points {
  if (_points is EqualUnmodifiableListView) return _points;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_points);
}


@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of Shape
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PolygonCopyWith<Polygon> get copyWith => _$PolygonCopyWithImpl<Polygon>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PolygonToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is Polygon&&const DeepCollectionEquality().equals(other.points, _points));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,const DeepCollectionEquality().hash(_points));
}

@override
String toString() {
    return 'Shape.polygon(points: $points)';
}


}

/// @nodoc
abstract mixin class $PolygonCopyWith<$Res> implements $ShapeCopyWith<$Res> {
  factory $PolygonCopyWith(Polygon value, $Res Function(Polygon) _then) = _$PolygonCopyWithImpl;
@useResult
$Res call({
 List<Point> points
});




}
/// @nodoc
class _$PolygonCopyWithImpl<$Res>
    implements $PolygonCopyWith<$Res> {
  _$PolygonCopyWithImpl(this._self, this._then);

  final Polygon _self;
  final $Res Function(Polygon) _then;

/// Create a copy of Shape
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? points = null,}) {
  return _then(Polygon(
null == points ? _self._points : points // ignore: cast_nullable_to_non_nullable
as List<Point>,
  ));
}


}


/// @nodoc
mixin _$Point {

 double get x; double get y;
/// Create a copy of Point
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PointCopyWith<Point> get copyWith => _$PointCopyWithImpl<Point>(this as Point, _$identity);

  /// Serializes this Point to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as Point;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Point&&(identical(other.x, _this.x) || other.x == _this.x)&&(identical(other.y, _this.y) || other.y == _this.y));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as Point;
  return Object.hash(runtimeType,_this.x,_this.y);
}

@override
String toString() {
  final _this = this as Point;
  return 'Point(x: ${_this.x}, y: ${_this.y})';
}


}

/// @nodoc
abstract mixin class $PointCopyWith<$Res>  {
  factory $PointCopyWith(Point value, $Res Function(Point) _then) = _$PointCopyWithImpl;
@useResult
$Res call({
 double x, double y
});




}
/// @nodoc
class _$PointCopyWithImpl<$Res>
    implements $PointCopyWith<$Res> {
  _$PointCopyWithImpl(this._self, this._then);

  final Point _self;
  final $Res Function(Point) _then;

/// Create a copy of Point
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? x = null,Object? y = null,}) {
  return _then(Point(
x: null == x ? _self.x : x // ignore: cast_nullable_to_non_nullable
as double,y: null == y ? _self.y : y // ignore: cast_nullable_to_non_nullable
as double,
  ));
}

}


/// Adds pattern-matching-related methods to [Point].
extension PointPatterns on Point {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Point value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Point() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Point value)  $default,){
final _that = this;
switch (_that) {
case _Point():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Point value)?  $default,){
final _that = this;
switch (_that) {
case _Point() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double x,  double y)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Point() when $default != null:
return $default(_that.x,_that.y);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double x,  double y)  $default,) {final _that = this;
switch (_that) {
case _Point():
return $default(_that.x,_that.y);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double x,  double y)?  $default,) {final _that = this;
switch (_that) {
case _Point() when $default != null:
return $default(_that.x,_that.y);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Point implements Point {
  const _Point({required this.x, required this.y});
  factory _Point.fromJson(Map<String, dynamic> json) => _$PointFromJson(json);

@override final  double x;
@override final  double y;

/// Create a copy of Point
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PointCopyWith<_Point> get copyWith => __$PointCopyWithImpl<_Point>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PointToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _Point&&(identical(other.x, x) || other.x == x)&&(identical(other.y, y) || other.y == y));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,x,y);
}

@override
String toString() {
    return 'Point(x: $x, y: $y)';
}


}

/// @nodoc
abstract mixin class _$PointCopyWith<$Res> implements $PointCopyWith<$Res> {
  factory _$PointCopyWith(_Point value, $Res Function(_Point) _then) = __$PointCopyWithImpl;
@override @useResult
$Res call({
 double x, double y
});




}
/// @nodoc
class __$PointCopyWithImpl<$Res>
    implements _$PointCopyWith<$Res> {
  __$PointCopyWithImpl(this._self, this._then);

  final _Point _self;
  final $Res Function(_Point) _then;

/// Create a copy of Point
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? x = null,Object? y = null,}) {
  return _then(_Point(
x: null == x ? _self.x : x // ignore: cast_nullable_to_non_nullable
as double,y: null == y ? _self.y : y // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

// dart format on
