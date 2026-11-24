// Compiles src/native_add.c into the package's one code asset, with the C
// compiler the build gives the hook.
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    await CBuilder.library(
      name: 'native_add',
      assetName: 'native_add.dart',
      sources: ['src/native_add.c'],
    ).run(
      input: input,
      output: output,
      logger: Logger('')..onRecord.listen((r) => print(r.message)),
    );
  });
}
