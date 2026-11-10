/// Entrypoint binary measuring how Dart rule costs grow with library count.
library;

import 'dart:io';

import 'package:perf/scale_cli.dart';

void main(List<String> args) {
  exit(runScaleCli(args));
}
