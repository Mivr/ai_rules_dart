import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  final runfiles = Runfiles.create();
  var bundlePath = runfiles.rlocation(
    'rules_flutter_pub_scc/app_flutter_assets',
  );
  if (bundlePath.isEmpty || !Directory(bundlePath).existsSync()) {
    bundlePath = runfiles.rlocation('_main/app_flutter_assets');
  }
  final bundleDir = Directory(bundlePath);
  if (!bundleDir.existsSync()) {
    throw StateError('app_flutter_assets not found at: $bundlePath');
  }

  final assetA = File('${bundleDir.path}/packages/cycle_a/assets/cycle_a.txt');
  if (!assetA.existsSync()) {
    throw StateError('cycle_a asset not found at: ${assetA.path}');
  }
  if (!assetA.readAsStringSync().contains('cycle_a asset')) {
    throw StateError('cycle_a asset content mismatch: ${assetA.path}');
  }

  final assetB = File('${bundleDir.path}/packages/cycle_b/assets/cycle_b.txt');
  if (!assetB.existsSync()) {
    throw StateError('cycle_b asset not found at: ${assetB.path}');
  }
  if (!assetB.readAsStringSync().contains('cycle_b asset')) {
    throw StateError('cycle_b asset content mismatch: ${assetB.path}');
  }

  final manifestFile = File('${bundleDir.path}/AssetManifest.bin.json');
  if (manifestFile.existsSync()) {
    final wrapped = jsonDecode(manifestFile.readAsStringSync()) as String;
    final raw = base64Decode(wrapped);
    final manifestText = utf8.decode(raw, allowMalformed: true);
    if (!manifestText.contains('packages/cycle_a/assets/cycle_a.txt')) {
      throw StateError('AssetManifest.bin.json missing cycle_a asset');
    }
    if (!manifestText.contains('packages/cycle_b/assets/cycle_b.txt')) {
      throw StateError('AssetManifest.bin.json missing cycle_b asset');
    }
  }
}
