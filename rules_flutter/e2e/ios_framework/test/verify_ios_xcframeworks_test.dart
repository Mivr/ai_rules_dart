/// Verifies the add-to-app xcframework set built from a plain application.
///
/// Every assertion prints what it expected and what it found. The macOS-only
/// target runs on the `e2e/ios_framework` leg of full.yaml; a missing input
/// fails the test instead of skipping it.
library;

// This script's diagnostics are its product: it reports what it found in the
// built artifacts to the bazel test log.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rules_flutter_macho_reader/macho_reader.dart';

const _appDevicePath =
    'app_xcframeworks/App.xcframework/ios-arm64/App.framework/App';
const _appSimulatorPath =
    'app_xcframeworks/App.xcframework/'
    'ios-arm64_x86_64-simulator/App.framework/App';
const _appInfoPath = 'app_xcframeworks/App.xcframework/Info.plist';
const _engineDevicePath =
    'app_xcframeworks/Flutter.xcframework/ios-arm64/Flutter.framework/Flutter';
const _registrantDevicePath =
    'app_xcframeworks/FlutterPluginRegistrant.xcframework/'
    'ios-arm64/FlutterPluginRegistrant.framework/FlutterPluginRegistrant';
const _pluginDevicePath =
    'app_xcframeworks/ios_framework_plugin.xcframework/'
    'ios-arm64/ios_framework_plugin.framework/ios_framework_plugin';
const _pluginSimulatorPath =
    'app_xcframeworks/ios_framework_plugin.xcframework/'
    'ios-arm64_x86_64-simulator/ios_framework_plugin.framework/'
    'ios_framework_plugin';
const _pluginMarker = 'rules_flutter_ios_framework_plugin_marker';
const _registrantMarker = 'IosFrameworkPlugin';
const _snapshotText = '_kDartSnapshotText';
const _snapshotData = '_kDartSnapshotData';

void main() {
  final srcDir = Platform.environment['TEST_SRCDIR'];
  final workspace = Platform.environment['TEST_WORKSPACE'];
  if (srcDir == null || workspace == null) {
    _abort('FAIL: missing TEST_SRCDIR or TEST_WORKSPACE');
  }
  final files = [
    ..._allFiles(_workspaceRoot(srcDir, workspace)),
    ..._externalEngineFiles(srcDir, workspace),
  ];

  final appInfo = _take(
    files,
    (f) => f.path.endsWith(_appInfoPath),
    _appInfoPath,
  );
  final appDevice = _take(
    files,
    (f) => f.path.endsWith(_appDevicePath),
    _appDevicePath,
  );
  final appSimulator = _take(
    files,
    (f) => f.path.endsWith(_appSimulatorPath),
    _appSimulatorPath,
  );
  final engineDevice = _take(
    files,
    (f) => f.path.endsWith(_engineDevicePath),
    _engineDevicePath,
  );
  final pinnedEngine = _take(
    files,
    (f) =>
        f.path.endsWith(
          '/Flutter.xcframework/ios-arm64/Flutter.framework/Flutter',
        ) &&
        !f.path.contains('/app_xcframeworks/') &&
        !f.path.contains('/debug/'),
    'the pinned engine device binary',
  );
  final registrant = _take(
    files,
    (f) => f.path.endsWith(_registrantDevicePath),
    _registrantDevicePath,
  );
  final plugin = _take(
    files,
    (f) => f.path.endsWith(_pluginDevicePath),
    _pluginDevicePath,
  );
  final pluginSimulator = _take(
    files,
    (f) => f.path.endsWith(_pluginSimulatorPath),
    _pluginSimulatorPath,
  );

  final report = _Report();
  _checkAppInfoPlist(report, _read(appInfo));
  _checkLibraryPaths(report, files);
  _checkDeviceApp(report, appDevice.path, _read(appDevice));
  _checkSimulatorApp(report, appSimulator.path, _read(appSimulator));
  _checkEngine(report, engineDevice, pinnedEngine);
  _checkContains(
    report,
    registrant,
    _registrantMarker,
    'the registrant binary registers IosFrameworkPlugin',
  );
  _checkContains(
    report,
    plugin,
    _pluginMarker,
    'the plugin xcframework carries the plugin marker',
  );
  _checkContains(
    report,
    pluginSimulator,
    _pluginMarker,
    'the plugin simulator slice carries the plugin marker',
  );

  if (!report.passed) exit(1);
  print(
    'PASS: the add-to-app xcframework set matches the pinned engine and plugin',
  );
}

