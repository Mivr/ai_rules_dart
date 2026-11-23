import 'dart:io';

import 'package:c/c.dart';

void main() {
  final got = greetBoth('/x/a.txt', 'b.txt');
  if (got != 'Hello, a.txt! Hello, b.txt!') {
    stderr.writeln('c did not greet through b and a: $got');
    exit(1);
  }
}
