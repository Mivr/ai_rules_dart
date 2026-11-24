// Imports `leaf`, which `mid` depends on. Whether that is allowed depends on
// whether the target builds this file lists `leaf` in its own `deps`.
import 'package:leaf/leaf.dart';
import 'package:mid/mid.dart';

void main() => print('$leaf $mid');
