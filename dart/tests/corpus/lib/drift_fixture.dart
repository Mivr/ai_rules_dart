import 'package:drift/drift.dart';

part 'drift_fixture.g.dart';

/// A corpus table.
class CorpusItems extends Table {
  /// The auto-incrementing primary key.
  IntColumn get id => integer().autoIncrement()();

  /// The item name.
  TextColumn get name => text()();
}

/// A corpus database.
@DriftDatabase(tables: [CorpusItems])
class CorpusDatabase extends _$CorpusDatabase {
  /// Opens the database on [e].
  CorpusDatabase(super.e);

  @override
  int get schemaVersion => 1;
}
