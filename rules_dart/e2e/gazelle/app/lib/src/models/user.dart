import 'package:json_annotation/json_annotation.dart';

part 'user.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class User {
  User({required this.id, required this.displayName, this.email});

  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);

  final int id;
  final String displayName;
  final String? email;

  Map<String, dynamic> toJson() => _$UserToJson(this);
}
