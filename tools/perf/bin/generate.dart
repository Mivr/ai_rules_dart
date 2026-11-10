/// Entrypoint binary for monorepo workspace generator.
library;

import 'dart:io';

import 'package:perf/generate_cli.dart';

void main(List<String> args) {
  exit(runGenerateCli(args));
}
