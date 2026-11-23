import 'package:tri_c/tri_c.dart';

String triB(int n) => n <= 0 ? 'tri_b' : 'tri_b -> ' + triC(n - 1);
