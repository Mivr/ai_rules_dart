/// Green control library with two avoid_print violations baselined at two.
library;

/// Emits two avoid_print diagnostics.
void triggerPrint() {
  print('green 1');
  print('green 2');
}
