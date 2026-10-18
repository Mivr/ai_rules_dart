import 'package:defines_fixture/comma_lib.dart';

/// Fails unless `defines` (including comma-containing defines) reached the
/// build-time kernel compile.
///
/// `dart_test` compiles `main` to a kernel during the build and the launcher
/// only runs it, so a declaration that misses that compile cannot be supplied
/// later — the VM's own `-D` has no effect on an already-compiled kernel.
void main() {
  const channel = String.fromEnvironment('CHANNEL', defaultValue: 'UNSET');
  if (channel != 'runtime') {
    throw StateError('expected CHANNEL=runtime, got "$channel"');
  }
  const commaVal = String.fromEnvironment('COMMA_VAL', defaultValue: 'UNSET');
  if (commaVal != 'a,b') {
    throw StateError('expected COMMA_VAL=a,b, got "$commaVal"');
  }
  if (libCommaVal != 'a,b') {
    throw StateError('expected libCommaVal=a,b, got "$libCommaVal"');
  }
}
