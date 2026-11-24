/// Verifies the device release `App.framework` is what a release engineer
/// ships: a real AOT snapshot for a physical iPhone, obfuscated, with split
/// debug info and a tree-shaken icon font.
///
/// Reads the two `:app_release_device` bundles (the obfuscated release and
/// its un-obfuscated twin, both built `-c opt` for `arm64`) and the debug
/// simulator bundle `:app_simulator`, and checks:
///
/// * `App.framework/App` parses as a 64-bit Mach-O for arm64 whose
///   `LC_BUILD_VERSION` platform is iOS (2), not the simulator (7), whose
///   exported symbols are exactly the two the engine loads from an Apple
///   `app-aot-macho-dylib` snapshot (`_kDartSnapshotText`,
///   `_kDartSnapshotData`) — the `LC_SYMTAB` entries in `LC_DYSYMTAB`'s
///   external-defined range, plus any export trie the binary carries
///   (gen_snapshot's dylib has none) — and whose symbol table is stripped
///   the way `flutter build` strips it (`strip -x`): `LC_DYSYMTAB` keeps no
///   local symbols and no `LC_SYMTAB` entry is a stab entry;
/// * the snapshot itself targets iOS on arm64: its VM features string (whose
///   first word is `product` in a release build) names `arm64` and `ios`,
///   not `macos` (the framework rule stamps `LC_BUILD_VERSION` itself, so
///   the load command alone cannot show what the snapshot was compiled for);
/// * obfuscation: the class `MyApp` from `lib/main.dart` is absent from the
///   release binary but present in the twin's, so the check cannot pass
///   vacuously;
/// * split debug info: the `.symbols` file exists, is non-empty, and carries
///   an object-file magic;
/// * icon tree shaking: `fonts/MaterialIcons-Regular.otf` in the release
///   framework's `flutter_assets/` is at most a tenth of the same font in the
///   debug bundle (which is never tree-shaken) and stays a valid OpenType
///   file.
///
/// The Mach-O header and load commands are parsed here with `dart:typed_data`
/// (`otool`/`nm` are not consulted). Every failed assertion prints what it
/// expected and what it found. A missing input fails the test; nothing here
/// is ever skipped.
library;

// This script's diagnostics are its product: it reports what it found in the
// built artifact to the bazel test log, so `print` is its output channel
// rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'ios_bundle_reader.dart';

/// The two symbols an Apple `app-aot-macho-dylib` snapshot exports, with the
/// leading underscore the symbol table keeps.
const _snapshotExports = {'_kDartSnapshotText', '_kDartSnapshotData'};

/// Class in `lib/main.dart` that obfuscation must rename away.
const _obfuscatedClass = 'MyApp';

/// Basename of the split-debug-info file the release application emits.
const _symbolsName = 'app_flutter_release.symbols';

/// Path suffix of the subset icon font inside a framework's `flutter_assets`.
const _fontSuffix = 'flutter_assets/fonts/MaterialIcons-Regular.otf';

/// Basename of the debug simulator bundle in the test's `data`.
const _debugIpaName = 'app.ipa';

void main() {
  final srcDir = Platform.environment['TEST_SRCDIR'];
  final workspace = Platform.environment['TEST_WORKSPACE'];
  if (srcDir == null || workspace == null) {
    abort('FAIL: missing TEST_SRCDIR or TEST_WORKSPACE env vars');
  }
  final files = allFiles(Directory('$srcDir/$workspace'));

  final releaseApp = takeSingle(
    files,
    _isReleaseApp,
    'one release App.framework/App in the runfiles',
  );
  final twinApp = takeSingle(
    files,
    _isTwinApp,
    'one un-obfuscated twin App.framework/App in the runfiles',
  );
  final symbols = takeSingle(
    files,
    _isSymbols,
    'one $_symbolsName in the runfiles',
  );
  final releaseFont = takeSingle(
    files,
    _isReleaseFont,
    'one release $_fontSuffix in the runfiles',
  );
  final debugIpa = takeSingle(
    files,
    _isDebugIpa,
    'one $_debugIpaName in the runfiles',
  );

  final report = BundleReport();
  final releaseBytes = readOrAbort(releaseApp);
  final twinBytes = readOrAbort(twinApp);
  _checkMachO(report, 'release', releaseApp.path, releaseBytes);
  _checkMachO(report, 'twin', twinApp.path, twinBytes);
  _checkFeatures(report, 'release', releaseApp.path, releaseBytes);
  _checkFeatures(report, 'twin', twinApp.path, twinBytes);
  _checkObfuscation(
    report,
    releaseBytes,
    releaseApp.path,
    twinBytes,
    twinApp.path,
  );
  _checkSymbols(report, symbols);
  _checkIconSubset(report, releaseFont, _readDebugFont(debugIpa));

  if (!report.passed) exit(1);
  print(
    'PASS: the device release App.framework is an obfuscated AOT '
    'snapshot with split debug info and tree-shaken icons',
  );
}

