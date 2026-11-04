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
    final String pkg = buildStep.inputId.package;
    final String pubspec = await buildStep.readAsString(
      AssetId(pkg, 'pubspec.yaml'),
    );
    final String options = await buildStep.readAsString(
      AssetId(pkg, 'analysis_options.yaml'),
    );
    final String normPubspec = pubspec.replaceAll('\r\n', '\n').trim();
    final String normOptions = options.replaceAll('\r\n', '\n').trim();
    await buildStep.writeAsString(
      buildStep.allowedOutputs.first,
      '// pubspec=${normPubspec.replaceAll('\n', '|')}\n'
      '// options=${normOptions.replaceAll('\n', '|')}\n',
    );
  }
}

Future<void> main(List<String> args) =>
    shimMain(args, (_) => _RootConfigEchoBuilder());
