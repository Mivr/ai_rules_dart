import 'package:clock/fork_marker.dart';
import 'package:fake_async/fake_async.dart';
import 'package:greet/greet.dart';

void main() {
  // The hosted fake_async runs on the overriding fork of clock.
  if (forkedFrom != 'third_party/clock') throw StateError(forkedFrom);
  var ticks = 0;
  fakeAsync((async) {
    Future<void>.delayed(const Duration(seconds: 1), () => ticks++);
    async.elapse(const Duration(seconds: 2));
  });
  if (ticks != 1) throw StateError('ticks: $ticks');
  final greeting = greet('path');
  if (greeting != 'hello/path') throw StateError(greeting);
  print('$greeting, $ticks tick');
}
