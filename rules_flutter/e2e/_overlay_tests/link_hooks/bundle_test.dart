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

  // The `.json` is the base64 of the binary manifest; the key is stored as
  // plain text inside it.
  final manifest = utf8.decode(
    base64.decode(
      jsonDecode(File('$bundle/AssetManifest.bin.json').readAsStringSync())
          as String,
    ),
    allowMalformed: true,
  );
  if (!manifest.contains('packages/glyphs/glyphs/index.json')) {
    throw StateError('AssetManifest does not list the index');
  }
}