/// Stops the test with [message]: a missing input fails, never skips.
Never _abort(String message) {
  stderr.writeln(message);
  exit(1);
}

/// The runfiles directory holding this workspace's outputs.
Directory _workspaceRoot(String srcDir, String workspace) {
  final named = Directory('$srcDir/$workspace');
  if (named.existsSync()) return named;
  final main = Directory('$srcDir/_main');
  if (main.existsSync()) return main;
  _abort('FAIL: expected the runfiles workspace at $named or ${main.path}');
}

/// Every file under [root], following runfiles symlinks.
List<File> _allFiles(Directory root) {
  final out = <File>[];
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File) out.add(entity);
  }
  return out;
}

/// The pinned engine's runfiles, which live in their own external repo.
List<File> _externalEngineFiles(String srcDir, String workspace) {
  final out = <File>[];
  for (final entity in Directory(srcDir).listSync()) {
    if (entity is! Directory) continue;
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name == workspace || name == '_main') continue;
    if (name.contains('flutter_ios_engine')) {
      out.addAll(_allFiles(entity));
    }
  }
  return out;
}

/// The single file matching [matches], or a failure naming what was found.
File _take(List<File> files, bool Function(File) matches, String description) {
  final hits = [
    for (final f in files)
      if (matches(f)) f,
  ];
  if (hits.length != 1) {
    final paths = [for (final f in hits.take(4)) f.path].join(', ');
    _abort(
      'FAIL: expected one $description; found ${hits.length}'
      '${paths.isEmpty ? '' : ': $paths'}',
    );
  }
  return hits[0];
}

/// The bytes of [file], or a failure naming the read error.
Uint8List _read(File file) {
  try {
    return file.readAsBytesSync();
  } on FileSystemException catch (e) {
    _abort('FAIL: could not read ${file.path}: $e');
  }
}

/// Collects passing and failing checks; every failure names expected/found.
class _Report {
  final _failures = <String>[];

  /// Whether every check so far passed.
  bool get passed => _failures.isEmpty;

  /// Records one check of [description], printing the outcome.
  void check(String description, {required bool ok, String? found}) {
    if (ok) {
      print('OK: $description');
    } else {
      stderr.writeln(
        'FAIL: expected $description; found ${found ?? 'nothing'}',
      );
      _failures.add(description);
    }
  }
}

/// Checks `App.xcframework/Info.plist` names exactly the two required slices.
void _checkAppInfoPlist(_Report report, Uint8List bytes) {
  final parsed = _parseAvailableLibraries(latin1.decode(bytes));
  const expected = {
    'ios-arm64': (archs: ['arm64'], variant: null),
    'ios-arm64_x86_64-simulator': (
      archs: ['arm64', 'x86_64'],
      variant: 'simulator',
    ),
  };
  final actual = <String, ({List<String> archs, String? variant})>{};
  for (final entry in parsed) {
    actual[entry.identifier] = (archs: entry.archs, variant: entry.variant);
  }
  report.check(
    'App.xcframework/Info.plist with exactly ios-arm64 and '
    'ios-arm64_x86_64-simulator',
    ok: _sameMap(actual, expected),
    found: '$parsed',
  );
  for (final entry in parsed) {
    report.check(
      '${entry.identifier} to declare SupportedPlatform ios',
      ok: entry.platform == 'ios',
      found: entry.platform,
    );
  }
}

