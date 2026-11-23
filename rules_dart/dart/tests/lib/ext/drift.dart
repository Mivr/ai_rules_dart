import 'package:drift/drift.dart';

part 'drift.g.dart';

/// A table the `drift_library` test generates a database for.
class Items extends Table {
  /// The row id.
  IntColumn get id => integer().autoIncrement()();
}

/// A database over [Items].
@DriftDatabase(tables: [Items])
class SubjectDatabase extends _$SubjectDatabase {
  /// Creates a database over [executor].
  SubjectDatabase(super.executor);

  @override
  int get schemaVersion => 1;
}
