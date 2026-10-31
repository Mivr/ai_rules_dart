/// Entrypoint binary for monorepo workspace generator.
library;

import 'dart:io';

import 'package:perf/generator.dart';

(String?, String?) _extractFlagAndValue(String arg, List<String> args, int i) {
  if (arg.startsWith('--')) {
    final eq = arg.indexOf('=');
    if (eq != -1) {
      return (arg.substring(2, eq), arg.substring(eq + 1));
    }
    final key = arg.substring(2);
    final val = i + 1 < args.length ? args[i + 1] : null;
    return (key, val);
  }
  return (null, null);
}

void main(List<String> args) {
  var targetLoc = 500000;
  var seed = 1;
  String? rulesDart;
  String? out;

  for (var i = 0; i < args.length; i++) {
    final (flag, val) = _extractFlagAndValue(args[i], args, i);
    if (flag == null) continue;
    if (val != null && !args[i].contains('=')) i++;

    switch (flag) {
      case 'target-loc':
      case 'target_loc':
      case 'loc':
        if (val != null) targetLoc = int.parse(val);
      case 'seed':
        if (val != null) seed = int.parse(val);
      case 'rules-dart':
      case 'rules_dart':
      case 'rules-head':
      case 'rules_head':
        rulesDart = val;
      case 'out':
      case 'output':
        out = val;
    }
  }

  if (rulesDart == null || out == null || targetLoc <= 0) {
    stderr.writeln(
      'Usage: generate --target-loc=<positive-int> --seed=<int> '
      '--rules-dart=<path> --out=<path>',
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
