// The release bundle carries the index `glyphs`' link hook wrote, at the key
// `rootBundle` loads it by, and lists it in the asset manifest.
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  // The app's files; the bundle is the `_flutter_assets` one.
  final path = args.singleWhere((p) => p.endsWith('_flutter_assets'));
  final bundle = runfiles.rlocation(path);
  if (bundle == null) throw StateError('no runfiles entry for $path');

  final index = File('$bundle/packages/glyphs/glyphs/index.json');
  final names = jsonDecode(index.readAsStringSync());
  if (names is! List || names.join(',') != 'heart,star') {
    throw StateError('index is $names, want [heart, star]');
  }

  // The binary manifest (StandardMessageCodec) stores the key as plain UTF-8.
  // `AssetManifest.bin.json`, its base64, is written for web builds only, as
  // `flutter build` writes it.
  final manifest = utf8.decode(
    File('$bundle/AssetManifest.bin').readAsBytesSync(),
    allowMalformed: true,
  );
  if (!manifest.contains('packages/glyphs/glyphs/index.json')) {
    throw StateError('AssetManifest does not list the index');
  }
}
