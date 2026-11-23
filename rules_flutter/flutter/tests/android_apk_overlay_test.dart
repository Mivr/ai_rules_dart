// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Computes the IEEE 802.3 CRC-32 checksum of [bytes].
int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc >>> 1) ^ ((crc & 1) != 0 ? 0xEDB88320 : 0);
    }
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

/// Creates a deterministic ZIP archive containing stored (method 0) [entries].
Uint8List _createStoredZip(List<({String name, Uint8List data})> entries) {
  final out = BytesBuilder();
  final cd = BytesBuilder();
  var offset = 0;

  for (final entry in entries) {
    final List<int> nameBytes = utf8.encode(entry.name);
    final int crc = _crc32(entry.data);
    final int size = entry.data.length;

    final local = ByteData(30);
    local.setUint32(0, 0x04034b50, Endian.little);
    local.setUint16(4, 20, Endian.little);
    local.setUint16(6, 0, Endian.little);
    local.setUint16(8, 0, Endian.little);
    local.setUint16(10, 0, Endian.little);
    local.setUint16(12, 0, Endian.little);
    local.setUint32(14, crc, Endian.little);
    local.setUint32(18, size, Endian.little);
    local.setUint32(22, size, Endian.little);
    local.setUint16(26, nameBytes.length, Endian.little);
    local.setUint16(28, 0, Endian.little);

    out.add(local.buffer.asUint8List());
    out.add(nameBytes);
    out.add(entry.data);

    final cdHeader = ByteData(46);
    cdHeader.setUint32(0, 0x02014b50, Endian.little);
    cdHeader.setUint16(4, 0, Endian.little);
    cdHeader.setUint16(6, 20, Endian.little);
    cdHeader.setUint16(8, 0, Endian.little);
    cdHeader.setUint16(10, 0, Endian.little);
    cdHeader.setUint16(12, 0, Endian.little);
    cdHeader.setUint16(14, 0, Endian.little);
    cdHeader.setUint32(16, crc, Endian.little);
    cdHeader.setUint32(20, size, Endian.little);
    cdHeader.setUint32(24, size, Endian.little);
    cdHeader.setUint16(28, nameBytes.length, Endian.little);
    cdHeader.setUint16(30, 0, Endian.little);
    cdHeader.setUint16(32, 0, Endian.little);
    cdHeader.setUint16(34, 0, Endian.little);
    cdHeader.setUint16(36, 0, Endian.little);
    cdHeader.setUint32(38, 0, Endian.little);
    cdHeader.setUint32(42, offset, Endian.little);

    cd.add(cdHeader.buffer.asUint8List());
    cd.add(nameBytes);

    offset += 30 + nameBytes.length + size;
  }

  final Uint8List cdBytes = cd.takeBytes();
  final eocd = ByteData(22);
  eocd.setUint32(0, 0x06054b50, Endian.little);
  eocd.setUint16(4, 0, Endian.little);
  eocd.setUint16(6, 0, Endian.little);
  eocd.setUint16(8, entries.length, Endian.little);
  eocd.setUint16(10, entries.length, Endian.little);
  eocd.setUint32(12, cdBytes.length, Endian.little);
  eocd.setUint32(16, offset, Endian.little);
  eocd.setUint16(20, 0, Endian.little);

  out.add(cdBytes);
  out.add(eocd.buffer.asUint8List());
  return out.takeBytes();
}

class _ApkEntry {
  new(
    this.name,
    this.method,
    this.crc,
    this.uncompressedSize,
    this.localHeaderOffset,
  );

  final String name;
  final int method;
  final int crc;
  final int uncompressedSize;
  final int localHeaderOffset;
}

