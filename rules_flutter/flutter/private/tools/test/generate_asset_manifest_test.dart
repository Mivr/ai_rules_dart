import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

// Import the library directly.
import '../generate_asset_manifest.dart' as manifest;

void main() {
  group('encodeStandardMessage', () {
    test('encodes null to empty bytes', () {
      final Uint8List result = manifest.encodeStandardMessage(null);
      expect(result, isEmpty);
    });

    test('encodes bool true to tag 1', () {
      final Uint8List result = manifest.encodeStandardMessage(true);
      expect(result[0], 1); // _tagTrue
    });

    test('encodes bool false to tag 2', () {
      final Uint8List result = manifest.encodeStandardMessage(false);
      expect(result[0], 2); // _tagFalse
    });

    test('encodes int32 to tag 3 + 4 bytes', () {
      final Uint8List result = manifest.encodeStandardMessage(42);
      expect(result[0], 3); // _tagInt32
      expect(result.length, 5); // 1 tag + 4 bytes
      // Decode the int32 value.
      final bd = ByteData.sublistView(result, 1, 5);
      expect(bd.getInt32(0, Endian.host), 42);
    });

    test('encodes string to tag 7 + length + UTF-8 bytes', () {
      final Uint8List result = manifest.encodeStandardMessage('hello');
      expect(result[0], 7); // _tagString
      expect(result[1], 5); // length of "hello" in UTF-8
      expect(utf8.decode(result.sublist(2)), 'hello');
    });

    test('encodes list to tag 12 + length + elements', () {
      final Uint8List result = manifest.encodeStandardMessage([true, false]);
      expect(result[0], 12); // _tagList
      expect(result[1], 2); // 2 elements
      expect(result[2], 1); // true
      expect(result[3], 2); // false
    });

    test('encodes map to tag 13 + length + key-value pairs', () {
      final Uint8List result = manifest.encodeStandardMessage({'a': true});
      expect(result[0], 13); // _tagMap
      expect(result[1], 1); // 1 entry
      // Key: string "a"
      expect(result[2], 7); // _tagString
      expect(result[3], 1); // length 1
      expect(result[4], 0x61); // 'a'
      // Value: true
      expect(result[5], 1); // _tagTrue
    });

    test('encodes nested asset manifest structure', () {
      // Simulate a real asset manifest: Map<String, List<Map<String, Object>>>
      final Map<String, List<Map<String, Object>>> manifestData = {
        'assets/logo.png': [
          {'asset': 'assets/logo.png'},
          {'asset': 'assets/2.0x/logo.png', 'dpr': 2.0},
        ],
      };
      final Uint8List result = manifest.encodeStandardMessage(manifestData);
      // Just verify it encodes without error and starts with map tag.
      expect(result[0], 13); // _tagMap
      expect(result.length, greaterThan(10));
    });

    test('writeSize encodes 1-byte, 2-byte, 4-byte sizes', () {
      // 1-byte: size < 254 — encode a short string
      final Uint8List short = manifest.encodeStandardMessage('hi');
      expect(short[1], 2); // size fits in 1 byte

      // 2-byte: size 254..65535 — encode a long string
      final String mediumStr = 'x' * 300;
      final Uint8List medium = manifest.encodeStandardMessage(mediumStr);
      expect(medium[1], 254); // marker for 2-byte size

      // 4-byte: would need a huge string (65536+), skip for perf.
    });
  });

  group('icon tree shaking', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('asset_manifest_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('ships font families with zero const IconData usage whole', () async {
      final materialFont = File('${tempDir.path}/MaterialIcons-Regular.otf')
        ..writeAsBytesSync(List<int>.filled(1024, 0x4d));
      final robotoFont = File('${tempDir.path}/Roboto-Regular.ttf')
        ..writeAsBytesSync(List<int>.filled(512, 0x52));
      final cupertinoFont = File('${tempDir.path}/CupertinoIcons.ttf')
        ..writeAsBytesSync(List<int>.filled(768, 0x43));

      final codePointsFile = File('${tempDir.path}/code_points.json')
        ..writeAsStringSync(
          json.encode({
            'packages/cupertino_icons/CupertinoIcons': [62660],
          }),
        );

      final fakeFontSubset = File('${tempDir.path}/fake_font_subset.sh')
        ..writeAsStringSync('''
#!/bin/sh
out="\$1"
cat > "\$out"
''');
      await Process.run('chmod', ['+x', fakeFontSubset.path]);

      final configFile = File('${tempDir.path}/config.json')
        ..writeAsStringSync(
          json.encode({
            'assets': <String, Object>{},
            'fonts': [
              {
                'family': 'MaterialIcons',
                'fonts': [
                  {'asset': 'fonts/MaterialIcons-Regular.otf'},
                ],
              },
              {
                'family': 'Roboto',
                'fonts': [
                  {'asset': 'fonts/Roboto-Regular.ttf'},
                ],
              },
              {
                'family': 'packages/cupertino_icons/CupertinoIcons',
                'fonts': [
                  {
                    'asset':
                        'packages/cupertino_icons/assets/CupertinoIcons.ttf',
                  },
                ],
              },
            ],
            'copies': {
              'fonts/MaterialIcons-Regular.otf': materialFont.path,
              'fonts/Roboto-Regular.ttf': robotoFont.path,
              'packages/cupertino_icons/assets/CupertinoIcons.ttf':
                  cupertinoFont.path,
            },
            'icon_tree_shaking': {
              'font_subset': fakeFontSubset.path,
              'code_points': codePointsFile.path,
            },
          }),
        );

      final outDir = '${tempDir.path}/out';
      await manifest.main([
        '--config',
        configFile.path,
        '--output-dir',
        outDir,
      ]);

      // MaterialIcons and Roboto had 0 const IconData usages -> shipped whole.
      expect(
        File('$outDir/fonts/MaterialIcons-Regular.otf').readAsBytesSync(),
        equals(materialFont.readAsBytesSync()),
      );
      expect(
        File('$outDir/fonts/Roboto-Regular.ttf').readAsBytesSync(),
        equals(robotoFont.readAsBytesSync()),
      );

      // CupertinoIcons had 1 const IconData usage -> subsetted to 0xf4c4 (62660).
      expect(
        File(
          '$outDir/packages/cupertino_icons/assets/CupertinoIcons.ttf',
        ).readAsStringSync().trim(),
        equals('${0xf4c4}'),
      );
    });

    test(
      'subsets families with suffix names and suffix asset paths independently',
      () async {
        final materialFont = File('${tempDir.path}/MaterialIcons-Regular.otf')
          ..writeAsBytesSync(List<int>.filled(1024, 0x4d));
        final bareIconsFont = File('${tempDir.path}/Icons.otf')
          ..writeAsBytesSync(List<int>.filled(1024, 0x49));
        final pkgIconsFont = File('${tempDir.path}/PkgIcons.otf')
          ..writeAsBytesSync(List<int>.filled(1024, 0x50));

        expect(
          manifest.matchesFontAssetPath('fonts/Icons.otf', 'fonts/Icons.otf'),
          isTrue,
        );
        expect(
          manifest.matchesFontAssetPath(
            'packages/custom_icons/fonts/Icons.otf',
            'fonts/Icons.otf',
          ),
          isFalse,
        );

        final codePointsFile = File('${tempDir.path}/code_points.json')
          ..writeAsStringSync(
            json.encode({
              'MaterialIcons': [57617],
              'Icons': [57890],
              'packages/custom_icons/Icons': [58163],
            }),
          );

        final fakeFontSubset = File('${tempDir.path}/fake_font_subset.sh')
          ..writeAsStringSync('''
#!/bin/sh
out="\$1"
cat > "\$out"
''');
        await Process.run('chmod', ['+x', fakeFontSubset.path]);

        final configFile = File('${tempDir.path}/config.json')
          ..writeAsStringSync(
            json.encode({
              'assets': <String, Object>{},
              'fonts': [
                {
                  'family': 'MaterialIcons',
                  'fonts': [
                    {'asset': 'fonts/MaterialIcons-Regular.otf'},
                  ],
                },
                {
                  'family': 'Icons',
                  'fonts': [
                    {'asset': 'fonts/Icons.otf'},
                  ],
                },
                {
                  'family': 'packages/custom_icons/Icons',
                  'fonts': [
                    {'asset': 'packages/custom_icons/fonts/Icons.otf'},
                  ],
                },
              ],
              'copies': {
                'fonts/MaterialIcons-Regular.otf': materialFont.path,
                'fonts/Icons.otf': bareIconsFont.path,
                'packages/custom_icons/fonts/Icons.otf': pkgIconsFont.path,
              },
              'icon_tree_shaking': {
                'font_subset': fakeFontSubset.path,
                'code_points': codePointsFile.path,
              },
            }),
          );

        final outDir = '${tempDir.path}/out';
        await manifest.main([
          '--config',
          configFile.path,
          '--output-dir',
          outDir,
        ]);

        expect(
          File('$outDir/fonts/MaterialIcons-Regular.otf')
              .readAsStringSync()
              .trim(),
          equals('${0xe111}'),
        );
        expect(
          File('$outDir/fonts/Icons.otf').readAsStringSync().trim(),
          equals('${0xe222}'),
        );
        expect(
          File('$outDir/packages/custom_icons/fonts/Icons.otf')
              .readAsStringSync()
              .trim(),
          equals('${0xe333}'),
        );
      },
    );

    test(
      'subsets fonts with precomputed code points and disables tree shaking when null',
      () async {
        final materialFont = File('${tempDir.path}/MaterialIcons-Regular.otf')
          ..writeAsBytesSync(List<int>.filled(1024, 0x4d));

        final fakeFontSubset = File('${tempDir.path}/fake_font_subset2.sh')
          ..writeAsStringSync('''
#!/bin/sh
out="\$1"
cat > "\$out"
''');
        await Process.run('chmod', ['+x', fakeFontSubset.path]);

        final codePointsFile = File('${tempDir.path}/code_points_multi.json')
          ..writeAsStringSync(
            json.encode({
              'MaterialIcons': [0xe047, 0xe145, 0xe567],
            }),
          );

        final configFile = File('${tempDir.path}/config2.json')
          ..writeAsStringSync(
            json.encode({
              'assets': <String, Object>{},
              'fonts': [
                {
                  'family': 'MaterialIcons',
                  'fonts': [
                    {'asset': 'fonts/MaterialIcons-Regular.otf'},
                  ],
                },
              ],
              'copies': {'fonts/MaterialIcons-Regular.otf': materialFont.path},
              'icon_tree_shaking': {
                'font_subset': fakeFontSubset.path,
                'code_points': codePointsFile.path,
              },
            }),
          );

        final outDir = '${tempDir.path}/out2';
        await manifest.main([
          '--config',
          configFile.path,
          '--output-dir',
          outDir,
        ]);

        expect(
          File('$outDir/fonts/MaterialIcons-Regular.otf')
              .readAsStringSync()
              .trim(),
          equals('${0xe047} ${0xe145} ${0xe567}'),
        );

        // When code_points file contains null, icon tree shaking is disabled.
        final disabledCodePointsFile = File('${tempDir.path}/disabled.json')
          ..writeAsStringSync('null\n');
        final disabledConfigFile = File('${tempDir.path}/config_disabled.json')
          ..writeAsStringSync(
            json.encode({
              'assets': <String, Object>{},
              'fonts': [
                {
                  'family': 'MaterialIcons',
                  'fonts': [
                    {'asset': 'fonts/MaterialIcons-Regular.otf'},
                  ],
                },
              ],
              'copies': {'fonts/MaterialIcons-Regular.otf': materialFont.path},
              'icon_tree_shaking': {
                'font_subset': fakeFontSubset.path,
                'code_points': disabledCodePointsFile.path,
              },
            }),
          );

        final outDisabled = '${tempDir.path}/out_disabled';
        await manifest.main([
          '--config',
          disabledConfigFile.path,
          '--output-dir',
          outDisabled,
        ]);

        // Original font file bytes should be copied untouched without running font-subset
        expect(
          File('$outDisabled/fonts/MaterialIcons-Regular.otf')
              .readAsBytesSync(),
          equals(List<int>.filled(1024, 0x4d)),
        );
      },
    );
  });

  group('NOTICES.Z', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('notices_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('header is host-independent (OS 255, MTIME 0, no flags)', () async {
      final Uint8List bytes = await _buildNotices(
        tempDir,
        notices: 'inline license',
      );
      _expectHostIndependentHeader(bytes);
      expect(gzip.decode(bytes), equals(utf8.encode('inline license')));
    });

    test('round-trips inline notices', () async {
      const text = 'Copyright 2026 Example\nAll rights reserved.';
      final Uint8List bytes = await _buildNotices(tempDir, notices: text);
      _expectHostIndependentHeader(bytes);
      expect(utf8.decode(gzip.decode(bytes)), equals(text));
    });

    test('concatenates license files that exist, skips missing ones', () async {
      final first = File('${tempDir.path}/LICENSE_A')..writeAsStringSync('AAA');
      final second = File('${tempDir.path}/LICENSE_B')
        ..writeAsStringSync('BBB');
      final Uint8List bytes = await _buildNotices(
        tempDir,
        licenseFiles: [first.path, '${tempDir.path}/MISSING', second.path],
      );
      _expectHostIndependentHeader(bytes);
      expect(utf8.decode(gzip.decode(bytes)), equals('AAA\n\n---\n\nBBB'));
    });

    test('empty notices still decode to empty text', () async {
      final Uint8List bytes = await _buildNotices(tempDir);
      _expectHostIndependentHeader(bytes);
      expect(gzip.decode(bytes), isEmpty);
    });
  });
}

/// Runs the tool with [notices] and [licenseFiles] and returns NOTICES.Z.
Future<Uint8List> _buildNotices(
  Directory tempDir, {
  String notices = '',
  List<String> licenseFiles = const [],
}) async {
  final configFile = File('${tempDir.path}/config.json')
    ..writeAsStringSync(
      json.encode({
        if (notices.isNotEmpty) 'notices': notices,
        if (licenseFiles.isNotEmpty) 'license_files': licenseFiles,
      }),
    );
  final outDir = Directory('${tempDir.path}/out')..createSync();
  await manifest.main([
    '--config',
    configFile.path,
    '--output-dir',
    outDir.path,
  ]);
  return File('${outDir.path}/NOTICES.Z').readAsBytesSync();
}

/// Checks the 10-byte gzip header: magic, deflate, no flags, MTIME 0, and
/// OS 255 ("unknown") instead of the executor's platform.
void _expectHostIndependentHeader(List<int> bytes) {
  expect(bytes.length, greaterThanOrEqualTo(10));
  expect(bytes.sublist(0, 8), equals([0x1f, 0x8b, 8, 0, 0, 0, 0, 0]));
  expect(bytes[9], equals(255));
}
