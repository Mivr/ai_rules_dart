// The `leaf` import is in a conditional alternative: the check reads every
// alternative, whichever one the build configuration would select.
import 'package:mid/mid.dart' if (dart.library.io) 'package:leaf/leaf.dart';

void main() => print('conditional');
