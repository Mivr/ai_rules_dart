/// A test importing `dart:mirrors`, which Flutter does not have.
library;

import 'dart:mirrors';

void main() {
  assert(currentMirrorSystem != null);
}
