// Keeps the library routed here, and writes which `Factor`s the program
// constructs, from the recorded uses, as a data asset.
import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:data_assets/data_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:record_use/record_use.dart';

const _factor = Class('Factor', Library('package:native_link/native_link.dart'));

Future<void> main(List<String> args) async {
  await link(args, (input, output) async {
    output.assets.code.addAll(input.assets.code);
    // A CLI build takes code assets only.
    if (!input.config.buildDataAssets) return;
    final factors = <int>{};
    for (final use in input.recordedUses?.instances[_factor] ?? const []) {
      if (use case InstanceConstantReference(
        instanceConstant: InstanceConstant(
          fields: {'value': IntConstant(value: final value)},
        ),
      )) {
        factors.add(value);
      }
    }
    final file = input.outputDirectory.resolve('factors.json');
    File.fromUri(file).writeAsStringSync(jsonEncode(factors.toList()..sort()));
    output.assets.data.add(
      DataAsset(package: input.packageName, name: 'factors.json', file: file),
    );
  });
}
