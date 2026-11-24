/// Deterministic ZIP archive readers.
///
/// Decodes the archives written by `zip_writer.dart`: full inflation into
/// `ZipEntry` values, or raw header-only reads into `ZipRawEntry` values
/// for splicing without recompression.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'zip_writer.dart'
    show
        CrcAndSizeSink,
        ZipEntry,
        getUint64LE,
        streamingFileThreshold,
        zip64HeaderId,
        zip64Limit32;

/// Central-directory record fields shared by the ZIP readers.
typedef _CentralRecord = ({
  String path,
  int method,
  int flags,
  int crc,
  int compressedSize,
  int uncompressedSize,
  int externalAttrs,
  int localOffset,
  int nextPos,
});

/// Locates the End of Central Directory record (`0x06054b50`) in [zipBytes].
///
/// A candidate counts only when it is structurally valid: its comment length
/// reaches exactly the end of the file. A bare backward scan would take an
/// `0x06054b50` stamped inside the archive comment for the record itself. The
/// record must lie within the last 64 KiB plus its 22 bytes, the most an
/// archive comment may hold.
int findEocdOffset(Uint8List zipBytes) {
  final bd = ByteData.sublistView(zipBytes);
  for (int i = zipBytes.length - 22; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50 &&
        i + 22 + bd.getUint16(i + 20, Endian.little) == zipBytes.length) {
      return i;
    }
    // The EOCD must lie within the last 64 KiB + 22 bytes; stop early.
    if (i < zipBytes.length - 22 - 65536) break;
  }
  throw FormatException('Invalid ZIP archive: EOCD signature not found.');
}

/// Code points for CP437 bytes `0x80`-`0xFF`, in order.
///
/// The ZIP spec defaults entry names to CP437 unless general-purpose bit 11
/// marks them UTF-8; bytes below `0x80` match ASCII either way.
const List<int> _cp437TailCodePoints = [
  0x00C7,
  0x00FC,
  0x00E9,
  0x00E2,
  0x00E4,
  0x00E0,
  0x00E5,
  0x00E7,
  0x00EA,
  0x00EB,
  0x00E8,
  0x00EF,
  0x00EE,
  0x00EC,
  0x00C4,
  0x00C5,
  0x00C9,
  0x00E6,
  0x00C6,
  0x00F4,
  0x00F6,
  0x00F2,
  0x00FB,
  0x00F9,
  0x00FF,
  0x00D6,
  0x00DC,
  0x00A2,
  0x00A3,
  0x00A5,
  0x20A7,
  0x0192,
  0x00E1,
  0x00ED,
  0x00F3,
  0x00FA,
  0x00F1,
  0x00D1,
  0x00AA,
  0x00BA,
  0x00BF,
  0x2310,
  0x00AC,
  0x00BD,
  0x00BC,
  0x00A1,
  0x00AB,
  0x00BB,
  0x2591,
  0x2592,
  0x2593,
  0x2502,
  0x2524,
  0x2561,
  0x2562,
  0x2556,
  0x2555,
  0x2563,
  0x2551,
  0x2557,
  0x255D,
  0x255C,
  0x255B,
  0x2510,
  0x2514,
  0x2534,
  0x252C,
  0x251C,
  0x2500,
  0x253C,
  0x255E,
  0x255F,
  0x255A,
  0x2554,
  0x2569,
  0x2566,
  0x2560,
  0x2550,
  0x256C,
  0x2567,
  0x2568,
  0x2564,
  0x2565,
  0x2559,
  0x2558,
  0x2552,
  0x2553,
  0x256B,
  0x256A,
  0x2518,
  0x250C,
  0x2588,
  0x2584,
  0x258C,
  0x2590,
  0x2580,
  0x03B1,
  0x00DF,
  0x0393,
  0x03C0,
  0x03A3,
  0x03C3,
  0x00B5,
  0x03C4,
  0x03A6,
  0x0398,
  0x03A9,
  0x03B4,
  0x221E,
  0x03C6,
  0x03B5,
  0x2229,
  0x2261,
  0x00B1,
  0x2265,
  0x2264,
  0x2320,
  0x2321,
  0x00F7,
  0x2248,
  0x00B0,
  0x2219,
  0x00B7,
  0x221A,
  0x207F,
  0x00B2,
  0x25A0,
  0x00A0,
];

/// Decodes CP437 [nameBytes] (general-purpose bit 11 clear) to a string.
String _decodeCp437Name(List<int> nameBytes) {
  final out = StringBuffer();
  for (final byte in nameBytes) {
    out.writeCharCode(byte < 0x80 ? byte : _cp437TailCodePoints[byte - 0x80]);
  }
  return out.toString();
}

