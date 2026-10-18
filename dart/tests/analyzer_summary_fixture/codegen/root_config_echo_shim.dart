import 'dart:async';

import 'package:build/build.dart';
import 'package:rules_dart_ext/worker_entry.dart';

class _RootConfigEchoBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart', '.agg.dart'],
    '.drift': ['.drift.dart'],
    '.yaml': ['.agg.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final pkg = buildStep.inputId.package;
    final pubspec = await buildStep.readAsString(AssetId(pkg, 'pubspec.yaml'));
    final options = await buildStep.readAsString(
      AssetId(pkg, 'analysis_options.yaml'),
    );
    await buildStep.writeAsString(
      buildStep.allowedOutputs.first,
      '// pubspec=${pubspec.trim().replaceAll('\n', '|')}\n'
      '// options=${options.trim().replaceAll('\n', '|')}\n',
    );
  }
}

Future<void> main(List<String> args) =>
    shimMain(args, (_) => _RootConfigEchoBuilder());
