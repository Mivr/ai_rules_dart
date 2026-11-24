import 'package:json_annotation/json_annotation.dart';

import 'address.dart';

part 'user.g.dart';

enum Role {
  @JsonValue('admin')
  admin,
  @JsonValue('member')
  member,
  guest,
}

@JsonSerializable()
class User {
  User({
    required this.id,
    required this.displayName,
    required this.createdAt,
    this.role = Role.member,
    this.addresses = const [],
    this.tags = const {},
    this.score,
  });

  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);

  final int id;
  final String displayName;
  final DateTime createdAt;
  final Role role;
  final List<Address> addresses;
  final Set<String> tags;
  @JsonKey(name: 'rating', defaultValue: 0.5)
  final double? score;
  @JsonKey(includeToJson: false, includeFromJson: false)
  int transientCounter = 0;

  Map<String, dynamic> toJson() => _$UserToJson(this);
}

@JsonSerializable(genericArgumentFactories: true, fieldRename: FieldRename.none)
class Page<T> {
  Page({required this.items, required this.nextCursor});

  factory Page.fromJson(
    Map<String, dynamic> json,
    T Function(Object? json) fromJsonT,
  ) => _$PageFromJson(json, fromJsonT);

  final List<T> items;
  final String? nextCursor;

  Map<String, dynamic> toJson(Object? Function(T value) toJsonT) =>
      _$PageToJson(this, toJsonT);
}
