import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../apk_overlay.dart';
import '../zip_reader.dart' show readZipEntries, readZipRawEntries;
import '../zip_writer.dart' show ZipEntry, encodeDeterministicZip;

// A 50-byte text whose level-9 sizes straddle the aapt2 tenth line: C zlib
// reports 46 bytes (46 + 46 ~/ 10 == 50, so the reference deflates it) while
// Dart's own level 9 reports 48 (48 + 48 ~/ 10 > 50, stored). Any estimator
// other than the ported level 9 gets this entry's method wrong.
const String _estimatorTrap =
    'boundary method compression entry engine zip entry';

// Same bytes as the hello_world e2e fixture: 36 bytes raw, 35 deflated at
// level 9, so the reference stores it (35 + 35 ~/ 10 > 36) while a
// deflate-when-smaller rule would deflate it.
const String _marginalSmall = 'too close to the boundary to shrink\n';

void main() {
  group('aaptDeflates tenth line', () {
    test('stores entries whose deflated form saves nothing', () {
      expect(aaptDeflates(compressedSize: 100, rawSize: 100), isFalse);
      expect(aaptDeflates(compressedSize: 101, rawSize: 100), isFalse);
      expect(aaptDeflates(compressedSize: 2, rawSize: 0), isFalse);
    });

    test('stores savings of one or a few bytes', () {
      expect(aaptDeflates(compressedSize: 99, rawSize: 100), isFalse);
      expect(aaptDeflates(compressedSize: 95, rawSize: 100), isFalse);
      expect(aaptDeflates(compressedSize: 35, rawSize: 36), isFalse);
    });

    test('deflates exactly when a tenth of itself is saved', () {
      expect(aaptDeflates(compressedSize: 100, rawSize: 110), isTrue);
      expect(aaptDeflates(compressedSize: 100, rawSize: 111), isTrue);
      expect(aaptDeflates(compressedSize: 90, rawSize: 99), isTrue);
      expect(aaptDeflates(compressedSize: 100, rawSize: 109), isFalse);
      expect(aaptDeflates(compressedSize: 90, rawSize: 98), isFalse);
    });
  });

  group('aaptDeflatedSize level-9 probe', () {
    test('matches C zlib on the estimator-trap vector', () {
      final data = Uint8List.fromList(utf8.encode(_estimatorTrap));
      expect(data.length, 50);
      expect(aaptDeflatedSize(data), 46);
      expect(aaptDeflates(compressedSize: 46, rawSize: 50), isTrue);
    });

    test('matches C zlib on the marginal e2e vectors', () {
      final small = Uint8List.fromList(utf8.encode(_marginalSmall));
      expect(small.length, 36);
      expect(aaptDeflatedSize(small), 35);
      expect(aaptDeflates(compressedSize: 35, rawSize: 36), isFalse);
    });
  });

  group('spliceApkOverlay entry methods', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('apk_overlay_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    Map<String, int> spliceMethods({
      required Map<String, Uint8List> assets,
      required List<ZipEntry> jarEntries,
      List<int>? baseComment,
    }) {
      final basePath = '${tempDir.path}/base.apk';
      Uint8List baseBytes = encodeDeterministicZip([
        ZipEntry(
          path: 'AndroidManifest.xml',
          data: Uint8List.fromList([1]),
        ),
      ]);
      if (baseComment != null) {
        baseBytes = _withDeclaredComment(
          baseBytes,
          baseComment.length,
          baseComment,
        );
      }
      File(basePath).writeAsBytesSync(baseBytes);
      final jarPath = '${tempDir.path}/native_libs.jar';
      File(jarPath).writeAsBytesSync(encodeDeterministicZip(jarEntries));
      final assetsDir = Directory('${tempDir.path}/flutter_assets')
        ..createSync();
      for (final MapEntry<String, Uint8List> entry in assets.entries) {
        File('${assetsDir.path}/${entry.key}').writeAsBytesSync(entry.value);
      }
      final outPath = '${tempDir.path}/out.apk';
      spliceApkOverlay(
        baseApkPath: basePath,
        nativeLibsJarPath: jarPath,
        flutterAssetsDirPath: assetsDir.path,
        outputApkPath: outPath,
      );
      return {
        for (final e in readZipRawEntries(File(outPath).readAsBytesSync()))
          e.path: e.method,
      };
    }

    test('stores marginally compressible assets the reference stores', () {
      final Map<String, int> methods = spliceMethods(
        assets: {
          'marginal_small.txt': Uint8List.fromList(utf8.encode(_marginalSmall)),
          'plain.txt': Uint8List.fromList(List<int>.filled(1000, 7)),
          'logo.png': Uint8List.fromList(List<int>.filled(10000, 7)),
        },
        jarEntries: [
          ZipEntry(
            path: 'lib/arm64-v8a/libapp.so',
            data: Uint8List.fromList([0x7f, 0x45, 0x4c, 0x46, 1, 2, 3]),
            storeOnly: true,
          ),
        ],
      );
      expect(
        methods['assets/flutter_assets/marginal_small.txt'],
        0,
        reason: '35 bytes saved of 36 stay stored under the tenth line',
      );
      expect(methods['assets/flutter_assets/plain.txt'], 8);
      expect(methods['assets/flutter_assets/logo.png'], 0);
      expect(methods['lib/arm64-v8a/libapp.so'], 0);
    });

    test('deflates the estimator-trap vector the reference deflates', () {
      final Map<String, int> methods = spliceMethods(
        assets: {
          'trap.txt': Uint8List.fromList(utf8.encode(_estimatorTrap)),
        },
        jarEntries: const [],
      );
      expect(
        methods['assets/flutter_assets/trap.txt'],
        8,
        reason: '46 + 46 ~/ 10 == 50 clears the tenth line',
      );
    });

    test('splices a base APK whose comment holds a stray EOCD signature', () {
      final Map<String, int> methods = spliceMethods(
        assets: {
          'plain.txt': Uint8List.fromList([1, 2, 3]),
        },
        jarEntries: const [],
        baseComment: [
          ...utf8.encode('note '),
          0x50, 0x4B, 0x05, 0x06, // stray EOCD signature, not the record
          0, 0, 1, 2, 3,
        ],
      );
      expect(methods['AndroidManifest.xml'], isNotNull);
      expect(methods['assets/flutter_assets/plain.txt'], isNotNull);
    });
  });

  group('EOCD finder and entry names', () {
    test('ignores a stray EOCD signature inside the archive comment', () {
      final Uint8List zip = encodeDeterministicZip([
        ZipEntry(path: 'a.txt', data: Uint8List.fromList([1, 2, 3])),
      ]);
      final Uint8List commented = _withDeclaredComment(zip, 14, [
        ...utf8.encode('note '),
        0x50,
        0x4B,
        0x05,
        0x06,
        0,
        0,
        1,
        2,
        3,
      ]);
      expect(
        [for (final e in readZipRawEntries(commented)) e.path],
        ['a.txt'],
      );
      expect(
        [for (final e in readZipEntries(commented)) e.path],
        ['a.txt'],
      );
    });

    test('rejects an EOCD whose comment does not reach the end of file', () {
      final Uint8List zip = encodeDeterministicZip([
        ZipEntry(path: 'a.txt', data: Uint8List.fromList([1])),
      ]);
      final Uint8List truncated = _withDeclaredComment(zip, 16, [1, 2, 3]);
      expect(
        () => readZipRawEntries(truncated),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('EOCD'),
          ),
        ),
      );
    });

    test('decodes a CP437 name when bit 11 is clear', () {
      // 'cp437_' + 0x82 (U+00E9 in CP437, invalid alone in UTF-8) + '.txt'.
      final Uint8List zip = _storedZip(
        [0x63, 0x70, 0x34, 0x33, 0x37, 0x5F, 0x82, 0x2E, 0x74, 0x78, 0x74],
        0,
        Uint8List.fromList([9]),
      );
      expect(readZipRawEntries(zip).single.path, 'cp437_é.txt');
    });

    test('decodes a UTF-8 name when bit 11 is set', () {
      final Uint8List nameBytes = utf8.encode('café_☃.txt');
      final Uint8List zip = _storedZip(
        nameBytes,
        0x0800,
        Uint8List.fromList([9]),
      );
      expect(readZipRawEntries(zip).single.path, 'café_☃.txt');
    });

    test('names the entry whose UTF-8 name is malformed', () {
      final Uint8List zip = _storedZip(
        [0x62, 0x61, 0x64, 0xFF],
        0x0800,
        Uint8List.fromList([9]),
      );
      expect(
        () => readZipRawEntries(zip),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('offset 35'), contains('not valid UTF-8')),
          ),
        ),
      );
    });
  });

  group('aaptDecisionSize fast path', () {
    test('fast decisions match the exact port over the fuzz corpus', () {
      var checked = 0;
      for (final Uint8List data in _decisionCorpus()) {
        final int fastSize = ZLibEncoder(raw: true).convert(data).length;
        final bool fast = aaptDeflates(
          compressedSize: aaptDecisionSize(data, fastSize),
          rawSize: data.length,
        );
        final bool exact = aaptDeflates(
          compressedSize: aaptDeflatedSize(data),
          rawSize: data.length,
        );
        expect(
          fast,
          exact,
          reason:
              'raw=${data.length} fastSize=$fastSize '
              'exact=${aaptDeflatedSize(data)}',
        );
        checked++;
      }
      expect(checked, greaterThan(200));
    });
  });
}

