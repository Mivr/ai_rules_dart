/// Entrypoint binary for monorepo workspace generator.
library;

import 'dart:io';

import 'package:perf/cli_args.dart';
import 'package:perf/generator.dart';

void main(List<String> args) {
  final flags = parseCliFlags(args);
  final targetLoc = intFlagValue(flags, const [
    'target-loc',
    'target_loc',
    'loc',
  ], defaultValue: 500000);
  final seed = intFlagValue(flags, const ['seed'], defaultValue: 1);
  final layers = intFlagValue(flags, const ['layers'], defaultValue: 8);
  final fanout = intFlagValue(flags, const ['fanout'], defaultValue: 4);
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
      layers == null ||
      layers < 2 ||
      fanout == null ||
      fanout < 1) {
    stderr.writeln(
      'Usage: generate --target-loc=<positive-int> --seed=<int> '
      '--rules-dart=<path> --out=<path>',
    );
    exit(1);
  }

  final rulesDart = resolveCliPath(rawRulesDart);
  final out = resolveCliPath(rawOut);
  if (!Directory(rulesDart).existsSync()) {
    stderr.writeln('rules_dart directory does not exist: $rulesDart');
    exit(1);
  }

  final options = GeneratorOptions(
    targetLoc: targetLoc,
    seed: seed,
    rulesDartPath: rulesDart,
    outputPath: out,
    layers: layers,
    fanout: fanout,
  );

  generateWorkspace(options);
  stdout.writeln('Workspace generated successfully at $out');
}
