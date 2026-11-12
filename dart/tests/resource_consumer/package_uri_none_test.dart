import 'dart:io';
import 'dart:isolate';

/// A test with no dependency at all still gets a runtime package config, and
/// it maps nothing.
Future<void> main() async {
  final String? config = Platform.packageConfig;
  if (config == null || !File.fromUri(Uri.parse(config)).existsSync()) {
    throw StateError('Platform.packageConfig is $config');
  }
  final Uri? uri = await Isolate.resolvePackageUri(
    Uri.parse('package:anything/x.txt'),
  );
  if (uri != null) throw StateError('package:anything/x.txt resolved to $uri');
}