/// Whether [file] is the obfuscated release framework binary.
bool _isReleaseApp(File file) {
  final path = file.path;
  return path.endsWith('App.framework/App') && !path.contains('plain');
}

/// Whether [file] is the un-obfuscated twin framework binary.
bool _isTwinApp(File file) {
  final path = file.path;
  return path.endsWith('App.framework/App') && path.contains('plain');
}

/// Whether [file] is the release split-debug-info file.
bool _isSymbols(File file) => file.path.endsWith('/$_symbolsName');

/// Whether [file] is the release framework's subset icon font.
bool _isReleaseFont(File file) {
  final path = file.path;
  return path.contains(_fontSuffix) && !path.contains('plain');
}

/// Whether [file] is the debug simulator bundle.
bool _isDebugIpa(File file) => file.path.endsWith('/$_debugIpaName');

/// Checks [bytes] is a 64-bit arm64 Mach-O for iOS exporting the snapshot
/// with a stripped symbol table.
void _checkMachO(
  BundleReport report,
  String role,
  String path,
  Uint8List bytes,
) {
  MachO macho;
  try {
    macho = parseMachO(bytes);
  } on FormatException catch (e) {
    report.check(
      'a $role App binary whose Mach-O header and load commands parse',
      ok: false,
      found: '$e in $path',
    );
    return;
  }
  report
    ..check(
      'a $role App binary that is a 64-bit Mach-O for arm64',
      ok: macho.cpuType == machOArm64CpuType,
      found: 'cputype 0x${macho.cpuType.toRadixString(16)} in $path',
    )
    ..check(
      'a $role App binary targeting iOS (platform $machOPlatformIos), '
      'not the simulator',
      ok: macho.platform == machOPlatformIos,
      found: macho.platform == null
          ? 'no LC_BUILD_VERSION in $path'
          : 'platform ${macho.platform} in $path',
    )
    ..check(
      'a $role App binary whose exported symbols are exactly '
      '$_snapshotExports, not the debug stub',
      ok:
          macho.exportNames.length == _snapshotExports.length &&
          macho.exportNames.containsAll(_snapshotExports),
      found:
          '${macho.exportNames.length} exported symbols in $path: '
          '${macho.exportNames.join(', ')}',
    )
    ..check(
      'a $role App binary with no local symbols left '
      '(nlocalsym 0, stripped like `flutter build`)',
      ok: macho.localSymbolCount == 0,
      found: macho.localSymbolCount == null
          ? 'no LC_DYSYMTAB in $path'
          : 'nlocalsym ${macho.localSymbolCount} in $path',
    )
    ..check(
      'a $role App binary with no stab entries left in its symbol table '
      '(stripped like `flutter build`)',
      ok: macho.stabSymbolCount == 0,
      found: '${macho.stabSymbolCount} stab entries in $path',
    );
}

/// Checks the snapshot was compiled for iOS on arm64, not for macOS.
///
/// The VM embeds its features as a space-separated word string whose first
/// word is `product` in a release build; the target CPU and OS are words of
/// it. The framework rule stamps `LC_BUILD_VERSION` itself, so only this
/// string shows what gen_snapshot actually compiled for.
void _checkFeatures(
  BundleReport report,
  String role,
  String path,
  Uint8List bytes,
) {
  final features = snapshotFeatures(bytes);
  final words = features.split(' ');
  report
    ..check(
      'a $role App binary whose snapshot features start with product '
      '(a release snapshot)',
      ok: words.isNotEmpty && words.first == 'product',
      found: features.isEmpty ? 'no features string in $path' : features,
    )
    ..check(
      'a $role App binary whose snapshot features name arm64',
      ok: words.contains('arm64'),
      found: features.isEmpty ? 'no features string in $path' : features,
    )
    ..check(
      'a $role App binary whose snapshot features name ios, not macos',
      ok: words.contains('ios') && !words.contains('macos'),
      found: features.isEmpty ? 'no features string in $path' : features,
    );
}

