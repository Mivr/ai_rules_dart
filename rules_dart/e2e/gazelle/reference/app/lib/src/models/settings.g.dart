// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Settings _$SettingsFromJson(Map<String, dynamic> json) => _Settings(
  theme: $enumDecodeNullable(_$ThemeEnumMap, json['theme']) ?? Theme.system,
  fontSize: (json['fontSize'] as num?)?.toInt() ?? 14,
  pinned:
      (json['pinned'] as List<dynamic>?)?.map((e) => e as String).toList() ??
      const <String>[],
);

Map<String, dynamic> _$SettingsToJson(_Settings instance) => <String, dynamic>{
  'theme': _$ThemeEnumMap[instance.theme]!,
  'fontSize': instance.fontSize,
  'pinned': instance.pinned,
};

const _$ThemeEnumMap = {
  Theme.light: 'light',
  Theme.dark: 'dark',
  Theme.system: 'system',
};
