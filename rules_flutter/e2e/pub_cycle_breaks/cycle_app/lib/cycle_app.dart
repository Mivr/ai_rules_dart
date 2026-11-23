/// The app side of the cycle-break fixture.
library;

import 'package:cycle_a/cycle_a.dart';
import 'package:cycle_b/cycle_b.dart';

/// Reads both spokes the app depends on.
String cycleApp() => '${cycleA()}/${cycleB()}';
