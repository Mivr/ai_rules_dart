import 'package:cycle_a/cycle_a.dart';

String getCycleB() => 'CycleB->' + getCycleAFromB();
String getCycleBFromA() => 'B';
