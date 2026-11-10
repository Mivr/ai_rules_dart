/// Command-line driver for `generate`: writes a layered benchmark workspace.
library;

import 'dart:io';

import 'cli_args.dart';
import 'generator.dart';
import 'library_shape.dart';

/// Runs the `generate` CLI and returns its exit code.
int runGenerateCli(List<String> args) {
  final flags = parseCliFlags(args);
  final targetLoc = intFlagValue(flags, const [
    'target-loc',
    'target_loc',
    'loc',
  ], defaultValue: 500000);
  final seed = intFlagValue(flags, const ['seed'], defaultValue: 1);
  final resolution = resolveShapeFlags(flags);
  final shape = resolution.shape;
  final rawRulesDart = lastFlagValue(flags, const [
    'rules-dart',
    'rules_dart',
    'rules-head',
    'rules_head',
  ]);
  final rawOut = lastFlagValue(flags, const [
    'out',
    'output',
    'workspace',
    'ws',
  ]);

  if (rawRulesDart == null ||
      rawRulesDart.isEmpty ||
      rawOut == null ||
      rawOut.isEmpty ||
      targetLoc == null ||
      targetLoc <= 0 ||
      seed == null ||
      shape == null) {
    final error = resolution.error;
    if (error != null) stderr.writeln(error);
    stderr.writeln(
      'Usage: generate --target-loc=<positive-int> --seed=<int> '
      '--rules-dart=<path> --out=<path> [--libraries=<n>]',
    );
    return 1;
  }

  final rulesDart = resolveCliPath(rawRulesDart);
  final out = resolveCliPath(rawOut);
  if (!Directory(rulesDart).existsSync()) {
    stderr.writeln('rules_dart directory does not exist: $rulesDart');
    return 1;
  }

  final options = GeneratorOptions(
    targetLoc: targetLoc,
    seed: seed,
    rulesDartPath: rulesDart,
    outputPath: out,
    layers: shape.layers,
    fanout: shape.fanout,
  );

  generateWorkspace(options);
  stdout.writeln('Workspace generated successfully at $out');
  return 0;
}
