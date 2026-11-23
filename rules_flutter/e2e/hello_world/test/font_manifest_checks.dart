/// Shared `FontManifest.json` and font-byte checks for the iOS simulator
/// bundle and Android APK e2e verifiers (COV-29).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Records one bundle expectation: [description] names what the bundle must
/// hold, [ok] whether it does, and [found] what was seen instead.
typedef BundleCheck = void Function(
  String description, {
  required bool ok,
  required String found,
});

/// The app's own font family, declared via `flutter_font_family` on
/// `//:hello_world_app` and bundled bare like the root pubspec's fonts.
const helloSansFamily = 'HelloSans';

/// The regular face asset path of [helloSansFamily].
const helloSansRegular = 'fonts/HelloSans-Regular.ttf';

/// The bold face asset path of [helloSansFamily].
const helloSansBold = 'fonts/HelloSans-Bold.ttf';

/// The exact `fonts` list `FontManifest.json` must carry for [helloSansFamily].
const List<Map<String, Object>> helloSansFonts = [
  {'asset': helloSansRegular},
  {'asset': helloSansBold, 'weight': 700},
];

/// Read-only view over a packaged `flutter_assets` directory inside an `.ipa`
/// or `.apk` archive, paired with the test runfiles root holding committed
/// fixture files.
class FontBundleView {
  /// Creates a view over packaged `flutter_assets` entries.
  const FontBundleView({
    required this.bundleKind,
    required this.assetsPrefix,
    required this.testRoot,
    required this.readAsset,
    required this.hasAsset,
  });

  /// Human-readable archive kind for failure messages (`bundle` or `APK`).
  final String bundleKind;

  /// Archive-internal path prefix of `flutter_assets` (no trailing slash).
  final String assetsPrefix;

  /// Runfiles workspace directory holding committed `fonts/*.ttf` fixtures.
  final String testRoot;

  /// Reads the decompressed bytes of `flutter_assets/[asset]`, or `null` when
  /// the archive has no such entry.
  final Uint8List? Function(String asset) readAsset;

  /// Whether `flutter_assets/[asset]` exists in the archive.
  final bool Function(String asset) hasAsset;
}

/// Whether [a] and [b] hold the same bytes in the same order.
bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Decodes `FontManifest.json` from [bundle], reporting a failure via [check]
/// and returning `null` when missing or malformed.
List<dynamic>? decodeFontManifest(FontBundleView bundle, BundleCheck check) {
  final raw = bundle.readAsset('FontManifest.json');
  if (raw == null) {
    check(
      'a FontManifest.json in the ${bundle.bundleKind}',
      ok: false,
      found: 'no ${bundle.assetsPrefix}/FontManifest.json entry',
    );
    return null;
  }
  try {
    final decoded = jsonDecode(utf8.decode(raw));
    if (decoded is! List) {
      check(
        'a FontManifest.json shaped as a family list',
        ok: false,
        found: 'a ${decoded.runtimeType}: $decoded',
      );
      return null;
    }
    return decoded;
  } on FormatException catch (e) {
    check(
      'a FontManifest.json that parses as JSON',
      ok: false,
      found: 'a decode failure: $e',
    );
    return null;
  }
}

/// Returns the manifest entry for [family] in [families], or `null`.
Map<dynamic, dynamic>? findFontFamily(List<dynamic> families, String family) {
  for (final item in families) {
    if (item is Map && item['family'] == family) return item;
  }
  return null;
}

/// Lists the family names in [families] for diagnostic messages.
List<dynamic> fontFamilyNames(List<dynamic> families) {
  return [
    for (final entry in families)
      if (entry is Map) entry['family'] else entry,
  ];
}

/// The exact `FontManifest.json` entry map for [helloSansFamily].
const Map<String, Object> helloSansEntry = {
  'family': helloSansFamily,
  'fonts': helloSansFonts,
};

bool _jsonEquals(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) ||
          !_jsonEquals(entry.value, b[entry.key])) {
        return false;
      }
    }
    return true;
  }
  return a == b;
}

/// Asserts [families] carries [helloSansFamily] once as [helloSansEntry] and
/// that both bundled `.ttf` files equal the committed fixtures byte for byte.
void checkHelloSansFamily(
  List<dynamic> families,
  FontBundleView bundle,
  BundleCheck check,
) {
  final matches = [
    for (final item in families)
      if (item is Map && item['family'] == helloSansFamily) item,
  ];
  if (matches.isEmpty) {
    check(
      'a FontManifest.json family $helloSansFamily',
      ok: false,
      found: 'families ${fontFamilyNames(families)}',
    );
    return;
  }
  final entry = matches.first;
  check(
    'one exact $helloSansFamily entry ${jsonEncode(helloSansEntry)}',
    ok: matches.length == 1 && _jsonEquals(entry, helloSansEntry),
    found: matches.length == 1
        ? 'entry ${jsonEncode(entry)}'
        : '${matches.length} entries ${jsonEncode(matches)}',
  );
  for (final asset in [helloSansRegular, helloSansBold]) {
    _checkCommittedFontBytes(bundle, asset, check);
  }
}

void _checkCommittedFontBytes(
  FontBundleView bundle,
  String asset,
  BundleCheck check,
) {
  final committed = File('${bundle.testRoot}/$asset');
  if (!committed.existsSync()) {
    check(
      'the committed $asset staged through data',
      ok: false,
      found: 'no file at ${committed.path}',
    );
    return;
  }
  final committedBytes = committed.readAsBytesSync();
  final bundledBytes = bundle.readAsset(asset);
  check(
    'bundled $asset byte-identical to the committed file '
    '(${committedBytes.length} bytes)',
    ok: bundledBytes != null && bytesEqual(bundledBytes, committedBytes),
    found: bundledBytes == null
        ? 'no ${bundle.assetsPrefix}/$asset entry'
        : '${bundledBytes.length} bytes instead of ${committedBytes.length}',
  );
}

/// Asserts [families] lists [family] with a non-empty `fonts` list and that
/// every asset path it names is present in [bundle].
void checkBundledFontFamily(
  List<dynamic> families,
  FontBundleView bundle,
  String family,
  BundleCheck check,
) {
  final entry = findFontFamily(families, family);
  if (entry == null) {
    check(
      'a FontManifest.json family $family',
      ok: false,
      found: 'families ${fontFamilyNames(families)}',
    );
    return;
  }
  final fonts = entry['fonts'];
  if (fonts is! List || fonts.isEmpty) {
    check(
      'fonts listed under the $family family',
      ok: false,
      found: 'fonts: $fonts',
    );
    return;
  }
  for (final font in fonts) {
    final asset = font is Map ? font['asset'] : null;
    check(
      'the bundled $family font asset $asset',
      ok: asset is String && bundle.hasAsset(asset),
      found: asset is String
          ? 'no ${bundle.assetsPrefix}/$asset entry'
          : 'a font entry with no asset path: $font',
    );
  }
}
