/// Entrypoint binary for running speed-of-light repeats.
library;

import 'dart:io';

import 'package:perf/incremental_driver.dart';
import 'package:perf/runner_cli.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == incrementalDriverFlag) {
    await runIncrementalDriver(args.skip(1).toList());
    return;
  }
  exit(runRunnerCli(args));
}
