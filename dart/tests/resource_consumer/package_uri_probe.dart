// What the runtime package config of a `dart_test` has to give a test, shared by
// the `package:test` and the plain-`main()` test that call it.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:bare_package/bare.dart';
import 'package:sample_data/sample.dart';

/// Returns where `package:sample_data/data/sample.txt` resolves, or throws a
/// [StateError] naming the first thing that is not as the runtime package
/// config promises.
Future<Uri> probePackageUris() async {
  final data = Uri.parse('package:$sampleData/data/sample.txt');
  final Uri? async = await Isolate.resolvePackageUri(data);
  final Uri? sync = Isolate.resolvePackageUriSync(data);
  for (final Uri? uri in [async, sync]) {
    if (uri == null || uri.scheme != 'file') {
      throw StateError('$data resolved to $uri, not a file URI');
    }
    final String text = File.fromUri(uri).readAsStringSync().trim();
    if (text != 'sample') throw StateError('$uri holds "$text"');
  }
  if (async != sync) throw StateError('async $async differs from sync $sync');

  // A package with no staged file is not in the config.
  final bareUri = Uri.parse('package:$bare/bare.dart');
  for (final Uri? uri in [
    await Isolate.resolvePackageUri(bareUri),
    Isolate.resolvePackageUriSync(bareUri),
  ]) {
    if (uri != null) throw StateError('$bareUri resolved to $uri');
  }

  // `Platform.packageConfig` is the file `resolvePackageUri` goes by.
  final String? config = Platform.packageConfig;
  if (config == null) throw StateError('Platform.packageConfig is null');
  final configUri = Uri.parse(config);
  final json = jsonDecode(
    File.fromUri(configUri).readAsStringSync(),
  ) as Map<String, dynamic>;
  final Uri? fromConfig = _fromConfig(
    json,
    configUri,
    sampleData,
    'data/sample.txt',
  );
  if (fromConfig != async) {
    throw StateError('config says $fromConfig, resolvePackageUri $async');
  }
  if (_fromConfig(json, configUri, bare, 'bare.dart') != null) {
    throw StateError('$config maps $bare');
  }
  return async!;
}

Uri? _fromConfig(
  Map<String, dynamic> json,
  Uri configUri,
  String name,
  String path,
) {
  for (final package
      in (json['packages'] as List).cast<Map<String, dynamic>>()) {
    if (package['name'] != name) continue;
    final Uri root = configUri.resolve(package['rootUri'] as String);
    return root.resolve(package['packageUri'] as String).resolve(path);
  }
  return null;
}
