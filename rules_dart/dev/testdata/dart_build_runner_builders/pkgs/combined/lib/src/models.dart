import 'package:freezed_annotation/freezed_annotation.dart';

part 'models.freezed.dart';
part 'models.g.dart';

@freezed
abstract class Note with _$Note {
  const factory Note({
    required String id,
    required String text,
    @Default(<String>[]) List<String> labels,
    DateTime? pinnedAt,
  }) = _Note;

  factory Note.fromJson(Map<String, dynamic> json) => _$NoteFromJson(json);
}

@freezed
sealed class Event with _$Event {
  const factory Event.created(Note note) = NoteCreated;
  const factory Event.deleted(String id) = NoteDeleted;

  factory Event.fromJson(Map<String, dynamic> json) => _$EventFromJson(json);
}
