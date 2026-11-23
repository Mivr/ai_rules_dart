// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Build tests for the debug split APKs `flutter_android_app` can produce.
///
/// They drive the `apk-overlay` subcommand exactly as the rule's actions do:
/// the base split (payload-free base APK plus native libraries) and the
/// payload split (code-free manifest plus `flutter_assets/`).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const String _splitName = 'flutter_payload';
const String _manifest =
    '<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
    'package="dev.example.app" android:versionCode="42"> '
    '<application/></manifest>';

/// A ZIP of stored (method 0) entries, with real CRC-32 checksums.
Uint8List _storedZip(Map<String, List<int>> files) {
  int crc32(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final b in data) {
      crc ^= b;
      for (var k = 0; k < 8; k++) {
        crc = (crc >>> 1) ^ (0xEDB88320 & -(crc & 1));
      }
    }
    return ~crc & 0xFFFFFFFF;
  }

  final body = BytesBuilder();
  final directory = BytesBuilder();
  files.forEach((name, data) {
    final List<int> n = utf8.encode(name);
    final Uint8List common =
        (ByteData(26)
              ..setUint16(0, 20, Endian.little)
              ..setUint32(10, crc32(data), Endian.little)
              ..setUint32(14, data.length, Endian.little)
              ..setUint32(18, data.length, Endian.little)
              ..setUint16(22, n.length, Endian.little))
            .buffer
            .asUint8List();
    final int offset = body.length;
    body
      ..add([0x50, 0x4b, 3, 4])
      ..add(common)
      ..add(n)
      ..add(data);
    directory
      ..add([0x50, 0x4b, 1, 2, 20, 0])
      ..add(common)
      ..add(List<int>.filled(10, 0))
      ..add(
        (ByteData(4)..setUint32(0, offset, Endian.little)).buffer.asUint8List(),
      )
      ..add(n);
  });
  final int cdAt = body.length;
  final int cdLen = directory.length;
  body.add(directory.takeBytes());
  return (BytesBuilder()
        ..add(body.takeBytes())
        ..add([0x50, 0x4b, 5, 6, 0, 0, 0, 0])
        ..add(
          (ByteData(14)
                ..setUint16(0, files.length, Endian.little)
                ..setUint16(2, files.length, Endian.little)
                ..setUint32(4, cdLen, Endian.little)
                ..setUint32(8, cdAt, Endian.little))
              .buffer
              .asUint8List(),
        ))
      .takeBytes();
}

/// The uncompressed bytes of every entry of [zip], by name.
Map<String, Uint8List> _entries(Uint8List zip) {
  final bd = ByteData.sublistView(zip);
  int eocd = zip.length - 22;
  while (bd.getUint32(eocd, Endian.little) != 0x06054b50) {
    eocd--;
  }
  final int count = bd.getUint16(eocd + 10, Endian.little);
  int cursor = bd.getUint32(eocd + 16, Endian.little);
  final result = <String, Uint8List>{};
  for (var i = 0; i < count; i++) {
    final int method = bd.getUint16(cursor + 10, Endian.little);
    final int compressed = bd.getUint32(cursor + 20, Endian.little);
    final int nameLen = bd.getUint16(cursor + 28, Endian.little);
    final int skip =
        bd.getUint16(cursor + 30, Endian.little) +
        bd.getUint16(cursor + 32, Endian.little);
    final int local = bd.getUint32(cursor + 42, Endian.little);
    final String name = utf8.decode(
      zip.sublist(cursor + 46, cursor + 46 + nameLen),
    );
    final int dataAt =
        local +
        30 +
        bd.getUint16(local + 26, Endian.little) +
        bd.getUint16(local + 28, Endian.little);
    final Uint8List raw = zip.sublist(dataAt, dataAt + compressed);
    result[name] = method == 0
        ? raw
        : Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
    cursor += 46 + nameLen + skip;
  }
  return result;
}

