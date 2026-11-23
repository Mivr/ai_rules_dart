// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Settings _$SettingsFromJson(Map<String, dynamic> json) => _Settings(
  darkMode: json['darkMode'] as bool? ?? false,
  favouriteShape: json['favourite_shape'] == null
      ? null
      : Shape.fromJson(json['favourite_shape'] as Map<String, dynamic>),
  counters:
      (json['counters'] as Map<String, dynamic>?)?.map(
        (k, e) => MapEntry(k, (e as num).toInt()),
      ) ??
      const <String, int>{},
);

Map<String, dynamic> _$SettingsToJson(_Settings instance) => <String, dynamic>{
  'darkMode': instance.darkMode,
  'favourite_shape': instance.favouriteShape,
  'counters': instance.counters,
};
