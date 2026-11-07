/// CLI entry point for repository contents cache checks.
///
/// Usage:
///   cd tools && bazel run //repo_contents_cache:check -- <ws> <repo>...
///   cd tools && bazel run //repo_contents_cache:check -- <ws> --scanner
library;

import 'dart:io';

import 'package:repo_contents_cache/repo_contents_cache.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: check -- <ws> <repo>... [--probe <repo>] [--scanner]',
    );
    exitCode = 1;
    return;
  }

  String? wsDir;
  final repos = <String>[];
  final probes = <String>[];
  var checkScanner = false;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--scanner' ||
        arg == '--check-scanner' ||
        arg == '--mode=scanner') {
      checkScanner = true;
    } else if (arg.startsWith('--probe=')) {
      probes.add(arg.substring('--probe='.length));
    } else if (arg == '--probe' && i + 1 < args.length) {
      probes.add(args[++i]);
    } else if (arg.startsWith('-')) {
      stderr.writeln('Unknown option: $arg');
      exitCode = 1;
      return;
    } else if (wsDir == null) {
      wsDir = arg;
    } else if (arg == 'probe') {
      probes.add(arg);
    } else {
      repos.add(arg);
    }
  }

  if (wsDir == null) {
    stderr.writeln('Missing workspace argument.');
    exitCode = 1;
    return;
  }

  if (repos.isEmpty && probes.isEmpty && !checkScanner) {
    stderr.writeln('No repositories or --scanner specified to check.');
    exitCode = 1;
    return;
  }

  try {
    runCheck(
      CheckConfig(
        workspaceDir: wsDir,
        reproducibleRepos: repos,
        probeRepos: probes,
        checkScanner: checkScanner,
      ),
    );
  } on StateError catch (e) {
    stderr.writeln('FAILURE: ${e.message}');
    exitCode = 1;
  }
}
