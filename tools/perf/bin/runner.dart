/// Entrypoint binary for running speed-of-light repeats.
library;

import 'dart:io';

import 'package:perf/runner_cli.dart';

void main(List<String> args) {
  exit(runRunnerCli(args));
}
