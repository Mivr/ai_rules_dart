/// The twin of the failing tests: it imports `dart:ui`, which Flutter has.
library;

import 'package:mirrors_twin/mirrors_twin.dart';

void main() {
  assert(twin != null);
}
