// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'book.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

const Genre _$fiction = const Genre._('fiction');
const Genre _$science = const Genre._('science');

Genre _$valueOf(String name) {
  switch (name) {
    case 'fiction':
      return _$fiction;
    case 'science':
      return _$science;
    default:
      throw ArgumentError(name);
  }
}

final BuiltSet<Genre> _$values = BuiltSet<Genre>(const <Genre>[
  _$fiction,
  _$science,
]);

Serializer<Book> _$bookSerializer = _$BookSerializer();
Serializer<Genre> _$genreSerializer = _$GenreSerializer();

class _$BookSerializer implements StructuredSerializer<Book> {
  @override
  final Iterable<Type> types = const [Book, _$Book];
  @override
  final String wireName = 'Book';

  @override
  Iterable<Object?> serialize(
    Serializers serializers,
    Book object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = <Object?>[
      'title',
      serializers.serialize(
        object.title,
        specifiedType: const FullType(String),
      ),
      'authors',
      serializers.serialize(
        object.authors,
        specifiedType: const FullType(BuiltList, const [
          const FullType(String),
        ]),
      ),
      'genre',
      serializers.serialize(object.genre, specifiedType: const FullType(Genre)),
    ];
    Object? value;
    value = object.pages;
    if (value != null) {
      result
        ..add('pages')
        ..add(serializers.serialize(value, specifiedType: const FullType(int)));
    }
    return result;
  }

  @override
  Book deserialize(
    Serializers serializers,
    Iterable<Object?> serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = BookBuilder();

    final iterator = serialized.iterator;
    while (iterator.moveNext()) {
      final key = iterator.current! as String;
      iterator.moveNext();
      final Object? value = iterator.current;
      switch (key) {
        case 'title':
          result.title =
              serializers.deserialize(
                    value,
                    specifiedType: const FullType(String),
                  )!
                  as String;
          break;
        case 'authors':
          result.authors.replace(
            serializers.deserialize(
                  value,
                  specifiedType: const FullType(BuiltList, const [
                    const FullType(String),
                  ]),
                )!
                as BuiltList<Object?>,
          );
          break;
        case 'pages':
          result.pages = serializers.deserialize(
            value,
            specifiedType: const FullType(int),
          ) as int?;
          break;
        case 'genre':
          result.genre =
              serializers.deserialize(
                    value,
                    specifiedType: const FullType(Genre),
                  )!
                  as Genre;
          break;
      }
    }

    return result.build();
  }
}

class _$GenreSerializer implements PrimitiveSerializer<Genre> {
  @override
  final Iterable<Type> types = const <Type>[Genre];
  @override
  final String wireName = 'Genre';

  @override
  Object serialize(
    Serializers serializers,
    Genre object, {
    FullType specifiedType = FullType.unspecified,
  }) => object.name;

  @override
  Genre deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) => Genre.valueOf(serialized as String);
}

class _$Book extends Book {
  @override
  final String title;
  @override
  final BuiltList<String> authors;
  @override
  final int? pages;
  @override
  final Genre genre;

  factory _$Book([void Function(BookBuilder)? updates]) =>
      (BookBuilder()..update(updates))._build();

  _$Book._({
    required this.title,
    required this.authors,
    this.pages,
    required this.genre,
  }) : super._();
  @override
  Book rebuild(void Function(BookBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  BookBuilder toBuilder() => BookBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is Book &&
        title == other.title &&
        authors == other.authors &&
        pages == other.pages &&
        genre == other.genre;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, title.hashCode);
    _$hash = $jc(_$hash, authors.hashCode);
    _$hash = $jc(_$hash, pages.hashCode);
    _$hash = $jc(_$hash, genre.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'Book')
          ..add('title', title)
          ..add('authors', authors)
          ..add('pages', pages)
          ..add('genre', genre))
        .toString();
  }
}

class BookBuilder implements Builder<Book, BookBuilder> {
  _$Book? _$v;

  String? _title;
  String? get title => _$this._title;
  set title(String? title) => _$this._title = title;

  ListBuilder<String>? _authors;
  ListBuilder<String> get authors => _$this._authors ??= ListBuilder<String>();
  set authors(ListBuilder<String>? authors) => _$this._authors = authors;

  int? _pages;
  int? get pages => _$this._pages;
  set pages(int? pages) => _$this._pages = pages;

  Genre? _genre;
  Genre? get genre => _$this._genre;
  set genre(Genre? genre) => _$this._genre = genre;

  BookBuilder();

  BookBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _title = $v.title;
      _authors = $v.authors.toBuilder();
      _pages = $v.pages;
      _genre = $v.genre;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(Book other) {
    _$v = other as _$Book;
  }

  @override
  void update(void Function(BookBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  Book build() => _build();

  _$Book _build() {
    _$Book _$result;
    try {
      _$result =
          _$v ??
          _$Book._(
            title: BuiltValueNullFieldError.checkNotNull(
              title,
              r'Book',
              'title',
            ),
            authors: authors.build(),
            pages: pages,
            genre: BuiltValueNullFieldError.checkNotNull(
              genre,
              r'Book',
              'genre',
            ),
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'authors';
        authors.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(r'Book', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
