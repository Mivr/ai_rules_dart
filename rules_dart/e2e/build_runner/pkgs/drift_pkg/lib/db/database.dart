import 'package:drift/drift.dart';

import 'converters.dart';

part 'database.g.dart';

class Todos extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text().withLength(min: 1, max: 64)();
  TextColumn get body => text().named('content').nullable()();
  IntColumn get category => integer().nullable().references(Categories, #id)();
  DateTimeColumn get due => dateTime().nullable()();
  BoolColumn get done => boolean().withDefault(const Constant(false))();
}

@DriftDatabase(
  tables: [Todos],
  include: {'tables.drift'},
  daos: [TodosDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 2;
}

@DriftAccessor(tables: [Todos])
class TodosDao extends DatabaseAccessor<AppDatabase> with _$TodosDaoMixin {
  TodosDao(super.db);

  Future<List<Todo>> open() =>
      (select(todos)..where((t) => t.done.equals(false))).get();
}
