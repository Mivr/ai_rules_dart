// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: type=lint, unused_element

// Combined package: generated, do not edit.

part of 'api.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

NotePage _$NotePageFromJson(Map json) =>
    $checkedCreate('NotePage', json, ($checkedConvert) {
      final val = NotePage(
        notes: $checkedConvert(
          'notes',
          (v) => (v as List<dynamic>)
              .map((e) => Note.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList(),
        ),
        next: $checkedConvert('next', (v) => v as String?),
      );
      return val;
    });

Map<String, dynamic> _$NotePageToJson(NotePage instance) => <String, dynamic>{
  'notes': instance.notes,
  'next': instance.next,
};

// dart format off

// **************************************************************************
// RetrofitGenerator
// **************************************************************************

// ignore_for_file: type=lint
// ignore_for_file: unnecessary_brace_in_string_interps,no_leading_underscores_for_local_identifiers,unused_element,unnecessary_string_interpolations,unused_element_parameter,avoid_unused_constructor_parameters,unreachable_from_main,avoid_redundant_argument_values

class _NotesApi implements NotesApi {
  _NotesApi(this._dio, {this.baseUrl, this.errorLogger}) {
    baseUrl ??= 'https://example.invalid/';
  }

  final Dio _dio;

  String? baseUrl;

  final ParseErrorLogger? errorLogger;

  @override
  Future<NotePage> list(String? cursor) async {
    final _extra = <String, dynamic>{};
    final queryParameters = <String, dynamic>{r'cursor': cursor};
    queryParameters.removeWhere((k, v) => v == null);
    final _headers = <String, dynamic>{};
    const Map<String, dynamic>? _data = null;
    final _options = _setStreamType<NotePage>(
      Options(method: 'GET', headers: _headers, extra: _extra)
          .compose(
            _dio.options,
            '/notes',
            queryParameters: queryParameters,
            data: _data,
          )
          .copyWith(baseUrl: _combineBaseUrls(_dio.options.baseUrl, baseUrl)),
    );
    final _result = await _dio.fetch<Map<String, dynamic>>(_options);
    late NotePage _value;
    try {
      _value = NotePage.fromJson(_result.data!);
    } on Object catch (e, s) {
      errorLogger?.logError(e, s, _options, response: _result);
      rethrow;
    }
    return _value;
  }

  @override
  Future<Note> put(String id, Note note) async {
    final _extra = <String, dynamic>{};
    final queryParameters = <String, dynamic>{};
    final _headers = <String, dynamic>{};
    final _data = <String, dynamic>{};
    _data.addAll(note.toJson());
    final _options = _setStreamType<Note>(
      Options(method: 'PUT', headers: _headers, extra: _extra)
          .compose(
            _dio.options,
            '/notes/${id}',
            queryParameters: queryParameters,
            data: _data,
          )
          .copyWith(baseUrl: _combineBaseUrls(_dio.options.baseUrl, baseUrl)),
    );
    final _result = await _dio.fetch<Map<String, dynamic>>(_options);
    late Note _value;
    try {
      _value = Note.fromJson(_result.data!);
    } on Object catch (e, s) {
      errorLogger?.logError(e, s, _options, response: _result);
      rethrow;
    }
    return _value;
  }

  RequestOptions _setStreamType<T>(RequestOptions requestOptions) {
    if (T != dynamic &&
        !(requestOptions.responseType == ResponseType.bytes ||
            requestOptions.responseType == ResponseType.stream)) {
      if (T == String) {
        requestOptions.responseType = ResponseType.plain;
      } else {
        requestOptions.responseType = ResponseType.json;
      }
    }
    return requestOptions;
  }

  String _combineBaseUrls(String dioBaseUrl, String? baseUrl) {
    if (baseUrl == null || baseUrl.trim().isEmpty) {
      return dioBaseUrl;
    }

    final url = Uri.parse(baseUrl);

    if (url.isAbsolute) {
      return url.toString();
    }

    return Uri.parse(dioBaseUrl).resolveUri(url).toString();
  }
}

// dart format on

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(notesApi)
final notesApiProvider = NotesApiProvider._();

final class NotesApiProvider
    extends $FunctionalProvider<NotesApi, NotesApi, NotesApi>
    with $Provider<NotesApi> {
  NotesApiProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'notesApiProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$notesApiHash();

  @$internal
  @override
  $ProviderElement<NotesApi> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  NotesApi create(Ref ref) {
    return notesApi(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(NotesApi value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<NotesApi>(value),
    );
  }
}

String _$notesApiHash() => r'c370fedc63f0472a761c99c7b1399006ceecf461';

@ProviderFor(firstPage)
final firstPageProvider = FirstPageProvider._();

final class FirstPageProvider
    extends
        $FunctionalProvider<AsyncValue<NotePage>, NotePage, FutureOr<NotePage>>
    with $FutureModifier<NotePage>, $FutureProvider<NotePage> {
  FirstPageProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'firstPageProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$firstPageHash();

  @$internal
  @override
  $FutureProviderElement<NotePage> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<NotePage> create(Ref ref) {
    return firstPage(ref);
  }
}

String _$firstPageHash() => r'54636d8bc9789f52b62bdb44ec72a04502cb721e';
