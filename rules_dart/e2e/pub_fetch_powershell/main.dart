import 'package:characters/characters.dart';
import 'package:meta/meta.dart';

@immutable
final class Greeting {
  const Greeting(this.name);
  final String name;
}

void main() {
  const greeting = Greeting('abc');
  final chars = greeting.name.characters;
  print('Length: ${chars.length}');
}
