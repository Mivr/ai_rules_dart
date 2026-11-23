/// Entrypoint binary for summarizing repeat results into `dart-sol.json`.
library;

import 'dart:io';

import 'package:perf/summarize_cli.dart';

void main(List<String> args) {
  exit(runSummarizeCli(args));
}
