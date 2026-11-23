abstract class Clock {
  DateTime now();
}

class Item {
  Item(this.id, this.name);
  final int id;
  final String name;
}

abstract class Repository<T> {
  Future<List<T>> fetchAll({int limit = 20});
  Future<T?> byId(int id);
  Stream<T> watch(String query);
  Future<void> save(T value);
  int get count;
  set cacheSize(int value);
}
