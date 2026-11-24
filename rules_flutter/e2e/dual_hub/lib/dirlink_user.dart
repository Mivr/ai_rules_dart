// Consumes the `dirlink_plugin` path package: importing it proves the
// spoke mirrored the package's `lib/` sources into its library target.
import 'package:dirlink_plugin/dirlink_plugin.dart';

String describe() => const DirlinkPlugin().greet();