/// Appends [actual] comment bytes to a comment-free ZIP while declaring
/// [declaredLength] in the EOCD: equal lengths for a well-formed comment, a
/// longer declaration for a comment that never reaches the end of the file.
Uint8List _withDeclaredComment(
  Uint8List zip,
  int declaredLength,
  List<int> actual,
) {
  final bytes = Uint8List.fromList([...zip, ...actual]);
  ByteData.sublistView(bytes).setUint16(
    bytes.length - actual.length - 2,
    declaredLength,
    Endian.little,
  );
  return bytes;
}

/// A minimal one-entry stored archive with verbatim [nameBytes] and [flags],
/// for entry-name cases the deterministic writer cannot express.
Uint8List _storedZip(List<int> nameBytes, int flags, Uint8List content) {
  final local = ByteData(30 + nameBytes.length)
    ..setUint32(0, 0x04034b50, Endian.little)
    ..setUint16(4, 20, Endian.little)
    ..setUint16(6, flags, Endian.little)
    ..setUint16(8, 0, Endian.little)
    ..setUint32(18, content.length, Endian.little)
    ..setUint32(22, content.length, Endian.little)
    ..setUint16(26, nameBytes.length, Endian.little);
  local.buffer.asUint8List().setRange(30, 30 + nameBytes.length, nameBytes);
  final central = ByteData(46 + nameBytes.length)
    ..setUint32(0, 0x02014b50, Endian.little)
    ..setUint16(4, (3 << 8) | 20, Endian.little)
    ..setUint16(6, 20, Endian.little)
    ..setUint16(8, flags, Endian.little)
    ..setUint16(10, 0, Endian.little)
    ..setUint32(20, content.length, Endian.little)
    ..setUint32(24, content.length, Endian.little)
    ..setUint16(28, nameBytes.length, Endian.little)
    ..setUint32(38, 0x81A4 << 16, Endian.little)
    ..setUint32(42, 0, Endian.little);
  central.buffer.asUint8List().setRange(46, 46 + nameBytes.length, nameBytes);
  final int cdOffset = 30 + nameBytes.length + content.length;
  final eocd = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, 1, Endian.little)
    ..setUint16(10, 1, Endian.little)
    ..setUint32(12, 46 + nameBytes.length, Endian.little)
    ..setUint32(16, cdOffset, Endian.little);
  return Uint8List.fromList([
    ...local.buffer.asUint8List(),
    ...content,
    ...central.buffer.asUint8List(),
    ...eocd.buffer.asUint8List(),
  ]);
}

