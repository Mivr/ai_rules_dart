import 'package:tri_b/tri_b.dart';

String triA(int n) => n <= 0 ? 'tri_a' : 'tri_a -> ' + triB(n - 1);
