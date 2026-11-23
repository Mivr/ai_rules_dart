/// Generates Flutter asset bundle files (AssetManifest.bin, FontManifest.json).
///
/// This tool implements the StandardMessageCodec binary encoding used by
/// Flutter's AssetManifest.bin format. It has no package dependencies and
/// runs with the bare Dart SDK.
///
/// Usage:
///   dart generate_asset_manifest.dart --config <path> --output-dir <path>
///
/// The config file is JSON with this schema:
/// {
///   "assets": {
///     "assets/image.png": [
///       {"asset": "assets/image.png"},
///       {"asset": "assets/2.0x/image.png", "dpr": 2.0}
///     ]
///   },
///   "fonts": [...],
///   "copies": {"dest/path": "source/path", ...},
///   "notices": "License text..."
/// }
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// -- StandardMessageCodec binary encoding ------------------------------------
// This reimplements Flutter's StandardMessageCodec.encodeMessage() so we can
// produce AssetManifest.bin without depending on package:flutter.

const int _tagNull = 0;
const int _tagTrue = 1;
const int _tagFalse = 2;
const int _tagInt32 = 3;
const int _tagInt64 = 4;
const int _tagFloat64 = 6;
const int _tagString = 7;
const int _tagList = 12;
const int _tagMap = 13;

class _WriteBuffer {
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _position = 0;

  void putUint8(int value) {
    _builder.addByte(value);
    _position++;
  }

  void putBytes(List<int> bytes) {
    _builder.add(bytes);
    _position += bytes.length;
  }

  void _putByteData(ByteData data) {
    _builder.add(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    _position += data.lengthInBytes;
  }

  void putInt32(int value) {
    final d = ByteData(4)..setInt32(0, value, Endian.host);
    _putByteData(d);
  }

  void putInt64(int value) {
    final d = ByteData(8)..setInt64(0, value, Endian.host);
    _putByteData(d);
  }

  void putFloat64(double value) {
    // Align to 8-byte boundary.
    final int pad = (8 - (_position % 8)) % 8;
    for (var i = 0; i < pad; i++) {
      _builder.addByte(0);
    }
    _position += pad;
    final d = ByteData(8)..setFloat64(0, value, Endian.host);
    _putByteData(d);
  }

  Uint8List done() => _builder.toBytes();
}

void _writeSize(_WriteBuffer buf, int size) {
  if (size < 254) {
    buf.putUint8(size);
  } else if (size < 0x10000) {
    buf.putUint8(254);
    final d = ByteData(2)..setUint16(0, size, Endian.host);
    buf._putByteData(d);
  } else {
    buf.putUint8(255);
    final d = ByteData(4)..setUint32(0, size, Endian.host);
    buf._putByteData(d);
  }
}

void _writeValue(_WriteBuffer buf, Object? value) {
  if (value == null) {
    buf.putUint8(_tagNull);
  } else if (value is bool) {
    buf.putUint8(value ? _tagTrue : _tagFalse);
  } else if (value is int) {
    if (value >= -0x80000000 && value <= 0x7fffffff) {
      buf.putUint8(_tagInt32);
      buf.putInt32(value);
    } else {
      buf.putUint8(_tagInt64);
      buf.putInt64(value);
    }
  } else if (value is double) {
    buf.putUint8(_tagFloat64);
    buf.putFloat64(value);
  } else if (value is String) {
    buf.putUint8(_tagString);
    final Uint8List encoded = utf8.encode(value);
    _writeSize(buf, encoded.length);
    buf.putBytes(encoded);
  } else if (value is List) {
    buf.putUint8(_tagList);
    _writeSize(buf, value.length);
    for (final Object? item in value) {
      _writeValue(buf, item);
    }
  } else if (value is Map) {
    buf.putUint8(_tagMap);
    _writeSize(buf, value.length);
    for (final MapEntry<dynamic, dynamic> entry in value.entries) {
      _writeValue(buf, entry.key);
      _writeValue(buf, entry.value);
    }
  } else {
    throw ArgumentError('Unsupported type: ${value.runtimeType}');
  }
}

Uint8List encodeStandardMessage(Object? message) {
  if (message == null) return Uint8List(0);
  final buf = _WriteBuffer();
  _writeValue(buf, message);
  return buf.done();
}

// -- Icon tree shaking helpers -----------------------------------------------

/// Returns true if [copyKey] matches [assetPath] exactly.
bool matchesFontAssetPath(String copyKey, String assetPath) {
  return copyKey == assetPath;
}

/// Builds a map from font `family` name to all declared `asset` paths in
/// [fonts] (`FontManifest.json` entries).
Map<String, Set<String>> buildFontFamilyToAssets(List<dynamic> fonts) {
  final result = <String, Set<String>>{};
  for (final entry in fonts) {
    final m = entry as Map<String, dynamic>;
    final family = m['family'] as String?;
    final List<dynamic> fontList = m['fonts'] as List<dynamic>? ?? [];
    if (family != null && fontList.isNotEmpty) {
      final Set<String> assets = result.putIfAbsent(family, () => <String>{});
      for (final fontEntry in fontList) {
        final asset = (fontEntry as Map<String, dynamic>)['asset'] as String?;
        if (asset != null) {
          assets.add(asset);
        }
      }
    }
  }
  return result;
}

/// Run font-subset, piping code points via stdin. Returns true on success.
Future<bool> _runFontSubset(
  String fontSubsetBin,
  String outputPath,
  String inputPath,
  String codePoints,
) async {
  // font-subset reads code points from stdin (space-separated, newline-terminated).
  final Process process = await Process.start(fontSubsetBin, [
    outputPath,
    inputPath,
  ]);
  final Future<String> stderrFuture = process.stderr
      .transform(utf8.decoder)
      .join();
  try {
    process.stdin.writeln(codePoints);
    await process.stdin.flush();
    await process.stdin.close();
  } on Exception {
    // Handled by checking exit code below.
  }

  final int exitCode = await process.exitCode;
  final String errText = await stderrFuture;
  if (exitCode != 0) {
    stderr.writeln('font-subset failed for $inputPath (exit $exitCode)');
    if (errText.isNotEmpty) {
      stderr.writeln(errText);
    }
    return false;
  }
  return true;
}

// -- Main --------------------------------------------------------------------

/// Tool entry point for generating the Flutter asset manifest and subsetting icon fonts.
Future<void> main(List<String> args) async {
  final ({String configPath, String outputDir}) parsed = _parseManifestArgs(
    args,
  );
  final String outputDir = parsed.outputDir;

  final config = json.decode(
    File(parsed.configPath).readAsStringSync(),
  ) as Map<String, dynamic>;

  // Create output directory.
  Directory(outputDir).createSync(recursive: true);

  _writeManifestFiles(config, outputDir);

  final List<dynamic> fonts = config['fonts'] as List<dynamic>? ?? [];
  final iconTreeShaking = config['icon_tree_shaking'] as Map<String, dynamic>?;
  final ({Map<String, Set<String>>? families, Map<String, Set<int>>? used})
  codePoints = await _collectIconCodePoints(iconTreeShaking, fonts);

  final Map<String, dynamic> copies =
      config['copies'] as Map<String, dynamic>? ?? {};
  for (final MapEntry<String, dynamic> entry in copies.entries) {
    await _copyOneAsset(
      entry,
      outputDir,
      iconTreeShaking,
      codePoints.used,
      codePoints.families,
    );
  }

  _writeNotices(config, outputDir);
}

/// The `--config` and `--output-dir` flags in [args], or usage and exit.
({String configPath, String outputDir}) _parseManifestArgs(List<String> args) {
  String? configPath;
  String? outputDir;

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--config' && i + 1 < args.length) {
      configPath = args[++i];
    } else if (args[i] == '--output-dir' && i + 1 < args.length) {
      outputDir = args[++i];
    }
  }

  if (configPath == null || outputDir == null) {
    stderr.writeln(
      'Usage: dart generate_asset_manifest.dart --config <path> --output-dir <path>',
    );
    exit(1);
  }
  return (configPath: configPath, outputDir: outputDir);
}

