// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'user.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

User _$UserFromJson(Map<String, dynamic> json) => User(
  id: (json['Id'] as num).toInt(),
  displayName: json['DisplayName'] as String,
  createdAt: DateTime.parse(json['CreatedAt'] as String),
  role: $enumDecodeNullable(_$RoleEnumMap, json['Role']) ?? Role.member,
  addresses:
      (json['Addresses'] as List<dynamic>?)
          ?.map((e) => Address.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
  tags:
      (json['Tags'] as List<dynamic>?)?.map((e) => e as String).toSet() ??
      const {},
  score: (json['rating'] as num?)?.toDouble() ?? 0.5,
);

Map<String, dynamic> _$UserToJson(User instance) => <String, dynamic>{
  'Id': instance.id,
  'DisplayName': instance.displayName,
  'CreatedAt': instance.createdAt.toIso8601String(),
  'Role': _$RoleEnumMap[instance.role]!,
  'Addresses': instance.addresses,
  'Tags': instance.tags.toList(),
  'rating': ?instance.score,
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
  'nextCursor': ?instance.nextCursor,
};
