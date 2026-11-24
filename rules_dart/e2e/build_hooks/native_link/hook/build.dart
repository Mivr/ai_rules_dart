// Compiles src/native_link.c. When the build links (a release build), the
// library goes to this package's link hook rather than straight to the app.
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    await CBuilder.library(
      name: 'native_link',
      assetName: 'native_link.dart',
      sources: ['src/native_link.c'],
    ).run(
      input: input,
      output: output,
      logger: Logger('')..onRecord.listen((r) => print(r.message)),
      routing: input.config.linkingEnabled
          ? [ToLinkHook(input.packageName)]
          : const [ToAppBundle()],
    );
  });
}
