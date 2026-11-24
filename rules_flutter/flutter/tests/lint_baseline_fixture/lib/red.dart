/// Red path library with one unbaselined avoid_print violation.
library;

/// Emits one avoid_print diagnostic.
void triggerPrint() {
  print('red');
}
