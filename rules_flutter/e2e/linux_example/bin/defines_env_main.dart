/// A kernel-mode `dart_binary` with `defines` over `//defines_env`.
library;

import 'dart:io';

import 'package:defines_env/defines_env.dart';

void main() {
  stdout.writeln(defcfgSummary);
}