/// Writes `AssetManifest.bin`, its web `AssetManifest.bin.json` wrapper and
/// `FontManifest.json` for [config] into [outputDir].
void _writeManifestFiles(Map<String, dynamic> config, String outputDir) {
  // -- AssetManifest.bin -----------------------------------------------------
  final Map<String, dynamic> assets =
      config['assets'] as Map<String, dynamic>? ?? {};
  final manifestMap = <String, Object>{};
  for (final MapEntry<String, dynamic> entry in assets.entries) {
    final List<Map<String, Object>> variants = (entry.value as List<dynamic>)
        .map((v) {
          final variant = v as Map<String, dynamic>;
          final result = <String, Object>{'asset': variant['asset'] as String};
          if (variant.containsKey('dpr')) {
            result['dpr'] = (variant['dpr'] as num).toDouble();
          }
          return result;
        })
        .toList();
    manifestMap[entry.key] = variants;
  }
  final Uint8List binBytes = encodeStandardMessage(manifestMap);
  File('$outputDir/AssetManifest.bin').writeAsBytesSync(binBytes);

  // AssetManifest.bin.json — base64-encoded JSON wrapper for web.
  File('$outputDir/AssetManifest.bin.json').writeAsStringSync(
    json.encode(base64.encode(binBytes)),
  );

  // -- FontManifest.json -----------------------------------------------------
  final List<dynamic> fonts = config['fonts'] as List<dynamic>? ?? [];
  File('$outputDir/FontManifest.json').writeAsStringSync(json.encode(fonts));
}

