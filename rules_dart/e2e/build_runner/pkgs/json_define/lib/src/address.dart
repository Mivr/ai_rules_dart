import 'package:json_annotation/json_annotation.dart';

part 'address.g.dart';

@JsonSerializable()
class Address {
  Address({required this.streetLine, required this.city, this.postCode});

  factory Address.fromJson(Map<String, dynamic> json) =>
      _$AddressFromJson(json);

  final String streetLine;
  final String city;
  final String? postCode;

  Map<String, dynamic> toJson() => _$AddressToJson(this);
}
