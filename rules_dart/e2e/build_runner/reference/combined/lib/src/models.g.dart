// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: type=lint, unused_element

// Combined package: generated, do not edit.

part of 'models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Note _$NoteFromJson(Map json) =>
    $checkedCreate('_Note', json, ($checkedConvert) {
      final val = _Note(
        id: $checkedConvert('id', (v) => v as String),
        text: $checkedConvert('text', (v) => v as String),
        labels: $checkedConvert(
          'labels',
          (v) =>
              (v as List<dynamic>?)?.map((e) => e as String).toList() ??
              const <String>[],
        ),
        pinnedAt: $checkedConvert(
          'pinnedAt',
          (v) => v == null ? null : DateTime.parse(v as String),
        ),
      );
      return val;
    });

Map<String, dynamic> _$NoteToJson(_Note instance) => <String, dynamic>{
  'id': instance.id,
  'text': instance.text,
  'labels': instance.labels,
  'pinnedAt': instance.pinnedAt?.toIso8601String(),
};

NoteCreated _$NoteCreatedFromJson(Map json) =>
    $checkedCreate('NoteCreated', json, ($checkedConvert) {
      final val = NoteCreated(
        $checkedConvert(
          'note',
          (v) => Note.fromJson(Map<String, dynamic>.from(v as Map)),
        ),
        $type: $checkedConvert('runtimeType', (v) => v as String?),
      );
      return val;
    }, fieldKeyMap: const {r'$type': 'runtimeType'});

Map<String, dynamic> _$NoteCreatedToJson(NoteCreated instance) =>
    <String, dynamic>{'note': instance.note, 'runtimeType': instance.$type};

NoteDeleted _$NoteDeletedFromJson(Map json) =>
    $checkedCreate('NoteDeleted', json, ($checkedConvert) {
      final val = NoteDeleted(
        $checkedConvert('id', (v) => v as String),
        $type: $checkedConvert('runtimeType', (v) => v as String?),
      );
      return val;
    }, fieldKeyMap: const {r'$type': 'runtimeType'});

Map<String, dynamic> _$NoteDeletedToJson(NoteDeleted instance) =>
    <String, dynamic>{'id': instance.id, 'runtimeType': instance.$type};
