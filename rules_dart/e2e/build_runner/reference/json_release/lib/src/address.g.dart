// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'address.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Address _$AddressFromJson(Map<String, dynamic> json) => Address(
  streetLine: json['StreetLine'] as String,
  city: json['City'] as String,
  postCode: json['PostCode'] as String?,
);

Map<String, dynamic> _$AddressToJson(Address instance) => <String, dynamic>{
  'StreetLine': instance.streetLine,
  'City': instance.city,
  'PostCode': ?instance.postCode,
};
