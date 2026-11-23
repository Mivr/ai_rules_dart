/// Verifies the Android release APK is what a release engineer ships:
/// obfuscated, with split debug info and a tree-shaken icon font.
///
/// Reads `:app_release` (the obfuscated release) and `:app_release_plain` (the
/// same program with `obfuscate`, `split_debug_info` and `tree_shake_icons`
/// off), the release's `.symbols` file and its obfuscation map, and checks:
///
/// * obfuscation: the class `MyApp` and the canary class identifier are absent
///   from the release `libapp.so` and present in the twin's, so the check
///   cannot pass vacuously;
/// * split debug info: the `.symbols` file exists, is an ELF with a
///   `.debug_info` section, and the shipped `libapp.so` has none;
/// * the obfuscation map names `MyApp`;
/// * icon tree shaking: the release APK's `MaterialIcons-Regular.otf` is
///   smaller than the twin's and holds fewer glyphs.
///
/// Archives, ELF section tables and the font table directory are parsed in
/// `android_artifact_reader.dart`. Every assertion reports what it found; a
/// missing input names its path.
library;

// This script's diagnostics are its product: it reports what it found in the
// built artifact to the bazel test log, so `print` is its output channel
// rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'android_artifact_reader.dart';

/// Class in `lib/release_main.dart` that obfuscation must rename away.
const _obfuscatedClass = 'MyApp';

/// Canary identifier in `lib/release_main.dart`. Obfuscation renames
/// identifiers, not string constants, so the canary is a class name.
const _canaryClass = 'ObfuscationCanaryRelease';

const _libAppEntry = 'lib/arm64-v8a/libapp.so';
const _fontEntry = 'assets/flutter_assets/fonts/MaterialIcons-Regular.otf';
const _symbolsName = 'app_flutter_release.symbols';
const _mapName = 'app_flutter_release.obfuscation_map.json';

void main() {
  final srcDir = Platform.environment['TEST_SRCDIR'];
  final workspace = Platform.environment['TEST_WORKSPACE'];
  if (srcDir == null || workspace == null) {
    stderr.writeln('FAIL: missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }
  final root = '$srcDir/$workspace';
  final failures = <String>[];
  void check(String expected, {required bool ok, required String found}) {
    print('${ok ? 'OK' : 'FAIL'}: $expected${ok ? '' : ' -- found: $found'}');
    if (!ok) failures.add(expected);
  }

  final release = _readApk('$root/app_release.apk');
  final plain = _readApk('$root/app_release_plain.apk');
  final libApp = _entry(release, _libAppEntry);
  final plainLibApp = _entry(plain, _libAppEntry);
  _checkObfuscation(check, libApp, plainLibApp);
  _checkSymbols(check, libApp, _readFile('$root/$_symbolsName'));
  _checkMap(check, _readFile('$root/$_mapName'));
  _checkIcons(check, _entry(release, _fontEntry), _entry(plain, _fontEntry));

  if (failures.isNotEmpty) {
    stderr.writeln('\n${failures.length} check(s) failed.');
    exit(1);
  }
  print(
    '\nPASS: the release APK is obfuscated, keeps its symbols out of '
    'libapp.so and ships a subset icon font',
  );
}

typedef _Check = void Function(
  String, {
  required bool ok,
  required String found,
});

Uint8List _readFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('FAIL: input not found: $path');
    exit(1);
  }
  return file.readAsBytesSync();
}

Map<String, Uint8List> _readApk(String path) {
  try {
    return readZipEntries(_readFile(path), path);
  } on FormatException catch (e) {
    stderr.writeln('FAIL: ${e.message}');
    exit(1);
  }
}

Uint8List _entry(Map<String, Uint8List> apk, String name) {
  final bytes = apk[name];
  if (bytes == null) {
    stderr.writeln('FAIL: $name not in the APK; it holds: ${apk.keys}');
    exit(1);
  }
  return bytes;
}

void _checkObfuscation(_Check check, Uint8List libApp, Uint8List plain) {
  for (final name in [_obfuscatedClass, _canaryClass]) {
    final inRelease = countOccurrences(libApp, name);
    final inPlain = countOccurrences(plain, name);
    check(
      'obfuscated libapp.so does not contain $name',
      ok: inRelease == 0,
      found: '$inRelease occurrence(s) in ${libApp.length} bytes',
    );
    check(
      'un-obfuscated twin libapp.so contains $name',
      ok: inPlain > 0,
      found: '$inPlain occurrence(s) in ${plain.length} bytes',
    );
  }
}

void _checkSymbols(_Check check, Uint8List libApp, Uint8List symbols) {
  try {
    final sections = readElfSectionNames(symbols, _symbolsName);
    check(
      '$_symbolsName is an ELF with a .debug_info section',
      ok: sections.contains('.debug_info'),
      found: 'sections $sections',
    );
    final shipped = readElfSectionNames(libApp, _libAppEntry);
    check(
      'shipped libapp.so has no .debug_info section',
      ok: !shipped.contains('.debug_info'),
      found: 'sections $shipped',
    );
  } on FormatException catch (e) {
    check('readable ELF files', ok: false, found: e.message);
  }
}

void _checkMap(_Check check, Uint8List map) {
  final decoded = jsonDecode(utf8.decode(map));
  final names = decoded is List ? decoded : const <Object?>[];
  check(
    'obfuscation map names $_obfuscatedClass',
    ok: names.contains(_obfuscatedClass),
    found: 'a ${decoded.runtimeType} of ${names.length} entries',
  );
}

void _checkIcons(_Check check, Uint8List release, Uint8List plain) {
  check(
    "release MaterialIcons font is smaller than the twin's",
    ok: release.length < plain.length,
    found: '${release.length} bytes vs ${plain.length} bytes',
  );
  try {
    final releaseGlyphs = readFontGlyphCount(release, 'release font');
    final plainGlyphs = readFontGlyphCount(plain, 'twin font');
    check(
      "release MaterialIcons font has fewer glyphs than the twin's",
      ok: releaseGlyphs < plainGlyphs,
      found: '$releaseGlyphs glyphs vs $plainGlyphs glyphs',
    );
  } on FormatException catch (e) {
    check('readable fonts', ok: false, found: e.message);
  }
}
