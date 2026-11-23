import 'package:tri_a/tri_a.dart';
import 'package:tri_b/tri_b.dart';
import 'package:tri_c/tri_c.dart';

void main() {
  final resA = triA(3);
  if (!resA.contains('tri_c')) {
    throw StateError('Expected triA(3) to reach tri_c, got: $resA');
  }
  final resB = triB(2);
  if (!resB.contains('tri_a')) {
    throw StateError('Expected triB(2) to reach tri_a, got: $resB');
  }
  final resC = triC(2);
  if (!resC.contains('tri_b')) {
    throw StateError('Expected triC(2) to reach tri_b, got: $resC');
  }
}
