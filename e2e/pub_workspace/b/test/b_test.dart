import 'dart:io';

import 'package:b/b.dart';

void main() {
  final got = greetFile('/x/y/dart.txt');
  if (got != 'Hello, dart.txt!') {
    stderr.writeln('b did not greet through a: $got');
    exit(1);
  }
}
