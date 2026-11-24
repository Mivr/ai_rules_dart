/// Entry point of the bench harness; see `package:perf/bench.dart`.
library;

import 'dart:io';

import 'package:perf/bench.dart';

Future<void> main(List<String> args) async {
  exitCode = await bench(args);
}
