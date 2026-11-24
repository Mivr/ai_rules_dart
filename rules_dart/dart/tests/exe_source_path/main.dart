import 'stub.dart' if (dart.library.mirrors) 'impl.dart';

void main() {
  print('$name ${const bool.fromEnvironment('dart.library.mirrors')}');
}
