import 'package:cycle_b/cycle_b.dart';

String getCycleA() => 'CycleA->' + getCycleBFromA();
String getCycleAFromB() => 'A';
