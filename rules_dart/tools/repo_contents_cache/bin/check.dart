/// CLI entry point for repository contents cache checks.
///
/// Usage:
///   `cd tools && bazel run //repo_contents_cache:check -- <ws> <repo>...`
///   `cd tools && bazel run //repo_contents_cache:check -- <ws> --scanner`
library;

import 'dart:io';

import 'package:repo_contents_cache/repo_contents_cache.dart';

/// Runs repository contents cache checks from CLI [args].
void main(List<String> args) {
  final CheckConfig config;
  try {
    config = parseCheckArgs(args);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
    return;
  }

  try {
    runCheck(config);
  } on CheckFailure catch (e) {
    stderr.writeln('FAILURE: ${e.message}');
    exitCode = 1;
  }
}
