/// Entrypoint that verifies runtime assertions are enabled in compiled AOT
/// executables and snapshots.
void main(List<String> args) {
  var assertsEnabled = false;
  assert(() {
    assertsEnabled = true;
    return true;
  }());
  if (!assertsEnabled) {
    throw StateError('expected assertions to be enabled at runtime');
  }
  assert(args.isEmpty, 'failing_assert_triggered');
}
