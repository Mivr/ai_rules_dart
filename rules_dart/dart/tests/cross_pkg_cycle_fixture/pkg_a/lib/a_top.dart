import 'package:pkg_a/a_base.dart';
import 'package:pkg_b/b.dart';

String aTopTag() => 'a_top_tag';
String aTopValue() => 'a_top(${bValue()},${aBaseValue()})';
