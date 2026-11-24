import 'package:built_collection/built_collection.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'book.g.dart';

abstract class Book implements Built<Book, BookBuilder> {
  static Serializer<Book> get serializer => _$bookSerializer;

  String get title;
  BuiltList<String> get authors;
  int? get pages;
  Genre get genre;

  Book._();
  factory Book([void Function(BookBuilder) updates]) = _$Book;
}

class Genre extends EnumClass {
  static Serializer<Genre> get serializer => _$genreSerializer;

  static const Genre fiction = _$fiction;
  static const Genre science = _$science;

  const Genre._(super.name);

  static BuiltSet<Genre> get values => _$values;
  static Genre valueOf(String name) => _$valueOf(name);
}
