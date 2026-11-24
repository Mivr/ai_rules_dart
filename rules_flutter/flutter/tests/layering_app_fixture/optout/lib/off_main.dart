/// An entrypoint importing `package:leaf` without declaring it; the package
/// opts out of the layering check.
library;

import 'package:leaf/leaf.dart';
import 'package:mid/mid.dart';

void main() {
  assert(leaf + mid > 0);
}
