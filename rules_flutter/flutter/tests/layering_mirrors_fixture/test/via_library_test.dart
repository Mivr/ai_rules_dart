/// A test whose library below exports `dart:mirrors`.
library;

import 'package:mirrors_export/mirrors_export.dart';

void main() {
  assert(reflected != null);
}
