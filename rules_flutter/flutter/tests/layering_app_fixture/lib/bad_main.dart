/// An entrypoint importing `package:leaf`, which only `mid` depends on.
library;

import 'package:layering_app_fixture/own.dart';
import 'package:leaf/leaf.dart';
import 'package:mid/mid.dart';

void main() {
  assert(leaf + mid + own > 0);
}
