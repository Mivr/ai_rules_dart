// The entrypoint belongs to no package, so the compiler names it by a URI of
// its own choosing, and the binary keeps that URI. The relative import reaches
// out of `bin/` the way an entrypoint often does.
import '../lib/where.dart';

void main() {
  print('product=${const bool.fromEnvironment('dart.vm.product')}');
  print('frame=${callerFrame()}');
}