/// Decodes a central-directory entry name held in [nameBytes] per the ZIP spec.
///
/// UTF-8 when general-purpose bit 11 of [flags] is set, CP437 when it is
/// clear. A malformed UTF-8 name fails naming the record's [recordOffset]
/// instead of leaking the decoder's bare error.
String decodeZipEntryName(List<int> nameBytes, int flags, int recordOffset) {
  if ((flags & 0x0800) == 0) {
    return _decodeCp437Name(nameBytes);
  }
  try {
    return utf8.decode(nameBytes);
  } on FormatException catch (e) {
    throw FormatException(
      'Invalid central directory entry at offset $recordOffset: '
      'entry name is not valid UTF-8 (${e.message}).',
    );
  }
}

/// Applies the ZIP64 End of Central Directory locator when present,
/// returning the authoritative entry count and central-directory offset.
({int entryCount, int cdOffset}) _applyZip64Locator(
  ByteData bd,
  Uint8List zipBytes,
  int eocdOffset,
  int entryCount,
  int cdOffset,
) {
  // Check for ZIP64 End of Central Directory Locator (0x07064b50) immediately
  // preceding the standard EOCD record.
  if (eocdOffset >= 20 &&
      bd.getUint32(eocdOffset - 20, Endian.little) == 0x07064b50) {
    final int zip64EocdOffset = getUint64LE(bd, eocdOffset - 20 + 8);
    if (zip64EocdOffset + 56 > zipBytes.length ||
        bd.getUint32(zip64EocdOffset, Endian.little) != 0x06064b50) {
      throw FormatException(
        'Invalid ZIP64 archive: ZIP64 EOCD signature not found at $zip64EocdOffset.',
      );
    }
    return (
      entryCount: getUint64LE(bd, zip64EocdOffset + 32),
      cdOffset: getUint64LE(bd, zip64EocdOffset + 48),
    );
  }
  return (entryCount: entryCount, cdOffset: cdOffset);
}

/// Applies the ZIP64 extended information extra field (`0x0001`) to 32-bit
/// size/offset markers, returning the resolved values and whether the field
/// was present.
({int uncompressedSize, int compressedSize, int localOffset, bool found})
_applyZip64ExtraField(
  ByteData bd,
  int extraStart,
  int extraEnd,
  int uncompressedSize,
  int compressedSize,
  int localOffset,
) {
  var extraPos = extraStart;
  while (extraPos + 4 <= extraEnd) {
    final int headerId = bd.getUint16(extraPos, Endian.little);
    final int dataSize = bd.getUint16(extraPos + 2, Endian.little);
    final int fieldDataStart = extraPos + 4;
    if (headerId == zip64HeaderId) {
      var fieldPos = fieldDataStart;
      if (uncompressedSize == zip64Limit32 &&
          fieldPos + 8 <= fieldDataStart + dataSize) {
        uncompressedSize = getUint64LE(bd, fieldPos);
        fieldPos += 8;
      }
      if (compressedSize == zip64Limit32 &&
          fieldPos + 8 <= fieldDataStart + dataSize) {
        compressedSize = getUint64LE(bd, fieldPos);
        fieldPos += 8;
      }
      if (localOffset == zip64Limit32 &&
          fieldPos + 8 <= fieldDataStart + dataSize) {
        localOffset = getUint64LE(bd, fieldPos);
        fieldPos += 8;
      }
      return (
        uncompressedSize: uncompressedSize,
        compressedSize: compressedSize,
        localOffset: localOffset,
        found: true,
      );
    }
    extraPos += 4 + dataSize;
  }
  return (
    uncompressedSize: uncompressedSize,
    compressedSize: compressedSize,
    localOffset: localOffset,
    found: false,
  );
}

/// How strictly a central-directory record is validated while parsing.
///
/// The inflating reader is lenient (archives with trailing data descriptors
/// and 64-bit sizes it never needs still read); the raw reader is strict
/// (it refuses anything below the ZIP32 limits it cannot represent).
class _CentralParseOptions {
  const new({
    required this.checkBounds,
    required this.flagsOverride,
    required this.strictZip64,
  });

  final bool checkBounds;
  final int? flagsOverride;
  final bool strictZip64;
}