void main() {
  final String? tool = Platform.environment['ANDROID_BUNDLE'];
  if (tool == null) throw StateError('Missing ANDROID_BUNDLE');
  final String androidBundle = Runfiles.create().rlocation(tool);

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('split_apk_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String write(String name, List<int> bytes) {
    final file = File('${tmp.path}/$name')..createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return file.path;
  }

  /// A flutter_assets tree whose kernel blob holds [kernel].
  String assets(String name, String kernel) {
    write('$name/kernel_blob.bin', utf8.encode(kernel));
    write('$name/AssetManifest.bin', utf8.encode('manifest'));
    write('$name/fonts/a.ttf', List<int>.filled(300, 5));
    return '${tmp.path}/$name';
  }

  ProcessResult run(List<String> args) =>
      Process.runSync(androidBundle, ['apk-overlay', ...args]);

  String zipFile(String name, Map<String, List<int>> files) =>
      write(name, _storedZip(files));

  Uint8List buildBase(String out, {String? libsJar}) {
    final ProcessResult r = run([
      '--base',
      zipFile('base.apk', {
        'classes.dex': [1, 2, 3],
      }),
      '--native-libs-jar',
      libsJar ??
          zipFile('libs.jar', {
            'lib/arm64-v8a/libplugin.so': List.filled(64, 9),
          }),
      '--no-flutter-assets',
      '--output',
      '${tmp.path}/$out',
      '--debug',
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return File('${tmp.path}/$out').readAsBytesSync();
  }

  Uint8List buildPayload(String out, String assetsDir) {
    final ProcessResult r = run([
      '--split-name',
      _splitName,
      '--manifest',
      write('AndroidManifest.xml', utf8.encode(_manifest)),
      '--flutter-assets',
      assetsDir,
      '--output',
      '${tmp.path}/$out',
      '--debug',
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return File('${tmp.path}/$out').readAsBytesSync();
  }

  test('a kernel blob edit changes only the payload split', () {
    final String before = assets('assets_a', 'kernel v1');
    final String after = assets('assets_b', 'kernel v2');

    final Uint8List baseBefore = buildBase('base_a.apk');
    final Uint8List baseAfter = buildBase('base_b.apk');
    final Uint8List payloadBefore = buildPayload('payload_a.apk', before);
    final Uint8List payloadAfter = buildPayload('payload_b.apk', after);

    expect(baseAfter, equals(baseBefore));
    expect(payloadAfter, isNot(equals(payloadBefore)));
    expect(
      utf8.decode(
        _entries(payloadAfter)['assets/flutter_assets/kernel_blob.bin']!,
      ),
      'kernel v2',
    );
    expect(
      _entries(baseAfter).keys.where((n) => n.endsWith('kernel_blob.bin')),
      isEmpty,
      reason: 'the base split carries no kernel blob',
    );
  });

  test('each split is reproducible', () {
    final String dir = assets('assets', 'kernel');
    expect(buildBase('base_1.apk'), equals(buildBase('base_2.apk')));
    expect(
      buildPayload('payload_1.apk', dir),
      equals(buildPayload('payload_2.apk', dir)),
    );
  });

  test('the payload split is a code-free split of the base package', () {
    final Map<String, Uint8List> entries = _entries(
      buildPayload('payload.apk', assets('assets', 'kernel')),
    );
    expect(
      entries.keys,
      containsAll([
        'AndroidManifest.xml',
        'assets/flutter_assets/kernel_blob.bin',
        'assets/flutter_assets/AssetManifest.bin',
        'assets/flutter_assets/fonts/a.ttf',
      ]),
    );
    final Uint8List manifest = entries['AndroidManifest.xml']!;
    final bd = ByteData.sublistView(manifest);
    expect(bd.getUint16(0, Endian.little), 0x0003, reason: 'binary XML');
    expect(bd.getUint32(4, Endian.little), manifest.length);
    final utf16 = String.fromCharCodes(
      Uint16List.view(
        manifest.buffer,
        manifest.offsetInBytes,
        manifest.length ~/ 2,
      ),
    );
    expect(utf16, contains('dev.example.app'));
    expect(utf16, contains(_splitName));
    expect(utf16, contains('hasCode'));
    expect(utf16, contains('versionCode'));
  });

  test('the split shape refuses a base APK', () {
    final ProcessResult r = run([
      '--split-name',
      _splitName,
      '--base',
      zipFile('base.apk', {
        'classes.dex': [1, 2, 3],
      }),
      '--manifest',
      write('AndroidManifest.xml', utf8.encode(_manifest)),
      '--flutter-assets',
      assets('assets', 'kernel'),
      '--output',
      '${tmp.path}/out.apk',
    ]);
    expect(r.exitCode, isNot(0));
    expect(File('${tmp.path}/out.apk').existsSync(), isFalse);
  });

  test('a merged manifest without a package fails', () {
    final ProcessResult r = run([
      '--split-name',
      _splitName,
      '--manifest',
      write('AndroidManifest.xml', utf8.encode('<manifest/>')),
      '--flutter-assets',
      assets('assets', 'kernel'),
      '--output',
      '${tmp.path}/out.apk',
    ]);
    expect(r.exitCode, isNot(0));
    expect('${r.stderr}', contains('package'));
  });
}
