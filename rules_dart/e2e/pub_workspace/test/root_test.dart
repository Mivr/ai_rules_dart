import 'dart:io';

import 'package:pub_workspace_root/pub_workspace_root.dart';

void main() {
  final got = rootGreeting();
  if (got != 'Hello, root.txt! Hello, workspace.txt!') {
    stderr.writeln('the root did not greet through c: $got');
    exit(1);
  }
}