/// Checks every produced xcframework resolves each `LibraryPath` on disk.
///
/// Xcode reads `LibraryPath` relative to the `LibraryIdentifier` directory, so
/// `<xcframework>/<LibraryIdentifier>/<LibraryPath>/<Name>` must exist.
void _checkLibraryPaths(_Report report, List<File> files) {
  final plists = [
    for (final f in files)
      if (f.path.contains('/app_xcframeworks/') &&
          f.path.endsWith('.xcframework/Info.plist'))
        f,
  ];
  report.check(
    'at least one xcframework Info.plist under app_xcframeworks',
    ok: plists.isNotEmpty,
    found: 'none',
  );
  final present = {for (final f in files) f.path};
  for (final plist in plists) {
    final xcframework = plist.parent.path;
    for (final lib in _parseAvailableLibraries(latin1.decode(_read(plist)))) {
      final binary = _sliceBinary(xcframework, lib);
      report.check(
        '$xcframework slice ${lib.identifier} to resolve LibraryPath '
        '${lib.path} to an existing binary',
        ok: binary != null && present.contains(binary),
        found: 'no file at $binary',
      );
    }
  }
}

/// The binary `<xcframework>/<LibraryIdentifier>/<LibraryPath>/<Name>`.
String? _sliceBinary(String xcframework, _Library lib) {
  final path = lib.path;
  if (path == null) return null;
  final name = path.split('/').last.replaceFirst(RegExp(r'\.framework$'), '');
  return '$xcframework/${lib.identifier}/$path/$name';
}

/// One parsed `AvailableLibraries` entry.
class _Library {
  const _Library(
    this.identifier,
    this.platform,
    this.variant,
    this.archs,
    this.path,
  );

  final String identifier;
  final String? path;
  final String platform;
  final String? variant;
  final List<String> archs;

  @override
  String toString() =>
      '$identifier(platform=$platform, variant=$variant, archs=$archs)';
}

