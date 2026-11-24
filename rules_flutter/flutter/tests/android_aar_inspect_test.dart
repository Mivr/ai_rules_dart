// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Reads the entries of the ZIP archive [bytes] from its central directory.
Map<String, Uint8List> _entries(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  int eocd = bytes.length - 22;
  while (eocd >= 0 && data.getUint32(eocd, Endian.little) != 0x06054b50) {
    eocd--;
  }
  expect(eocd, greaterThanOrEqualTo(0), reason: 'no end of central directory');
  final int count = data.getUint16(eocd + 10, Endian.little);
  int offset = data.getUint32(eocd + 16, Endian.little);
  final entries = <String, Uint8List>{};
  for (var i = 0; i < count; i++) {
    expect(data.getUint32(offset, Endian.little), 0x02014b50);
    final int method = data.getUint16(offset + 10, Endian.little);
    final int compressed = data.getUint32(offset + 20, Endian.little);
    final int nameLength = data.getUint16(offset + 28, Endian.little);
    final int extraLength = data.getUint16(offset + 30, Endian.little);
    final int commentLength = data.getUint16(offset + 32, Endian.little);
    final int local = data.getUint32(offset + 42, Endian.little);
    final name = String.fromCharCodes(
      bytes,
      offset + 46,
      offset + 46 + nameLength,
    );
    final int start =
        local +
        30 +
        data.getUint16(local + 26, Endian.little) +
        data.getUint16(local + 28, Endian.little);
    final raw = Uint8List.sublistView(
      bytes,
      start,
      start + compressed,
    );
    entries[name] = method == 0
        ? raw
        : Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

void _assertSingleAbiAar(String envVar, String abi) {
  final String path = Runfiles.create().rlocation(
    Platform.environment[envVar]!,
  );
  expect(path, endsWith('.aar'));
  final Uint8List bytes = File(path).readAsBytesSync();
  final Map<String, Uint8List> entries = _entries(bytes);
  final List<String> names = entries.keys.toList();

  expect(
    names,
    containsAll(<String>[
      'AndroidManifest.xml',
      'classes.jar',
      'jni/$abi/libapp.so',
      'assets/flutter_assets/AssetManifest.bin',
    ]),
  );
  expect(
    names.where(
      (n) => n.startsWith('assets/') && !n.startsWith('assets/flutter_assets/'),
    ),
    isEmpty,
  );
  expect(names.where((n) => n.startsWith('jni/')), [
    'jni/$abi/libapp.so',
  ]);
  expect(
    String.fromCharCodes(entries['AndroidManifest.xml']!),
    contains('package="com.example.module"'),
  );
}

void main() {
  test('the default .aar holds arm64-v8a AOT library, assets, manifest and classes.jar', () {
    _assertSingleAbiAar('AAR', 'arm64-v8a');
  });

  test('the x86_64 .aar holds x86_64 AOT library only, assets, manifest and classes.jar', () {
    _assertSingleAbiAar('AAR_X64', 'x86_64');
  });
}