/// Checks the class is gone from the release binary but kept in the twin.
void _checkObfuscation(
  BundleReport report,
  Uint8List releaseBytes,
  String releasePath,
  Uint8List twinBytes,
  String twinPath,
) {
  final needle = utf8.encode(_obfuscatedClass);
  report
    ..check(
      'a release App binary that hides $_obfuscatedClass (obfuscated)',
      ok: !hasBytes(releaseBytes, needle),
      found: 'the name $_obfuscatedClass in $releasePath',
    )
    ..check(
      'an un-obfuscated twin App binary that keeps $_obfuscatedClass, '
      'so the check above cannot pass vacuously',
      ok: hasBytes(twinBytes, needle),
      found: 'no $_obfuscatedClass bytes in $twinPath',
    );
}

/// Checks the `.symbols` file is non-empty and carries an object magic.
void _checkSymbols(BundleReport report, File symbols) {
  final bytes = readOrAbort(symbols);
  report.check(
    'a non-empty split-debug-info .symbols file',
    ok: bytes.isNotEmpty,
    found: '${bytes.length} bytes at ${symbols.path}',
  );
  if (bytes.length < 4) return;
  final view = ByteData.sublistView(bytes, 0, 4);
  final magic = view.getUint32(0, Endian.little);
  final magicBig = view.getUint32(0);
  final isElf =
      bytes[0] == 0x7f &&
      bytes[1] == 0x45 &&
      bytes[2] == 0x4c &&
      bytes[3] == 0x46;
  report.check(
    'a .symbols file that is an object file (a Mach-O or ELF magic)',
    ok:
        magic == 0xfeedface ||
        magic == machOMagic64 ||
        magicBig == 0xcafebabe ||
        magicBig == 0xcefaedfe ||
        magicBig == 0xcffaedfe ||
        isElf,
    found: 'first bytes 0x${magic.toRadixString(16)} at ${symbols.path}',
  );
}

/// Checks the release icon font is a small, still-valid subset of the debug
/// font.
void _checkIconSubset(BundleReport report, File releaseFont, _FontPair fonts) {
  final releaseBytes = readOrAbort(releaseFont);
  report
    ..check(
      'a tree-shaken icon font at most a tenth of the debug font '
      '(${fonts.debugBytes.length} bytes)',
      ok: releaseBytes.length * 10 <= fonts.debugBytes.length,
      found: '${releaseBytes.length} bytes at ${releaseFont.path}',
    )
    ..check(
      'a tree-shaken icon font that stays a valid OpenType file',
      ok: _isOpenType(releaseBytes),
      found:
          '${releaseBytes.length} bytes at ${releaseFont.path} '
          'starting with ${_fontTag(releaseBytes)}',
    );
}

/// The release font under test beside the debug font it is measured against.
class _FontPair {
  const _FontPair(this.debugBytes, this.debugPath);

  final Uint8List debugBytes;
  final String debugPath;
}

/// Extracts the debug `.ipa` and reads its full icon font into memory.
_FontPair _readDebugFont(File ipa) {
  final tmp = Directory.systemTemp.createTempSync('ios_release_font_');
  try {
    ProcessResult unzipped;
    try {
      unzipped = Process.runSync('unzip', ['-q', ipa.path, '-d', tmp.path]);
    } on ProcessException catch (e) {
      abort('FAIL: could not run the `unzip` tool on ${ipa.path}: $e');
    }
    if (unzipped.exitCode != 0) {
      abort('FAIL: could not extract ${ipa.path}: ${unzipped.stderr}');
    }
    // A debug app keeps its assets at the app root, not in App.framework.
    final font = File('${tmp.path}/Payload/app.app/$_fontSuffix');
    if (!font.existsSync()) {
      abort(
        'FAIL: expected the debug icon font at ${font.path}; '
        'the bundle holds: ${childNames(font.parent)}',
      );
    }
    return _FontPair(readOrAbort(font), font.path);
  } finally {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }
}

/// Whether [bytes] starts with an OpenType sfnt magic.
bool _isOpenType(Uint8List bytes) {
  if (bytes.length < 4) return false;
  final tag = _fontTag(bytes);
  return tag == '00010000' || tag == '4f54544f' || tag == '74727565';
}

/// The first four bytes of [bytes] as lowercase hex, or `short`.
String _fontTag(Uint8List bytes) {
  if (bytes.length < 4) return 'short';
  return [
    for (var i = 0; i < 4; i++) bytes[i].toRadixString(16).padLeft(2, '0'),
  ].join();
}
