// Opens the release web build and the release APK and counts the glyphs of
// their MaterialIcons font: the full font has 8661, a shaken one what the
// program's constants name. Stock 3.47.7 keeps 67 in this project's web build
// (the shaker reads the whole CFE kernel, framework included) and 8 in its APK
// (the AOT kernel, after tree shaking). Reads the APK's ZIP directory and the
// font's `maxp` table with `dart:io` alone.
import 'dart:io';
import 'dart:typed_data';

const _apkFont = 'assets/flutter_assets/fonts/MaterialIcons-Regular.otf';
const _webFont = 'assets/fonts/MaterialIcons-Regular.otf';

// Stock's counts with room for a framework patch; far below the full font.
const _apkAtMost = 16;
const _webAtMost = 128;

void main() {
  final env = Platform.environment;
  final failures = <String>[
    ..._check(
      'release APK',
      _zipEntry(env['RELEASE_APK']!, _apkFont),
      _apkAtMost,
    ),
    ..._check(
      'release web build',
      File('${env['WEB_DIR']!}/$_webFont').readAsBytesSync(),
      _webAtMost,
    ),
  ];
  if (failures.isNotEmpty) {
    stderr.writeln(failures.join('\n'));
    exit(1);
  }
}

List<String> _check(String where, Uint8List font, int atMost) {
  final glyphs = _glyphCount(font);
  stdout.writeln('$where: MaterialIcons has $glyphs glyphs');
  return glyphs <= atMost
      ? const []
      : ['FAIL: $where: MaterialIcons has $glyphs glyphs (shaken: <= $atMost)'];
}

int _glyphCount(Uint8List font) {
  final data = ByteData.sublistView(font);
  for (var i = 0; i < data.getUint16(4); i++) {
    final record = 12 + 16 * i;
    if (String.fromCharCodes(font.sublist(record, record + 4)) == 'maxp') {
      return data.getUint16(data.getUint32(record + 8) + 4);
    }
  }
  throw const FormatException('no maxp table');
}

Uint8List _zipEntry(String path, String name) {
  final zip = File(path).readAsBytesSync();
  final data = ByteData.sublistView(zip);
  var eocd = zip.length - 22;
  while (data.getUint32(eocd, Endian.little) != 0x06054b50) {
    eocd--;
  }
  var cursor = data.getUint32(eocd + 16, Endian.little);
  for (var i = 0; i < data.getUint16(eocd + 10, Endian.little); i++) {
    final nameLength = data.getUint16(cursor + 28, Endian.little);
    final entry = String.fromCharCodes(
      zip.sublist(cursor + 46, cursor + 46 + nameLength),
    );
    if (entry == name) {
      final method = data.getUint16(cursor + 10, Endian.little);
      final size = data.getUint32(cursor + 20, Endian.little);
      final local = data.getUint32(cursor + 42, Endian.little);
      final start =
          local +
          30 +
          data.getUint16(local + 26, Endian.little) +
          data.getUint16(local + 28, Endian.little);
      final bytes = zip.sublist(start, start + size);
      return method == 0
          ? bytes
          : Uint8List.fromList(ZLibDecoder(raw: true).convert(bytes));
    }
    cursor +=
        46 +
        nameLength +
        data.getUint16(cursor + 30, Endian.little) +
        data.getUint16(cursor + 32, Endian.little);
  }
  throw FileSystemException('no $name', path);
}
