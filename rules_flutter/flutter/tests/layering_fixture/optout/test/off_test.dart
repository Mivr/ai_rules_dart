/// A test importing `package:leaf`, which only `mid` depends on, in a package
/// that opts out of the layering check.
library;

import 'package:leaf/leaf.dart';
import 'package:mid/mid.dart';

void main() {
  assert(leaf + mid > 0);
}
