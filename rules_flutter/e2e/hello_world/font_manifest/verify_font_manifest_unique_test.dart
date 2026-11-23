/// Asserts a font family reached along two paths is written once.
///
/// `:diamond_bundle` depends on `:mid_left` and `:mid_right`, which both
/// depend on `:font_lib`'s `Diamond` family. The bundle config must carry
/// the family exactly once: two entries would ship the same file twice and
/// slow every family lookup to a linear scan of duplicates.
///
/// Backed by data files (the bundle's `flutter_assets/` tree, copied into
/// the test's runfiles via `data = [":diamond_bundle"]`). Hermetic like
/// `//test/verify_pub_assets_test.dart`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main() {
  late Directory bundleDir;

  setUpAll(() {
    // The data dep `:diamond_bundle` produces a tree artifact named after
    // the target, staged in the test's runfiles at the repo root.
    final path = Runfiles.create().rlocation(
      '_main/font_manifest/diamond_bundle',
    );
    bundleDir = Directory(path);
    if (!bundleDir.existsSync()) {
      throw StateError('diamond_bundle not found at runfiles path: $path');
    }
  });

  test('Diamond family is listed exactly once in FontManifest.json', () {
    final manifest = jsonDecode(
      File('${bundleDir.path}/FontManifest.json').readAsStringSync(),
    ) as List;
    final families = manifest.map((entry) => (entry as Map)['family']).toList();
    expect(families.where((family) => family == 'Diamond'), hasLength(1));
  });

  test('Diamond entry carries its one font asset', () {
    final manifest = jsonDecode(
      File('${bundleDir.path}/FontManifest.json').readAsStringSync(),
    ) as List;
    final diamond =
        (manifest.firstWhere((entry) => (entry as Map)['family'] == 'Diamond')
                as Map)['fonts']
            as List;
    expect(diamond, hasLength(1));
    expect((diamond.single as Map)['asset'], equals('fonts/Diamond.ttf'));
  });
}
