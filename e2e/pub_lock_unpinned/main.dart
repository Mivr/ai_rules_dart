import 'package:collection/collection.dart';

void main() {
  print([1, 2, 3].firstWhereOrNull((n) => n.isEven));
}