/// Deterministic hostile corpus for the fast-path parity check: every size
/// from empty to 100 KB across fills, random alphabets, periods, text and
/// sparse patterns, seeded so the run is reproducible.
Iterable<Uint8List> _decisionCorpus() sync* {
  const sizes = [
    0,
    1,
    2,
    3,
    4,
    5,
    7,
    8,
    9,
    15,
    16,
    17,
    19,
    23,
    24,
    25,
    31,
    32,
    33,
    36,
    50,
    56,
    57,
    60,
    63,
    64,
    65,
    100,
    127,
    128,
    129,
    150,
    200,
    220,
    242,
    255,
    256,
    257,
    300,
    512,
    1000,
    1024,
    2048,
    4095,
    4096,
    4097,
    5000,
    8192,
    16384,
    32768,
    65536,
    100000,
  ];
  final Uint8List text = utf8.encode(
    'boundary method compression entry engine ',
  );
  for (final size in sizes) {
    final random = Random(0xA47A9 + size);
    final patterns = <Uint8List>[
      Uint8List(size),
      Uint8List.fromList(List<int>.filled(size, 0xFF)),
      Uint8List.fromList(
        List<int>.generate(size, (_) => random.nextInt(256)),
      ),
      Uint8List.fromList(
        List<int>.generate(size, (_) => random.nextInt(16)),
      ),
      Uint8List.fromList(
        List<int>.generate(size, (_) => random.nextInt(4)),
      ),
      Uint8List.fromList(
        List<int>.generate(size, (i) => text[i % text.length]),
      ),
      Uint8List.fromList(
        List<int>.generate(size, (i) => i % 251),
      ),
      Uint8List.fromList(
        List<int>.generate(
          size,
          (i) => i % 32 == 0 ? random.nextInt(256) : 0,
        ),
      ),
    ];
    // Keep the big end of the corpus cheap: two patterns past 32 KB.
    yield* (size > 32768 ? patterns.sublist(2, 4) : patterns);
  }
}