/// Parses one central-directory record at [pos] with ZIP64 size resolution.
///
/// [options] selects the header checks, the flags value, and the ZIP64 policy
/// of the caller; everything else is shared.
_CentralRecord _parseCentralRecord(
  ByteData bd,
  Uint8List zipBytes,
  int pos,
  _CentralParseOptions options,
) {
  if ((options.checkBounds && pos + 46 > zipBytes.length) ||
      bd.getUint32(pos, Endian.little) != 0x02014b50) {
    throw FormatException('Invalid central directory header at $pos.');
  }
  final int rawFlags = bd.getUint16(pos + 8, Endian.little);
  final int flags = options.flagsOverride ?? rawFlags;
  final int method = bd.getUint16(pos + 10, Endian.little);
  final int crc = bd.getUint32(pos + 16, Endian.little);
  int compressedSize = bd.getUint32(pos + 20, Endian.little);
  int uncompressedSize = bd.getUint32(pos + 24, Endian.little);
  final int nameLen = bd.getUint16(pos + 28, Endian.little);
  final int extraLen = bd.getUint16(pos + 30, Endian.little);
  final int commentLen = bd.getUint16(pos + 32, Endian.little);
  final int externalAttrs = bd.getUint32(pos + 38, Endian.little);
  int localOffset = bd.getUint32(pos + 42, Endian.little);

  if (options.checkBounds && pos + 46 + nameLen > zipBytes.length) {
    throw FormatException('Invalid central directory header at $pos.');
  }
  // The name decodes by the flags actually on disk: the inflated reader's
  // flags override only silences bit 3 for payload handling, never the name.
  final String path = decodeZipEntryName(
    zipBytes.sublist(pos + 46, pos + 46 + nameLen),
    rawFlags,
    pos,
  );

  if (uncompressedSize == zip64Limit32 ||
      compressedSize == zip64Limit32 ||
      localOffset == zip64Limit32) {
    final int extraStart = pos + 46 + nameLen;
    final ({
      int compressedSize,
      bool found,
      int localOffset,
      int uncompressedSize,
    })
    resolved = _applyZip64ExtraField(
      bd,
      extraStart,
      extraStart + extraLen,
      uncompressedSize,
      compressedSize,
      localOffset,
    );
    uncompressedSize = resolved.uncompressedSize;
    compressedSize = resolved.compressedSize;
    localOffset = resolved.localOffset;
    if (options.strictZip64 &&
        !resolved.found &&
        (uncompressedSize == zip64Limit32 ||
            compressedSize == zip64Limit32 ||
            localOffset == zip64Limit32)) {
      throw FormatException(
        'ZIP64 entry "$path" has no ZIP64 extra field; 64-bit sizes are '
        'not supported here.',
      );
    }
  }

  return (
    path: path,
    method: method,
    flags: flags,
    crc: crc,
    compressedSize: compressedSize,
    uncompressedSize: uncompressedSize,
    externalAttrs: externalAttrs,
    localOffset: localOffset,
    nextPos: pos + 46 + nameLen + extraLen + commentLen,
  );
}

_CentralRecord _parseInflatedCentralRecord(
  ByteData bd,
  Uint8List zipBytes,
  int pos,
) => _parseCentralRecord(
  bd,
  zipBytes,
  pos,
  const _CentralParseOptions(
    checkBounds: false,
    flagsOverride: 0,
    strictZip64: false,
  ),
);

/// Inflates one entry's payload, verifying checksums for large streaming
/// entries without holding them inflated in memory.
({Uint8List data, int? uncompressedSizeOverride, int? crc32Override})
_inflateZipPayload(
  ByteData bd,
  Uint8List zipBytes,
  ZLibCodec rawInflate,
  _CentralRecord central,
) {
  if (bd.getUint32(central.localOffset, Endian.little) != 0x04034b50) {
    throw FormatException(
      'Invalid local file header at ${central.localOffset}.',
    );
  }
  final int localNameLen = bd.getUint16(
    central.localOffset + 26,
    Endian.little,
  );
  final int localExtraLen = bd.getUint16(
    central.localOffset + 28,
    Endian.little,
  );
  final int dataStart = central.localOffset + 30 + localNameLen + localExtraLen;
  final rawPayload = Uint8List.sublistView(
    zipBytes,
    dataStart,
    dataStart + central.compressedSize,
  );

  if (central.method == 0) {
    final data = Uint8List.fromList(rawPayload);
    return (
      data: data,
      uncompressedSizeOverride: central.uncompressedSize != data.length
          ? central.uncompressedSize
          : null,
      crc32Override: central.crc,
    );
  }
  if (central.method == 8) {
    if (central.uncompressedSize > streamingFileThreshold) {
      return _inflateStreamingZipPayload(central, rawPayload);
    }
    final data = Uint8List.fromList(rawInflate.decode(rawPayload));
    return (
      data: data,
      uncompressedSizeOverride: central.uncompressedSize != data.length
          ? central.uncompressedSize
          : null,
      crc32Override: central.crc,
    );
  }
  throw UnsupportedError(
    'Unsupported ZIP compression method: ${central.method}',
  );
}

