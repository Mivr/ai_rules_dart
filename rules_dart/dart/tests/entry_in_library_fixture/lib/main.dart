import 'dart:io';

import 'package:entry_in_library_fixture/src/greeting.dart';
import 'package:path/path.dart' as p;

void main() {
  stdout.writeln(greeting(p.basename('/stock/layout')));
  stdout.writeln(StackTrace.current.toString().split('\n').first);
}
