import 'package:dio/dio.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:retrofit/retrofit.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'models.dart';

part 'api.g.dart';

@JsonSerializable()
class NotePage {
  NotePage({required this.notes, this.next});

  factory NotePage.fromJson(Map<String, dynamic> json) =>
      _$NotePageFromJson(json);

  final List<Note> notes;
  final String? next;

  Map<String, dynamic> toJson() => _$NotePageToJson(this);
}

@RestApi(baseUrl: 'https://example.invalid/')
abstract class NotesApi {
  factory NotesApi(Dio dio, {String? baseUrl}) = _NotesApi;

  @GET('/notes')
  Future<NotePage> list(@Query('cursor') String? cursor);

  @PUT('/notes/{id}')
  Future<Note> put(@Path() String id, @Body() Note note);
}

@riverpod
NotesApi notesApi(Ref ref) => NotesApi(Dio());

@riverpod
Future<NotePage> firstPage(Ref ref) => ref.watch(notesApiProvider).list(null);
