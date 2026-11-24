// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'address.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Address _$AddressFromJson(Map<String, dynamic> json) => Address(
  streetLine: json['street-line'] as String,
  city: json['city'] as String,
  postCode: json['post-code'] as String?,
);

Map<String, dynamic> _$AddressToJson(Address instance) => <String, dynamic>{
  'street-line': instance.streetLine,
  'city': instance.city,
  'post-code': instance.postCode,
};
