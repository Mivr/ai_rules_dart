/// Readers for the Android release artifacts, written with `dart:io` and
/// `dart:typed_data` alone: a ZIP central directory (an APK), a 64-bit
/// little-endian ELF section table, and the OpenType table directory. No host
/// `unzip` or `readelf` is consulted.
library;

import 'dart:io';
import 'dart:typed_data';

/// Returns the entries of the ZIP archive [zip] by name, inflating each one.
///
/// Throws a [FormatException] naming [path] when the archive is malformed.
Map<String, Uint8List> readZipEntries(Uint8List zip, String path) {
  final data = ByteData.sublistView(zip);
  final eocd = _findEndOfCentralDirectory(zip, path);
  final count = data.getUint16(eocd + 10, Endian.little);
  var cursor = data.getUint32(eocd + 16, Endian.little);
  final entries = <String, Uint8List>{};
  for (var i = 0; i < count; i++) {
    if (cursor + 46 > zip.length ||
        data.getUint32(cursor, Endian.little) != 0x02014b50) {
      throw FormatException('bad central directory entry $i in $path');
    }
    final nameLength = data.getUint16(cursor + 28, Endian.little);
    final name = String.fromCharCodes(
      zip.sublist(cursor + 46, cursor + 46 + nameLength),
    );
    entries[name] = _readEntry(zip, data, cursor, name, path);
    cursor +=
        46 +
        nameLength +
        data.getUint16(cursor + 30, Endian.little) +
        data.getUint16(cursor + 32, Endian.little);
  }
  return entries;
}

int _findEndOfCentralDirectory(Uint8List zip, String path) {
  final data = ByteData.sublistView(zip);
  for (var i = zip.length - 22; i >= 0; i--) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) return i;
  }
  throw FormatException('no end of central directory in $path');
}

Uint8List _readEntry(
  Uint8List zip,
  ByteData data,
  int cursor,
  String name,
  String path,
) {
  final method = data.getUint16(cursor + 10, Endian.little);
  final compressed = data.getUint32(cursor + 20, Endian.little);
  final local = data.getUint32(cursor + 42, Endian.little);
  if (data.getUint32(local, Endian.little) != 0x04034b50) {
    throw FormatException('bad local header for $name in $path');
  }
  final start =
      local +
      30 +
      data.getUint16(local + 26, Endian.little) +
      data.getUint16(local + 28, Endian.little);
  final raw = Uint8List.sublistView(zip, start, start + compressed);
  switch (method) {
    case 0:
      return raw;
    case 8:
      return Uint8List.fromList(ZLibCodec(raw: true).decode(raw));
  }
  throw FormatException('unsupported compression $method for $name in $path');
}

/// Returns the section names of the 64-bit little-endian ELF [elf].
///
/// Throws a [FormatException] naming [path] when [elf] is not one.
List<String> readElfSectionNames(Uint8List elf, String path) {
  if (elf.length < 64 ||
      elf[0] != 0x7f ||
      elf[1] != 0x45 ||
      elf[2] != 0x4c ||
      elf[3] != 0x46) {
    throw FormatException('$path is not an ELF file');
  }
  if (elf[4] != 2 || elf[5] != 1) {
    throw FormatException('$path is not a 64-bit little-endian ELF file');
  }
  final data = ByteData.sublistView(elf);
  final tableOffset = data.getUint64(0x28, Endian.little);
  final entrySize = data.getUint16(0x3a, Endian.little);
  final count = data.getUint16(0x3c, Endian.little);
  final namesIndex = data.getUint16(0x3e, Endian.little);
  if (tableOffset + entrySize * count > elf.length || namesIndex >= count) {
    throw FormatException('$path has a section table outside the file');
  }
  int field(int index, int offset, {int width = 8}) {
    final at = tableOffset + entrySize * index + offset;
    return width == 4
        ? data.getUint32(at, Endian.little)
        : data.getUint64(at, Endian.little);
  }

  final namesStart = field(namesIndex, 0x18);
  return [
    for (var i = 0; i < count; i++)
      _cString(elf, namesStart + field(i, 0, width: 4)),
  ];
}

String _cString(Uint8List bytes, int offset) {
  final end = bytes.indexOf(0, offset);
  return String.fromCharCodes(bytes.sublist(offset, end < 0 ? null : end));
}

/// Returns the glyph count (`maxp.numGlyphs`) of the OpenType font [font].
///
/// Throws a [FormatException] naming [path] when [font] has no `maxp` table.
int readFontGlyphCount(Uint8List font, String path) {
  final data = ByteData.sublistView(font);
  if (font.length < 12) throw FormatException('$path is too small for a font');
  final tables = data.getUint16(4);
  for (var i = 0; i < tables; i++) {
    final record = 12 + 16 * i;
    if (record + 16 > font.length) break;
    if (String.fromCharCodes(font.sublist(record, record + 4)) == 'maxp') {
      return data.getUint16(data.getUint32(record + 8) + 4);
    }
  }
  throw FormatException('$path has no maxp table');
}

/// Returns how many times [needle] occurs in [haystack] as raw bytes.
int countOccurrences(Uint8List haystack, String needle) {
  final bytes = needle.codeUnits;
  var found = 0;
  for (var i = 0; i + bytes.length <= haystack.length; i++) {
    var j = 0;
    while (j < bytes.length && haystack[i + j] == bytes[j]) {
      j++;
    }
    if (j == bytes.length) found++;
  }
  return found;
}