List<_ApkEntry> _readCentral(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  var eocd = -1;
  for (int i = bytes.length - 22; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) {
    throw StateError('APK has no End of Central Directory');
  }
  final int count = bd.getUint16(eocd + 8, Endian.little);
  int pos = bd.getUint32(eocd + 16, Endian.little);
  final entries = <_ApkEntry>[];
  for (var i = 0; i < count; i++) {
    if (bd.getUint32(pos, Endian.little) != 0x02014b50) {
      throw StateError('APK central directory is corrupt at $pos');
    }
    final int method = bd.getUint16(pos + 10, Endian.little);
    final int crc = bd.getUint32(pos + 16, Endian.little);
    final int size = bd.getUint32(pos + 24, Endian.little);
    final int nameLen = bd.getUint16(pos + 28, Endian.little);
    final int extraLen = bd.getUint16(pos + 30, Endian.little);
    final int commentLen = bd.getUint16(pos + 32, Endian.little);
    final int localOffset = bd.getUint32(pos + 42, Endian.little);
    final String name = utf8.decode(
      bytes.sublist(pos + 46, pos + 46 + nameLen),
    );
    entries.add(
      _ApkEntry(
        name,
        method,
        crc,
        size,
        localOffset,
      ),
    );
    pos += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

Uint8List _extractEntryData(Uint8List apkBytes, _ApkEntry entry) {
  final bd = ByteData.sublistView(apkBytes);
  final int pos = entry.localHeaderOffset;
  final int nameLen = bd.getUint16(pos + 26, Endian.little);
  final int extraLen = bd.getUint16(pos + 28, Endian.little);
  final int dataStart = pos + 30 + nameLen + extraLen;
  return apkBytes.sublist(dataStart, dataStart + entry.uncompressedSize);
}

void _runOverlayTool({
  required String androidBundlePath,
  required String basePath,
  required String jarPath,
  required String assetsPath,
  required String outputPath,
  required bool debug,
}) {
  final args = <String>[
    'apk-overlay',
    '--base',
    basePath,
    '--native-libs-jar',
    jarPath,
    '--flutter-assets',
    assetsPath,
    '--output',
    outputPath,
  ];
  if (debug) {
    args.add('--debug');
  }
  final ProcessResult result = Process.runSync(androidBundlePath, args);
  if (result.exitCode != 0) {
    throw StateError(
      'android_bundle apk-overlay failed (exit ${result.exitCode}):\n'
      'stdout: ${result.stdout}\n'
      'stderr: ${result.stderr}',
    );
  }
}

void main() {
  final runfiles = Runfiles.create();
  final String? androidBundleRel = Platform.environment['ANDROID_BUNDLE'];
  if (androidBundleRel == null) {
    throw StateError('Missing ANDROID_BUNDLE environment variable');
  }
  final String androidBundlePath = runfiles.rlocation(androidBundleRel);

  group('apk overlay execution', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('android_overlay_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('stores kernel_blob.bin in debug and deflates it in release', () {
      final basePath = '${tempDir.path}/base.apk';
      File(basePath).writeAsBytesSync(
        _createStoredZip([
          (
            name: 'AndroidManifest.xml',
            data: Uint8List.fromList([1, 2, 3]),
          ),
        ]),
      );

      final jarPath = '${tempDir.path}/libs.jar';
      File(jarPath).writeAsBytesSync(_createStoredZip([]));

      final assetsDir = Directory('${tempDir.path}/flutter_assets')
        ..createSync();
      // 5000 identical bytes: highly compressible, so release deflates it.
      final compressible = Uint8List.fromList(List<int>.filled(5000, 42));
      File('${assetsDir.path}/kernel_blob.bin').writeAsBytesSync(compressible);

      final debugOut = '${tempDir.path}/debug_out.apk';
      _runOverlayTool(
        androidBundlePath: androidBundlePath,
        basePath: basePath,
        jarPath: jarPath,
        assetsPath: assetsDir.path,
        outputPath: debugOut,
        debug: true,
      );
      final debugEntries = <String, _ApkEntry>{
        for (final _ApkEntry e in _readCentral(
          File(debugOut).readAsBytesSync(),
        ))
          e.name: e,
      };
      expect(
        debugEntries['assets/flutter_assets/kernel_blob.bin']?.method,
        equals(0),
        reason: 'debug build must store kernel_blob.bin uncompressed',
      );

      final releaseOut = '${tempDir.path}/release_out.apk';
      _runOverlayTool(
        androidBundlePath: androidBundlePath,
        basePath: basePath,
        jarPath: jarPath,
        assetsPath: assetsDir.path,
        outputPath: releaseOut,
        debug: false,
      );
      final releaseEntries = <String, _ApkEntry>{
        for (final _ApkEntry e in _readCentral(
          File(releaseOut).readAsBytesSync(),
        ))
          e.name: e,
      };
      expect(
        releaseEntries['assets/flutter_assets/kernel_blob.bin']?.method,
        equals(8),
        reason: 'release build must deflate compressible kernel_blob.bin',
      );
    });

    test(
      'carries over stored aligned base entry without recompression in debug',
      () {
        final storedData = Uint8List.fromList(
          List<int>.generate(256, (int i) => i),
        );
        final basePath = '${tempDir.path}/base_stored.apk';
        File(basePath).writeAsBytesSync(
          _createStoredZip([
            (
              name: 'AndroidManifest.xml',
              data: Uint8List.fromList([1]),
            ),
            (
              name: 'resources.arsc',
              data: storedData,
            ),
          ]),
        );

        final jarPath = '${tempDir.path}/libs.jar';
        File(jarPath).writeAsBytesSync(_createStoredZip([]));

        final assetsDir = Directory('${tempDir.path}/flutter_assets')
          ..createSync();
        File('${assetsDir.path}/dummy.txt')
            .writeAsBytesSync(Uint8List.fromList([1]));

        final outPath = '${tempDir.path}/debug_carried.apk';
        _runOverlayTool(
          androidBundlePath: androidBundlePath,
          basePath: basePath,
          jarPath: jarPath,
          assetsPath: assetsDir.path,
          outputPath: outPath,
          debug: true,
        );

        final Uint8List outBytes = File(outPath).readAsBytesSync();
        final entries = <String, _ApkEntry>{
          for (final _ApkEntry e in _readCentral(outBytes)) e.name: e,
        };
        final _ApkEntry? resources = entries['resources.arsc'];
        expect(resources, isNotNull);
        expect(resources!.method, equals(0));
        final Uint8List extractedData = _extractEntryData(outBytes, resources);
        expect(extractedData, equals(storedData));
      },
    );

    test(
      'produces identical APK bytes across multiple runs with same inputs',
      () {
        final basePath = '${tempDir.path}/base_repro.apk';
        File(basePath).writeAsBytesSync(
          _createStoredZip([
            (
              name: 'AndroidManifest.xml',
              data: Uint8List.fromList([1, 2, 3]),
            ),
            (
              name: 'classes.dex',
              data: Uint8List.fromList(List<int>.filled(100, 5)),
            ),
          ]),
        );

        final jarPath = '${tempDir.path}/libs_repro.jar';
        File(jarPath).writeAsBytesSync(_createStoredZip([]));

        final assetsDir = Directory('${tempDir.path}/assets_repro')
          ..createSync();
        File('${assetsDir.path}/kernel_blob.bin')
            .writeAsBytesSync(List<int>.filled(500, 7));
        File('${assetsDir.path}/asset.txt')
            .writeAsBytesSync(utf8.encode('asset text'));

        final out1 = '${tempDir.path}/out1.apk';
        final out2 = '${tempDir.path}/out2.apk';
        _runOverlayTool(
          androidBundlePath: androidBundlePath,
          basePath: basePath,
          jarPath: jarPath,
          assetsPath: assetsDir.path,
          outputPath: out1,
          debug: true,
        );
        _runOverlayTool(
          androidBundlePath: androidBundlePath,
          basePath: basePath,
          jarPath: jarPath,
          assetsPath: assetsDir.path,
          outputPath: out2,
          debug: true,
        );

        final Uint8List bytes1 = File(out1).readAsBytesSync();
        final Uint8List bytes2 = File(out2).readAsBytesSync();
        expect(bytes1, equals(bytes2));
      },
    );
  });
}