/// The icon code points for [fonts], for subsetting.
///
/// Reads the pre-extracted code points JSON from [iconTreeShaking]['code_points'];
/// a null [iconTreeShaking], no fonts or missing `code_points` mean no
/// subsetting. A null decoded value disables icon tree shaking.
Future<({Map<String, Set<int>>? used, Map<String, Set<String>>? families})>
_collectIconCodePoints(
  Map<String, dynamic>? iconTreeShaking,
  List<dynamic> fonts,
) async {
  if (iconTreeShaking == null || fonts.isEmpty) {
    return (used: null, families: null);
  }
  final codePointsPath = iconTreeShaking['code_points'] as String?;
  if (codePointsPath == null) {
    return (used: null, families: null);
  }
  final String raw = File(codePointsPath).readAsStringSync().trim();
  final dynamic decoded = json.decode(raw);
  if (decoded == null) {
    return (used: null, families: null);
  }
  final usedCodePoints = <String, Set<int>>{};
  for (final MapEntry<String, dynamic> entry
      in (decoded as Map<String, dynamic>).entries) {
    final list = entry.value as List<dynamic>;
    usedCodePoints[entry.key] = list.map((e) => (e as num).toInt()).toSet();
  }
  return (used: usedCodePoints, families: buildFontFamilyToAssets(fonts));
}

/// Copies one [entry] of the config `copies` map into [outputDir], subsetting
/// the font when [usedCodePoints] covers its family.
Future<void> _copyOneAsset(
  MapEntry<String, dynamic> entry,
  String outputDir,
  Map<String, dynamic>? iconTreeShaking,
  Map<String, Set<int>>? usedCodePoints,
  Map<String, Set<String>>? fontFamilyToAssets,
) async {
  final dest = '$outputDir/${entry.key}';
  Directory(File(dest).parent.path).createSync(recursive: true);

  // Check if this asset should be subsetted.
  if (usedCodePoints != null &&
      fontFamilyToAssets != null &&
      iconTreeShaking != null) {
    final bool subsetted = await _subsetFontAsset(
      entry,
      dest,
      iconTreeShaking,
      usedCodePoints,
      fontFamilyToAssets,
    );
    if (subsetted) return;
  }

  File(entry.value as String).copySync(dest);
}

/// Subsets the font [entry] into [dest] when its family has used code points.
///
/// Returns whether the asset was subsetted (a subsetting failure exits).
Future<bool> _subsetFontAsset(
  MapEntry<String, dynamic> entry,
  String dest,
  Map<String, dynamic> iconTreeShaking,
  Map<String, Set<int>> usedCodePoints,
  Map<String, Set<String>> fontFamilyToAssets,
) async {
  final fontSubsetBin = iconTreeShaking['font_subset'] as String;
  String? matchedFamily;
  for (final MapEntry<String, Set<String>> famEntry
      in fontFamilyToAssets.entries) {
    if (famEntry.value.any(
      (assetPath) => matchesFontAssetPath(entry.key, assetPath),
    )) {
      matchedFamily = famEntry.key;
      break;
    }
  }

  if (matchedFamily == null) return false;
  final Set<int>? codePoints = usedCodePoints[matchedFamily];
  if (codePoints == null || codePoints.isEmpty) return false;
  // Run font-subset: code points are piped via stdin.
  final List<int> sortedCodePoints = codePoints.toList()..sort();
  final String codePointStr = sortedCodePoints
      .map((cp) => cp.toString())
      .join(' ');
  final bool success = await _runFontSubset(
    fontSubsetBin,
    dest,
    entry.value as String,
    codePointStr,
  );
  if (!success) {
    exit(1);
  }
  final int inputSize = File(entry.value as String).lengthSync();
  final int outputSize = File(dest).lengthSync();
  final String reduction = ((inputSize - outputSize) / inputSize * 100)
      .toStringAsFixed(1);
  stderr.writeln(
    'Font "${entry.key}" tree-shaken: $inputSize -> $outputSize bytes ($reduction% reduction).',
  );
  return true;
}

/// Encodes [bytes] as one gzip member with a host-independent header.
///
/// `dart:convert`'s `gzip` fills the header's OS byte from the platform the
/// Dart SDK was built for (3 on Linux, 19 on macOS, 10 on Windows), so the
/// same input compresses to different bytes on different executors. The
/// compressed payload and the trailer stay as written; only byte 9 becomes
/// 255 ("unknown", RFC 1952 section 2.3.1). MTIME stays 0 with no optional
/// fields, as the encoder already writes them.
Uint8List encodeNoticesGzip(List<int> bytes) {
  final encoded = Uint8List.fromList(gzip.encode(bytes));
  encoded[9] = 255;
  return encoded;
}

/// Writes `NOTICES.Z`: the inline license text plus every license file that
/// exists, gzipped.
void _writeNotices(Map<String, dynamic> config, String outputDir) {
  // Collect license text from inline string and/or license file paths.
  final noticesBuf = StringBuffer();
  final String notices = config['notices'] as String? ?? '';
  if (notices.isNotEmpty) {
    noticesBuf.write(notices);
  }
  final List<dynamic> licenseFiles =
      config['license_files'] as List<dynamic>? ?? [];
  for (final path in licenseFiles) {
    final file = File(path as String);
    if (file.existsSync()) {
      if (noticesBuf.isNotEmpty) noticesBuf.write('\n\n---\n\n');
      noticesBuf.write(file.readAsStringSync());
    }
  }
  File('$outputDir/NOTICES.Z').writeAsBytesSync(
    encodeNoticesGzip(utf8.encode(noticesBuf.toString())),
  );
}
