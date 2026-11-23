// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'shelf.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

Serializer<Shelf> _$shelfSerializer = _$ShelfSerializer();

class _$ShelfSerializer implements StructuredSerializer<Shelf> {
  @override
  final Iterable<Type> types = const [Shelf, _$Shelf];
  @override
  final String wireName = 'Shelf';

  @override
  Iterable<Object?> serialize(
    Serializers serializers,
    Shelf object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = <Object?>[
      'label',
      serializers.serialize(
        object.label,
        specifiedType: const FullType(String),
      ),
      'byIsbn',
      serializers.serialize(
        object.byIsbn,
        specifiedType: const FullType(BuiltMap, const [
          const FullType(String),
          const FullType(Book),
        ]),
      ),
    ];

    return result;
  }

  @override
  Shelf deserialize(
    Serializers serializers,
    Iterable<Object?> serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = ShelfBuilder();

    final iterator = serialized.iterator;
    while (iterator.moveNext()) {
      final key = iterator.current! as String;
      iterator.moveNext();
      final Object? value = iterator.current;
      switch (key) {
        case 'label':
          result.label =
              serializers.deserialize(
                    value,
                    specifiedType: const FullType(String),
                  )!
                  as String;
          break;
        case 'byIsbn':
          result.byIsbn.replace(
            serializers.deserialize(
              value,
              specifiedType: const FullType(BuiltMap, const [
                const FullType(String),
                const FullType(Book),
              ]),
            )!,
          );
          break;
      }
    }

    return result.build();
  }
}

class _$Shelf extends Shelf {
  @override
  final String label;
  @override
  final BuiltMap<String, Book> byIsbn;

  factory _$Shelf([void Function(ShelfBuilder)? updates]) =>
      (ShelfBuilder()..update(updates))._build();

  _$Shelf._({required this.label, required this.byIsbn}) : super._();
  @override
  Shelf rebuild(void Function(ShelfBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  ShelfBuilder toBuilder() => ShelfBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is Shelf && label == other.label && byIsbn == other.byIsbn;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, label.hashCode);
    _$hash = $jc(_$hash, byIsbn.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'Shelf')
          ..add('label', label)
          ..add('byIsbn', byIsbn))
        .toString();
  }
}

class ShelfBuilder implements Builder<Shelf, ShelfBuilder> {
  _$Shelf? _$v;

  String? _label;
  String? get label => _$this._label;
  set label(String? label) => _$this._label = label;

  MapBuilder<String, Book>? _byIsbn;
  MapBuilder<String, Book> get byIsbn =>
      _$this._byIsbn ??= MapBuilder<String, Book>();
  set byIsbn(MapBuilder<String, Book>? byIsbn) => _$this._byIsbn = byIsbn;

  ShelfBuilder();

  ShelfBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _label = $v.label;
      _byIsbn = $v.byIsbn.toBuilder();
      _$v = null;
    }
    return this;
  }

  @override
  void replace(Shelf other) {
    _$v = other as _$Shelf;
  }

  @override
  void update(void Function(ShelfBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  Shelf build() => _build();

  _$Shelf _build() {
    _$Shelf _$result;
    try {
      _$result =
          _$v ??
          _$Shelf._(
            label: BuiltValueNullFieldError.checkNotNull(
              label,
              r'Shelf',
              'label',
            ),
            byIsbn: byIsbn.build(),
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'byIsbn';
        byIsbn.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(r'Shelf', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
