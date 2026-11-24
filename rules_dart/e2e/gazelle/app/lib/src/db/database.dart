import 'package:drift/drift.dart';

part 'database.g.dart';

class Notes extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get author => integer()();
  TextColumn get body => text().withLength(min: 1, max: 280)();
  DateTimeColumn get created => dateTime()();
}

@DriftDatabase(tables: [Notes])
class NotesDatabase extends _$NotesDatabase {
  NotesDatabase(super.e);

  @override
  int get schemaVersion => 1;

  Future<List<Note>> byAuthor(int author) =>
      (select(notes)..where((n) => n.author.equals(author))).get();
}