/// Parses the `AvailableLibraries` dictionaries of an xcframework plist.
List<_Library> _parseAvailableLibraries(String text) {
  final at = text.indexOf('<key>AvailableLibraries</key>');
  if (at < 0) {
    _abort('FAIL: expected AvailableLibraries in App.xcframework/Info.plist');
  }
  final dicts = RegExp(
    '<dict>(.*?)</dict>',
    dotAll: true,
  ).allMatches(text.substring(at));
  final libraries = <_Library>[];
  for (final dict in dicts) {
    final body = dict.group(1)!;
    final identifier = _string(body, 'LibraryIdentifier');
    final platform = _string(body, 'SupportedPlatform');
    final path = _string(body, 'LibraryPath');
    final variant = _string(body, 'SupportedPlatformVariant');
    final archBlock = RegExp(
      r'<key>\s*SupportedArchitectures\s*</key>\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(body);
    final archs = archBlock == null
        ? <String>[]
        : [
            for (final m in RegExp(
              '<string>(.*?)</string>',
              dotAll: true,
            ).allMatches(archBlock.group(1)!))
              m.group(1)!,
          ];
    if (identifier == null || platform == null) {
      _abort(
        'FAIL: expected LibraryIdentifier and SupportedPlatform, found $body',
      );
    }
    libraries.add(_Library(identifier, platform, variant, archs, path));
  }
  return libraries;
}

/// The `<string>` value following [key] in one plist dictionary body.
String? _string(String body, String key) {
  final match = RegExp(
    '<key>\\s*$key\\s*</key>\\s*<string>(.*?)</string>',
    dotAll: true,
  ).firstMatch(body);
  return match?.group(1);
}

/// Whether two slice maps carry the same identifier, architecture and variant.
bool _sameMap(
  Map<String, ({List<String> archs, String? variant})> actual,
  Map<String, ({List<String> archs, String? variant})> expected,
) {
  if (actual.length != expected.length) return false;
  for (final entry in expected.entries) {
    final found = actual[entry.key];
    if (found == null) return false;
    if (found.variant != entry.value.variant) return false;
    if (found.archs.join(',') != entry.value.archs.join(',')) return false;
  }
  return true;
}

/// Checks the device App slice is 64-bit arm64, iOS platform 2, and AOT.
void _checkDeviceApp(_Report report, String path, Uint8List bytes) {
  final slices = _slices(report, path, bytes);
  report.check(
    'one 64-bit arm64 Mach-O slice in the device App binary',
    ok:
        slices.length == 1 &&
        slices.every((s) => s.cpuType == machoCpuArm64 && s.is64Bit),
    found: '$slices in $path',
  );
  _checkPlatform(report, path, slices, machoPlatformIos);
  _checkSnapshot(report, path, bytes);
}

/// Checks the universal simulator App slice is 64-bit and iOS-simulator.
void _checkSimulatorApp(_Report report, String path, Uint8List bytes) {
  final slices = _slices(report, path, bytes);
  final cpuTypes = {for (final s in slices) s.cpuType};
  report.check(
    'a universal simulator App binary with arm64 and x86_64 slices',
    ok:
        slices.length == 2 &&
        slices.every((s) => s.is64Bit) &&
        cpuTypes.contains(machoCpuArm64) &&
        cpuTypes.contains(machoCpuX8664),
    found: '$slices in $path',
  );
  _checkPlatform(report, path, slices, machoPlatformIosSimulator);
  _checkSnapshot(report, path, bytes);
}

/// Parses [bytes], failing the report when they are not Mach-O.
List<MachOSliceInfo> _slices(_Report report, String path, Uint8List bytes) {
  try {
    return readMachOSlices(bytes, path);
  } on FormatException catch (e) {
    report.check('a parseable Mach-O at $path', ok: false, found: '$e');
    return const [];
  }
}

/// Checks every slice declares [platform].
void _checkPlatform(
  _Report report,
  String path,
  List<MachOSliceInfo> slices,
  int platform,
) {
  report.check(
    'every slice to target platform $platform',
    ok: slices.isNotEmpty && slices.every((s) => s.platform == platform),
    found: '${[for (final s in slices) s.platform]} in $path',
  );
}

/// Checks the App binary exports both AOT snapshot symbols, never the stub.
void _checkSnapshot(_Report report, String path, Uint8List bytes) {
  report.check(
    'an AOT App binary exporting $_snapshotText and $_snapshotData '
    '(not the debug stub)',
    ok: _hasBytes(bytes, _snapshotText) && _hasBytes(bytes, _snapshotData),
    found: 'snapshot exports in $path',
  );
}

/// Checks the Flutter device slice is byte-identical to the pinned engine.
void _checkEngine(_Report report, File engine, File pinned) {
  final actual = _read(engine);
  final expected = _read(pinned);
  report.check(
    'the Flutter.xcframework device binary to be byte-identical to '
    '${pinned.path}',
    ok: _sameBytes(actual, expected),
    found:
        '${actual.length} bytes at ${engine.path}, '
        '${expected.length} bytes at ${pinned.path}',
  );
}

/// Checks [file]'s bytes contain [needle] as ASCII.
void _checkContains(
  _Report report,
  File file,
  String needle,
  String description,
) {
  final bytes = _read(file);
  report.check(
    '$description (looking for "$needle")',
    ok: _hasBytes(bytes, needle),
    found: '${bytes.length} bytes at ${file.path}',
  );
}

/// Whether [haystack] holds [needle] as contiguous UTF-8 bytes.
bool _hasBytes(Uint8List haystack, String needle) {
  final target = utf8.encode(needle);
  if (target.isEmpty) return true;
  for (var i = 0; i + target.length <= haystack.length; i++) {
    var hit = true;
    for (var j = 0; j < target.length; j++) {
      if (haystack[i + j] != target[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

/// Whether two byte lists have identical contents.
bool _sameBytes(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}
