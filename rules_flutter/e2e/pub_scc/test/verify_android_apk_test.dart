import 'dart:convert';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';

import 'zip_archive.dart';

void main() {
  final runfiles = Runfiles.create();
  final apkFile = resolveRunfile(runfiles, 'APK_RLOCATION', suffix: '.apk');
  final registrantFile = resolveRunfile(
    runfiles,
    'REGISTRANT_RLOCATION',
    suffix: '.java',
  );

  final entries = readZipArchive(apkFile.readAsBytesSync());
  _verifyBundledAssets(entries);
  _verifyCompiledDexClasses(entries);
  _verifyGeneratedRegistrant(registrantFile.readAsStringSync());
}

void _verifyBundledAssets(Map<String, Uint8List Function()> entries) {
  const keyA = 'assets/flutter_assets/packages/cycle_a/assets/cycle_a.txt';
  const keyB = 'assets/flutter_assets/packages/cycle_b/assets/cycle_b.txt';
  const manifestKey = 'assets/flutter_assets/AssetManifest.bin';

  final textA = readZipEntryUtf8(entries, keyA);
  if (!textA.contains('cycle_a asset')) {
    throw StateError('Unexpected $keyA content: $textA');
  }
  final textB = readZipEntryUtf8(entries, keyB);
  if (!textB.contains('cycle_b asset')) {
    throw StateError('Unexpected $keyB content: $textB');
  }

  final manifestReader = entries[manifestKey];
  if (manifestReader == null) {
    throw StateError('Missing $manifestKey in APK');
  }
  final manifestText = utf8.decode(manifestReader(), allowMalformed: true);
  for (final expected in [
    'packages/cycle_a/assets/cycle_a.txt',
    'packages/cycle_b/assets/cycle_b.txt',
  ]) {
    if (!manifestText.contains(expected)) {
      throw StateError('APK AssetManifest.bin missing $expected');
    }
  }
}

void _verifyCompiledDexClasses(Map<String, Uint8List Function()> entries) {
  final dexNames = entries.keys
      .where((k) => k.startsWith('classes') && k.endsWith('.dex'))
      .toList();
  if (dexNames.isEmpty) {
    throw StateError('No classes*.dex entries found in APK');
  }

  final dexStrings = StringBuffer();
  for (final name in dexNames) {
    dexStrings.write(latin1.decode(entries[name]!()));
  }
  final combined = dexStrings.toString();
  for (final descriptor in [
    'Ldev/example/cycle_a/CycleAPlugin;',
    'Ldev/example/cycle_b/CycleBPlugin;',
    'Lio/flutter/plugins/GeneratedPluginRegistrant;',
  ]) {
    if (!combined.contains(descriptor)) {
      throw StateError('APK DEX missing class descriptor $descriptor');
    }
  }
}

void _verifyGeneratedRegistrant(String registrantSource) {
  for (final snippet in [
    'new dev.example.cycle_a.CycleAPlugin()',
    'new dev.example.cycle_b.CycleBPlugin()',
  ]) {
    if (!registrantSource.contains(snippet)) {
      throw StateError('Android GeneratedPluginRegistrant missing $snippet');
    }
  }
}
