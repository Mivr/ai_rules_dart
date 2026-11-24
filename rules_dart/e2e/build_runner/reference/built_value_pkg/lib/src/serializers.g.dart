// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'serializers.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

Serializers _$serializers =
    (Serializers().toBuilder()
          ..add(Book.serializer)
          ..add(Genre.serializer)
          ..add(Shelf.serializer)
          ..addBuilderFactory(
            const FullType(BuiltList, const [const FullType(String)]),
            () => ListBuilder<String>(),
          )
          ..addBuilderFactory(
            const FullType(BuiltMap, const [
              const FullType(String),
              const FullType(Book),
            ]),
            () => MapBuilder<String, Book>(),
          ))
        .build();

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
