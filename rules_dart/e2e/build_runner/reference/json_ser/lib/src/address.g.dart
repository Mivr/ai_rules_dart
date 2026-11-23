// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'address.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Address _$AddressFromJson(Map<String, dynamic> json) => Address(
  streetLine: json['street_line'] as String,
  city: json['city'] as String,
  postCode: json['post_code'] as String?,
);

Map<String, dynamic> _$AddressToJson(Address instance) => <String, dynamic>{
  'street_line': instance.streetLine,
  'city': instance.city,
  'post_code': ?instance.postCode,
};