({Uint8List data, int? uncompressedSizeOverride, int? crc32Override})
_inflateStreamingZipPayload(_CentralRecord central, Uint8List rawPayload) {
  final crcSink = CrcAndSizeSink();
  final ByteConversionSink inflateSink = ZLibDecoder(raw: true)
      .startChunkedConversion(crcSink);
  const int step = 1024 * 1024;
  for (var off = 0; off < rawPayload.length; off += step) {
    final int end = (off + step < rawPayload.length)
        ? off + step
        : rawPayload.length;
    inflateSink.add(Uint8List.sublistView(rawPayload, off, end));
  }
  inflateSink.close();
  if (crcSink.totalLength != central.uncompressedSize) {
    throw FormatException(
      'ZIP64 inflated length mismatch for "${central.path}": '
      'expected ${central.uncompressedSize}, got ${crcSink.totalLength}.',
    );
  }
  if (crcSink.crc32Value != central.crc) {
    throw FormatException(
      'ZIP64 CRC-32 mismatch for "${central.path}": '
      'expected 0x${central.crc.toRadixString(16)}, '
      'got 0x${crcSink.crc32Value.toRadixString(16)}.',
    );
  }
  return (
    data: Uint8List(0),
    uncompressedSizeOverride: crcSink.totalLength,
    crc32Override: crcSink.crc32Value,
  );
}

({bool isDir, bool isSymlink, bool isExec}) _zipModeFlags(
  int externalAttrs,
  String path,
) {
  final int unixMode = (externalAttrs >>> 16) & 0xFFFF;
  final int fileType = unixMode & 0xF000;
  final bool isDir = path.endsWith('/') || fileType == 0x4000;
  final isSymlink = fileType == 0xA000;
  return (
    isDir: isDir,
    isSymlink: isSymlink,
    isExec: !isDir && !isSymlink && ((unixMode & 0x49) != 0),
  );
}

/// Decodes a ZIP or ZIP64 archive produced by [encodeDeterministicZip] (or
/// standard ZIP writers) into a list of [ZipEntry] items for inspection and
/// testing.
List<ZipEntry> readZipEntries(Uint8List zipBytes) {
  final bd = ByteData.sublistView(zipBytes);
  final int eocdOffset = findEocdOffset(zipBytes);
  final ({int cdOffset, int entryCount}) located = _applyZip64Locator(
    bd,
    zipBytes,
    eocdOffset,
    bd.getUint16(eocdOffset + 10, Endian.little),
    bd.getUint32(eocdOffset + 16, Endian.little),
  );
  final rawInflate = ZLibCodec(raw: true);

  final entries = <ZipEntry>[];
  int pos = located.cdOffset;
  for (var i = 0; i < located.entryCount; i++) {
    final _CentralRecord central = _parseInflatedCentralRecord(
      bd,
      zipBytes,
      pos,
    );
    pos = central.nextPos;
    final ({int? crc32Override, Uint8List data, int? uncompressedSizeOverride})
    payload = _inflateZipPayload(bd, zipBytes, rawInflate, central);
    final ({bool isDir, bool isExec, bool isSymlink}) flags = _zipModeFlags(
      central.externalAttrs,
      central.path,
    );
    entries.add(
      ZipEntry(
        path: central.path,
        data: payload.data,
        uncompressedSizeOverride: payload.uncompressedSizeOverride,
        crc32Override: payload.crc32Override,
        isDirectory: flags.isDir,
        isExecutable: flags.isExec,
        isSymlink: flags.isSymlink,
      ),
    );
  }
  return entries;
}

/// A ZIP entry's on-disk payload, without inflating.
///
/// Unlike [readZipEntries], this never inflates deflated data and never drops
/// large entries: [rawData] is a view onto [zipBytes] holding the entry's
/// bytes exactly as stored (deflated bytes when [method] is 8), so entries of
/// any size below the ZIP32 limits can be copied through (for example a
/// stored native library spliced from one archive into another).
class ZipRawEntry {
  /// Archive path, UTF-8 decoded from the central directory.
  final String path;

