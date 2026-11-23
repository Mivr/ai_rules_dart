import 'package:tri_a/tri_a.dart';

String triC(int n) => n <= 0 ? 'tri_c' : 'tri_c -> ' + triA(n - 1);
