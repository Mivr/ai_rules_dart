// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'user.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

User _$UserFromJson(Map<String, dynamic> json) => User(
  id: (json['id'] as num).toInt(),
  displayName: json['display-name'] as String,
  createdAt: DateTime.parse(json['created-at'] as String),
  role: $enumDecodeNullable(_$RoleEnumMap, json['role']) ?? Role.member,
  addresses:
      (json['addresses'] as List<dynamic>?)
          ?.map((e) => Address.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
  tags:
      (json['tags'] as List<dynamic>?)?.map((e) => e as String).toSet() ??
      const {},
  score: (json['rating'] as num?)?.toDouble() ?? 0.5,
);

Map<String, dynamic> _$UserToJson(User instance) => <String, dynamic>{
  'id': instance.id,
  'display-name': instance.displayName,
  'created-at': instance.createdAt.toIso8601String(),
  'role': _$RoleEnumMap[instance.role]!,
  'addresses': instance.addresses.map((e) => e.toJson()).toList(),
  'tags': instance.tags.toList(),
  'rating': instance.score,
};

const _$RoleEnumMap = {
  Role.admin: 'admin',
  Role.member: 'member',
  Role.guest: 'guest',
};

Page<T> _$PageFromJson<T>(
  Map<String, dynamic> json,
  T Function(Object? json) fromJsonT,
) => Page<T>(
  items: (json['items'] as List<dynamic>).map(fromJsonT).toList(),
  nextCursor: json['nextCursor'] as String?,
);

Map<String, dynamic> _$PageToJson<T>(
  Page<T> instance,
  Object? Function(T value) toJsonT,
) => <String, dynamic>{
  'items': instance.items.map(toJsonT).toList(),
  'nextCursor': instance.nextCursor,
};