  /// Compression method: 0 (stored) or 8 (deflated).
  final int method;

  /// CRC-32 of the uncompressed data, from the central directory.
  final int crc;

  /// Uncompressed byte length, with the ZIP64 extra field applied.
  final int uncompressedSize;

  /// The entry's bytes as stored: uncompressed content when [method] is 0,
  /// deflated content when [method] is 8. A view onto the input buffer.
  final Uint8List rawData;
  final bool isDirectory;

  const new({
    required this.path,
    required this.method,
    required this.crc,
    required this.uncompressedSize,
    required this.rawData,
    required this.isDirectory,
  });
}

/// Reads the central directory of [zipBytes], returning each entry's raw
/// payload without inflating.
///
/// Refuses archives without a readable extra field where a 64-bit size marker
/// appears (writers that need 64-bit sizes must emit the ZIP64 extra fields
/// [encodeDeterministicZip] emits), encrypted entries, and unsupported
/// compression methods. Entries with data descriptors (bit 3) read fine: the
/// central record carries the authoritative sizes. Anything else below the
/// ZIP32 limits reads, at any size.
_CentralRecord _parseRawCentralRecord(
  ByteData bd,
  Uint8List zipBytes,
  int pos,
) => _parseCentralRecord(
  bd,
  zipBytes,
  pos,
  const _CentralParseOptions(
    checkBounds: true,
    flagsOverride: null,
    strictZip64: true,
  ),
);

ZipRawEntry _materializeRawEntry(
  ByteData bd,
  Uint8List zipBytes,
  _CentralRecord central,
) {
  if (central.method != 0 && central.method != 8) {
    throw UnsupportedError(
      'Unsupported ZIP compression method ${central.method} for "${central.path}".',
    );
  }
  if ((central.flags & 0x01) != 0) {
    throw FormatException(
      'Encrypted ZIP entries are not supported: ${central.path}.',
    );
  }
  if (central.localOffset + 30 > zipBytes.length ||
      bd.getUint32(central.localOffset, Endian.little) != 0x04034b50) {
    throw FormatException(
      'Invalid local file header at ${central.localOffset}.',
    );
  }
  final int localNameLen = bd.getUint16(
    central.localOffset + 26,
    Endian.little,
  );
  final int localExtraLen = bd.getUint16(
    central.localOffset + 28,
    Endian.little,
  );
  final int dataStart = central.localOffset + 30 + localNameLen + localExtraLen;
  if (dataStart + central.compressedSize > zipBytes.length) {
    throw FormatException(
      'ZIP entry "${central.path}" overruns the archive '
      '(offset $dataStart, size ${central.compressedSize}).',
    );
  }
  final rawPayload = Uint8List.sublistView(
    zipBytes,
    dataStart,
    dataStart + central.compressedSize,
  );

  final int unixMode = (central.externalAttrs >>> 16) & 0xFFFF;
  final int fileType = unixMode & 0xF000;
  final bool isDir = central.path.endsWith('/') || fileType == 0x4000;
  return ZipRawEntry(
    path: central.path,
    method: central.method,
    crc: central.crc,
    uncompressedSize: central.uncompressedSize,
    rawData: rawPayload,
    isDirectory: isDir,
  );
}

/// Reads the central directory of [zipBytes], returning each entry's raw
/// payload without inflating.
///
/// Refuses archives without a readable extra field where a 64-bit size marker
/// appears (writers that need 64-bit sizes must emit the ZIP64 extra fields
/// [encodeDeterministicZip] emits), encrypted entries, and unsupported
/// compression methods. Entries with data descriptors (bit 3) read fine: the
/// central record carries the authoritative sizes. Anything else below the
/// ZIP32 limits reads, at any size.
List<ZipRawEntry> readZipRawEntries(Uint8List zipBytes) {
  final bd = ByteData.sublistView(zipBytes);
  final int eocdOffset = findEocdOffset(zipBytes);
  final ({int cdOffset, int entryCount}) located = _applyZip64Locator(
    bd,
    zipBytes,
    eocdOffset,
    bd.getUint16(eocdOffset + 10, Endian.little),
    bd.getUint32(eocdOffset + 16, Endian.little),
  );

  final entries = <ZipRawEntry>[];
  int pos = located.cdOffset;
  for (var i = 0; i < located.entryCount; i++) {
    final _CentralRecord central = _parseRawCentralRecord(bd, zipBytes, pos);
    pos = central.nextPos;
    entries.add(_materializeRawEntry(bd, zipBytes, central));
  }
  return entries;
}
