import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'providers.g.dart';

@riverpod
String greeting(Ref ref, {required String name}) => 'Hello $name';

@Riverpod(keepAlive: true)
Future<int> answer(Ref ref) async => 42;

@riverpod
class Counter extends _$Counter {
  @override
  int build(int start) => start;

  void increment() => state++;
}

@riverpod
Stream<List<String>> feed(Ref ref) async* {
  yield const [];
}
