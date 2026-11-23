import 'package:json_annotation/json_annotation.dart';

part 'user.g.dart';

/// A serializable model exercising `dart_codegen` kernel shims under mixed
/// SDKs.
@JsonSerializable()
class CoupledUser {
  /// Creates a [CoupledUser].
  const CoupledUser({required this.id, required this.name});

  /// Deserializes a [CoupledUser] from [json].
  factory CoupledUser.fromJson(Map<String, dynamic> json) =>
      _$CoupledUserFromJson(json);

  /// The user's numeric identifier.
  final int id;

  /// The user's display name.
  final String name;

  /// Serializes this user to a JSON map.
  Map<String, dynamic> toJson() => _$CoupledUserToJson(this);
}
