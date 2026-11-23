/// Asserts that pub-package fonts and assets land in the bundle at
/// `packages/<pkg>/...` and that FontManifest.json + AssetManifest.bin
/// reference them with the same `packages/<pkg>/` prefix.
///
/// Backed by data files (the bundle's `flutter_assets/` tree, copied into
/// the test's runfiles via `data = [":hello_world_app"]`). The test is
/// intentionally hermetic: no `bazel build` from inside the test, no host
/// flutter SDK, no real macOS bundle. The bundle structure alone is what
/// proves the pub-asset pipeline works.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main() {
  late Directory bundleDir;

  setUpAll(() {
    // The data dep `:hello_world_app` produces a tree artifact
    // `hello_world_app_flutter_assets`, staged in the test's runfiles.
    // Resolve it via the runfiles library rather than guessing paths: that
    // works under both the Unix symlink tree and the Windows manifest
    // (windows-latest runs with --noenable_runfiles, so no directory exists).
    final path = Runfiles.create().rlocation(
      '_main/hello_world_app_flutter_assets',
    );
    bundleDir = Directory(path);
    if (!bundleDir.existsSync()) {
      throw StateError(
        'hello_world_app_flutter_assets not found at runfiles path: $path',
      );
    }
  });

  test('cupertino_icons font lands at packages/cupertino_icons/...', () {
    final fontFile = File(
      '${bundleDir.path}/packages/cupertino_icons/assets/CupertinoIcons.ttf',
    );
    expect(
      fontFile.existsSync(),
      isTrue,
      reason: 'expected pub-shipped font at $fontFile',
    );
    // Tree-shaken — file is small but non-empty.
    expect(fontFile.lengthSync(), greaterThan(0));
  });

  test(
    'FontManifest.json contains packages/cupertino_icons/CupertinoIcons',
    () {
      final manifest = File(
        '${bundleDir.path}/FontManifest.json',
      ).readAsStringSync();
      final entries = jsonDecode(manifest) as List<dynamic>;
      final cupertino = entries.firstWhere(
        (e) =>
            (e as Map<String, dynamic>)['family'] ==
            'packages/cupertino_icons/CupertinoIcons',
        orElse: () => null,
      );
      expect(
        cupertino,
        isNotNull,
        reason:
            'FontManifest.json missing packages/cupertino_icons/CupertinoIcons '
            'family entry. Full manifest: $manifest',
      );
      final fonts =
          (cupertino as Map<String, dynamic>)['fonts'] as List<dynamic>;
      expect(fonts, hasLength(1));
      expect(
        (fonts[0] as Map<String, dynamic>)['asset'],
        equals('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
      );
    },
  );

  test('FontManifest.json contains bare MaterialIcons family', () {
    // The pubspec's `uses-material-design: true` bundles the framework's
    // icon font under the bare "MaterialIcons" family at
    // fonts/MaterialIcons-Regular.otf, as `flutter build` does. Matches
    // const_finder's expectations for IconData with no fontPackage.
    final manifest = File(
      '${bundleDir.path}/FontManifest.json',
    ).readAsStringSync();
    final entries = jsonDecode(manifest) as List<dynamic>;
    final material = entries.firstWhere(
      (e) => (e as Map<String, dynamic>)['family'] == 'MaterialIcons',
      orElse: () => null,
    );
    expect(material, isNotNull);
    final fonts = (material as Map<String, dynamic>)['fonts'] as List<dynamic>;
    expect(
      (fonts[0] as Map<String, dynamic>)['asset'],
      equals('fonts/MaterialIcons-Regular.otf'),
    );
  });

  test('flutter_localized_locales data files land under packages/<pkg>/', () {
    final dataDir = Directory(
      '${bundleDir.path}/packages/flutter_localized_locales/data',
    );
    expect(dataDir.existsSync(), isTrue);
    final files = dataDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList();
    expect(
      files.length,
      greaterThan(50),
      reason: 'expected many locale json files; got ${files.length}',
    );
  });

  test('AssetManifest.bin contains a packages/<pkg>/ entry', () {
    // AssetManifest.bin is StandardMessageCodec, which serializes string keys
    // as UTF-8 bytes inline, so the prefixed asset path appears verbatim in
    // the decoded bytes. (Its base64 wrapper, AssetManifest.bin.json, is
    // written for web builds only, as `flutter build` writes it.)
    final raw = File('${bundleDir.path}/AssetManifest.bin').readAsBytesSync();
    final asString = utf8.decode(raw, allowMalformed: true);
    expect(
      asString,
      contains('packages/flutter_localized_locales/data/'),
      reason:
          'AssetManifest.bin should reference at least one '
          'flutter_localized_locales asset',
    );
  });
}
