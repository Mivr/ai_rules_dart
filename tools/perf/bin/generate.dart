/// Entrypoint binary for monorepo workspace generator.
library;

import 'dart:io';

import 'package:perf/generator.dart';

void main(List<String> args) {
  var targetLoc = 500000;
  var seed = 1;
  String? rulesDart;
  String? out;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--target-loc=')) {
      targetLoc = int.parse(arg.substring('--target-loc='.length));
    } else if (arg == '--target-loc' && i + 1 < args.length) {
      targetLoc = int.parse(args[++i]);
    } else if (arg.startsWith('--seed=')) {
      seed = int.parse(arg.substring('--seed='.length));
    } else if (arg == '--seed' && i + 1 < args.length) {
      seed = int.parse(args[++i]);
    } else if (arg.startsWith('--rules-dart=')) {
      rulesDart = arg.substring('--rules-dart='.length);
    } else if (arg == '--rules-dart' && i + 1 < args.length) {
      rulesDart = args[++i];
    } else if (arg.startsWith('--out=')) {
      out = arg.substring('--out='.length);
    } else if (arg == '--out' && i + 1 < args.length) {
      out = args[++i];
    }
  }

  if (rulesDart == null || out == null) {
    stderr.writeln(
      'Usage: generate --target-loc=<loc> --seed=<seed> --rules-dart=<path> --out=<path>',
    );
    exit(1);
  }

  final options = GeneratorOptions(
    targetLoc: targetLoc,
    seed: seed,
    rulesDartPath: rulesDart,
    outputPath: out,
  );

  generateWorkspace(options);
  stdout.writeln('Workspace generated successfully at $out');
}
