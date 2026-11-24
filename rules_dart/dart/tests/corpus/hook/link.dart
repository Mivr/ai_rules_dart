import 'package:hooks/hooks.dart';

/// The fixture package's link hook. It emits no data assets, so building
/// `:link_hook` runs it only as validation.
Future<void> main(List<String> args) async {
  await link(args, (input, output) async {});
}
