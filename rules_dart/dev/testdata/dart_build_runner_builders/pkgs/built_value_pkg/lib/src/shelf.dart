import 'package:built_collection/built_collection.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

import 'book.dart';

part 'shelf.g.dart';

abstract class Shelf implements Built<Shelf, ShelfBuilder> {
  static Serializer<Shelf> get serializer => _$shelfSerializer;

  String get label;
  BuiltMap<String, Book> get byIsbn;

  Shelf._();
  factory Shelf([void Function(ShelfBuilder) updates]) = _$Shelf;
}
