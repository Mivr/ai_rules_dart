import 'dart:convert';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';

import 'zip_archive.dart';

void main() {
  final runfiles = Runfiles.create();
  final ipaFile = resolveRunfile(runfiles, 'IPA_RLOCATION', suffix: '.ipa');
  final registrantFile = resolveRunfile(
    runfiles,
    'REGISTRANT_RLOCATION',
    suffix: '.swift',
  );

  final entries = readZipArchive(ipaFile.readAsBytesSync());
  final appPrefix = _findAppBundlePrefix(entries.keys);
  _verifyBundledIosAssets(entries, appPrefix);
  _verifyLinkedIosPlugins(entries, appPrefix);
  _verifyIosRegistrant(registrantFile.readAsStringSync());
}

String _findAppBundlePrefix(Iterable<String> keys) {
  for (final key in keys) {
    if (!key.startsWith('Payload/')) continue;
    final appEnd = key.indexOf('.app/');
    if (appEnd > 0) {
      return key.substring(0, appEnd + '.app/'.length);
    }
  }
  throw StateError('No Payload/<name>.app/ directory found in IPA');
}

void _verifyBundledIosAssets(
  Map<String, Uint8List Function()> entries,
  String appPrefix,
) {
  final assetsRoot =
      entries.keys.any(
        (k) => k.startsWith('${appPrefix}flutter_assets/'),
      )
      ? '${appPrefix}flutter_assets'
      : '${appPrefix}Frameworks/App.framework/flutter_assets';

  final textA = readZipEntryUtf8(
    entries,
    '$assetsRoot/packages/cycle_a/assets/cycle_a.txt',
  );
  if (!textA.contains('cycle_a asset')) {
    throw StateError('Unexpected iOS cycle_a asset content: $textA');
  }
  final textB = readZipEntryUtf8(
    entries,
    '$assetsRoot/packages/cycle_b/assets/cycle_b.txt',
  );
  if (!textB.contains('cycle_b asset')) {
    throw StateError('Unexpected iOS cycle_b asset content: $textB');
  }

  final manifestReader = entries['$assetsRoot/AssetManifest.bin'];
  if (manifestReader == null) {
    throw StateError('Missing $assetsRoot/AssetManifest.bin in IPA');
  }
  final manifestText = utf8.decode(manifestReader(), allowMalformed: true);
  for (final expected in [
    'packages/cycle_a/assets/cycle_a.txt',
    'packages/cycle_b/assets/cycle_b.txt',
  ]) {
    if (!manifestText.contains(expected)) {
      throw StateError('iOS AssetManifest.bin missing $expected');
    }
  }
}

void _verifyLinkedIosPlugins(
  Map<String, Uint8List Function()> entries,
  String appPrefix,
) {
  final rootFiles = entries.keys.where((k) {
    if (!k.startsWith(appPrefix) || k.endsWith('/')) return false;
    return !k.substring(appPrefix.length).contains('/');
  }).toList();

  final symbolBytes = StringBuffer();
  var foundMachO = false;
  for (final path in rootFiles) {
    final data = entries[path]!();
    if (_isMachOBinary(data)) {
      foundMachO = true;
      symbolBytes.write(latin1.decode(data));
    }
  }
  if (!foundMachO) {
    throw StateError('No Mach-O binary found under $appPrefix');
  }
  final combined = symbolBytes.toString();
  for (final pluginSymbol in ['CycleAPlugin', 'CycleBPlugin']) {
    if (!combined.contains(pluginSymbol)) {
      throw StateError('Linked iOS app binary missing $pluginSymbol');
    }
  }
}

bool _isMachOBinary(Uint8List data) {
  if (data.length < 4) return false;
  final magic = ByteData.sublistView(data).getUint32(0);
  return magic == 0xfeedfacf ||
      magic == 0xcffaedfe ||
      magic == 0xcafebabe ||
      magic == 0xbebafeca;
}

void _verifyIosRegistrant(String registrantSource) {
  for (final snippet in [
    'import cycle_a',
    'import cycle_b',
    'CycleAPlugin.register',
    'CycleBPlugin.register',
  ]) {
    if (!registrantSource.contains(snippet)) {
      throw StateError('iOS GeneratedPluginRegistrant missing $snippet');
    }
  }
}
