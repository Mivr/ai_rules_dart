/// Pure-Dart deterministic ZIP archive writer.
///
/// Writes deterministic ZIP (or ZIP64) archives with fixed DOS timestamps
/// and Unix permission bits. Also holds the little-endian record helpers
/// and ZIP64 limits shared with the readers in `zip_reader.dart`.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'crc32.dart' as crc32lib;

// ---------------------------------------------------------------------------
// Pure-Dart deterministic ZIP archive writer
// ---------------------------------------------------------------------------

/// Computes the IEEE 802.3 CRC-32 checksum of [bytes].
int crc32(List<int> bytes) => crc32lib.crc32(bytes);

class _BytesSink implements Sink<List<int>> {
  final BytesBuilder builder = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    builder.add(data);
  }

  @override
  void close() {}
}

/// Counts bytes and accumulates their CRC-32 while a ZIP payload streams through.
class CrcAndSizeSink implements Sink<List<int>> {
  int _crc = 0xFFFFFFFF;

  /// Total payload bytes streamed through this sink so far.
  int totalLength = 0;

  /// The CRC-32 of the bytes streamed so far, post-conditioned.
  int get crc32Value => (_crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;

  @override
  void add(List<int> data) {
    _crc = crc32lib.crc32Update(_crc, data);
    totalLength += data.length;
  }

  @override
  void close() {}
}

/// Writes [value] as an unsigned 64-bit little-endian integer at [offset] of [bd].
void setUint64LE(ByteData bd, int offset, int value) {
  bd.setUint32(offset, value & 0xFFFFFFFF, Endian.little);
  bd.setUint32(offset + 4, (value >>> 32) & 0xFFFFFFFF, Endian.little);
}

/// Reads an unsigned 64-bit little-endian integer at [offset] of [bd].
int getUint64LE(ByteData bd, int offset) {
  final int lo = bd.getUint32(offset, Endian.little);
  final int hi = bd.getUint32(offset + 4, Endian.little);
  return ((hi & 0x7FFFFFFF) * 0x100000000) + lo;
}

/// Largest count that fits in a 16-bit ZIP record field; larger counts force ZIP64.
const int zip64Limit16 = 0xFFFF;

/// Largest size or offset that fits in a 32-bit ZIP record field; larger values force ZIP64.
const int zip64Limit32 = 0xFFFFFFFF;

/// ZIP extra-field header id for ZIP64 extended information.
const int zip64HeaderId = 0x0001;

/// Entries larger than this stream incrementally instead of loading fully into memory (64 MiB).
const int streamingFileThreshold = 64 * 1024 * 1024; // 64 MiB

/// An entry in a deterministic ZIP archive.
class ZipEntry {
  final String path;
  final Uint8List data;
  final Uint8List? compressedData;
  final int? uncompressedSizeOverride;
  final int? crc32Override;
  final bool isDirectory;
  final bool isExecutable;
  final bool isSymlink;

  /// When true, [encodeDeterministicZip] writes the entry stored (method 0)
  /// even when deflating would shrink it. Native Android libraries (`.so`)
  /// need this: the APK stores them uncompressed so `zipalign` can
  /// page-align them, and the APK overlay copies them without inflating.
  final bool storeOnly;

  const new({
    required this.path,
    required this.data,
    this.compressedData,
    this.uncompressedSizeOverride,
    this.crc32Override,
    this.isDirectory = false,
    this.isExecutable = false,
    this.isSymlink = false,
    this.storeOnly = false,
  });

  /// The uncompressed byte length of this entry (including 64-bit ZIP64 sizes).
  int get uncompressedSize => uncompressedSizeOverride ?? data.length;
}

/// Builds a deterministic ZIP archive from [rootDir].
///
/// [executablePaths] contains relative archive paths (using `/`) that receive
/// `0755` (`-rwxr-xr-x`) Unix permissions. All other regular files receive
/// `0644` (`-rw-r--r--`), directories receive `0755` (`drwxr-xr-x`), and
/// symbolic links receive `0120777` (`lrwxrwxrwx`). Host filesystem mode bits
/// are never inherited.
Uint8List createDeterministicZipFromDirectory(
  Directory rootDir, {
  Set<String> executablePaths = const {},
}) {
  final entries = <ZipEntry>[];
  _collectZipEntries(entries, rootDir, '', executablePaths);
  return encodeDeterministicZip(entries);
}

/// Reads [entity] as a streaming deflated ZIP entry, computing its CRC-32
/// incrementally so files larger than [streamingFileThreshold] never sit
/// fully inflated in memory.
ZipEntry _streamingZipEntry(File entity, String relPath, bool isExec) {
  final int fileSize = entity.lengthSync();
  final RandomAccessFile raf = entity.openSync(mode: FileMode.read);
  try {
    final bytesSink = _BytesSink();
    final ByteConversionSink deflateSink = ZLibEncoder(raw: true)
        .startChunkedConversion(
          bytesSink,
        );
    final chunkBuf = Uint8List(1024 * 1024);
    var runningCrc = 0xFFFFFFFF;
    while (true) {
      final int n = raf.readIntoSync(chunkBuf);
      if (n <= 0) break;
      runningCrc = crc32lib.crc32Update(runningCrc, chunkBuf, n);
      deflateSink.add(Uint8List.sublistView(chunkBuf, 0, n));
    }
    deflateSink.close();
    return ZipEntry(
      path: relPath,
      data: Uint8List(0),
      compressedData: bytesSink.builder.takeBytes(),
      uncompressedSizeOverride: fileSize,
      crc32Override: (runningCrc ^ 0xFFFFFFFF) & 0xFFFFFFFF,
      isExecutable: isExec,
    );
  } finally {
    raf.closeSync();
  }
}

void _collectZipEntries(
  List<ZipEntry> entries,
  Directory dir,
  String relPrefix,
  Set<String> executablePaths,
) {
  final List<FileSystemEntity> children = dir.listSync(followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in children) {
    final String name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final relPath = relPrefix.isEmpty ? name : '$relPrefix/$name';
    if (entity is Link) {
      final String target = entity.targetSync();
      entries.add(
        ZipEntry(
          path: relPath,
          data: Uint8List.fromList(utf8.encode(target)),
          isSymlink: true,
        ),
      );
    } else if (entity is Directory) {
      entries.add(
        ZipEntry(path: '$relPath/', data: Uint8List(0), isDirectory: true),
      );
      _collectZipEntries(entries, entity, relPath, executablePaths);
    } else if (entity is File) {
      // File modes are determined strictly from the entry role via
      // executablePaths, never from host filesystem stat.mode bits.
      final bool isExec = executablePaths.contains(relPath);
      if (entity.lengthSync() > streamingFileThreshold) {
        entries.add(_streamingZipEntry(entity, relPath, isExec));
      } else {
        entries.add(
          ZipEntry(
            path: relPath,
            data: entity.readAsBytesSync(),
            isExecutable: isExec,
          ),
        );
      }
    }
  }
}

/// Encodes [entries] into a deterministic ZIP (or ZIP64) byte buffer.
///
/// Automatically writes ZIP64 extended information extra fields (`0x0001`),
/// ZIP64 End of Central Directory record (`0x06064b50`), and ZIP64 End of
/// Central Directory Locator (`0x07064b50`) when entry count >= 65,535 or any
/// entry size or offset >= 4 GiB (`0xFFFFFFFF`).
/// A ZIP entry's chosen on-disk representation: compression method (0 for
/// stored, 8 for deflate), payload bytes, uncompressed length, and CRC-32.
typedef _ZipPayload = ({
  int method,
  Uint8List payload,
  int uncompressedLen,
  int crc,
});

/// Stateful writer for the local-file and central-directory sections of a
/// deterministic ZIP archive. Tracks the running data offset and whether any
/// entry needed ZIP64 extended information.
class _DeterministicZipEncoder {
  final localParts = BytesBuilder(copy: false);
  final centralParts = BytesBuilder(copy: false);
  final rawDeflate = ZLibCodec(raw: true);
  var offset = 0;
  var anyEntryZip64 = false;

  // Fixed DOS timestamp: 1980-01-01 00:00:00 (time = 0, date = 0x0021).
  static const dosTime = 0x0000;
  static const dosDate = 0x0021;
  // Version made by: Unix (3) << 8 | ZIP 2.0 (20) or ZIP 4.5 (45) for ZIP64.
  static const versionMadeByStandard = (3 << 8) | 20;
  static const versionMadeByZip64 = (3 << 8) | 45;
  static const versionNeededStandard = 20;
  static const versionNeededZip64 = 45;

  void writeEntry(ZipEntry entry) {
    final Uint8List nameBytes = utf8.encode(entry.path);
    final _ZipPayload record = _chooseZipPayload(entry);
    final int externalAttrs = _zipExternalAttrs(entry);
    final Uint8List localExtra = _localZip64Extra(
      record.uncompressedLen,
      record.payload.length,
    );
    _writeLocalRecord(nameBytes, record, localExtra);
    _writeCentralRecord(nameBytes, record, localExtra, externalAttrs);
    offset += 30 + nameBytes.length + localExtra.length + record.payload.length;
  }

  _ZipPayload _chooseZipPayload(ZipEntry entry) {
    final Uint8List uncompressed = entry.data;
    final int uncompressedLen = entry.uncompressedSize;
    final int crc = entry.isDirectory
        ? 0
        : (entry.crc32Override ?? crc32(uncompressed));
    if (entry.storeOnly && entry.compressedData != null) {
      throw ArgumentError(
        'encodeDeterministicZip: entry ${entry.path} is storeOnly but '
        'carries compressedData.',
      );
    }
    var compressionMethod = 0; // Stored
    var payload = uncompressed;
    if (entry.compressedData != null) {
      compressionMethod = 8; // Deflate
      payload = entry.compressedData!;
    } else if (_shouldDeflate(entry, uncompressed)) {
      final deflated = Uint8List.fromList(rawDeflate.encode(uncompressed));
      if (deflated.length < uncompressed.length) {
        compressionMethod = 8; // Deflate
        payload = deflated;
      }
    }
    return (
      method: compressionMethod,
      payload: payload,
      uncompressedLen: uncompressedLen,
      crc: crc,
    );
  }

  bool _shouldDeflate(ZipEntry entry, Uint8List uncompressed) {
    return !entry.storeOnly &&
        !entry.isDirectory &&
        !entry.isSymlink &&
        uncompressed.isNotEmpty &&
        entry.uncompressedSizeOverride == null;
  }

  int _zipExternalAttrs(ZipEntry entry) {
    if (entry.isDirectory) {
      return (0x41ED << 16) | 0x10; // drwxr-xr-x + DOS directory bit
    } else if (entry.isSymlink) {
      return (0xA1FF << 16); // lrwxrwxrwx
    } else if (entry.isExecutable) {
      return (0x81ED << 16); // -rwxr-xr-x
    } else {
      return (0x81A4 << 16); // -rw-r--r--
    }
  }

  Uint8List _localZip64Extra(int uncompressedLen, int compressedLen) {
    if (uncompressedLen < zip64Limit32 && compressedLen < zip64Limit32) {
      return Uint8List(0);
    }
    anyEntryZip64 = true;
    final localExtra = Uint8List(20);
    final extraBd = ByteData.sublistView(localExtra);
    extraBd.setUint16(0, zip64HeaderId, Endian.little);
    extraBd.setUint16(2, 16, Endian.little);
    setUint64LE(extraBd, 4, uncompressedLen);
    setUint64LE(extraBd, 12, compressedLen);
    return localExtra;
  }

  void _writeLocalRecord(
    List<int> nameBytes,
    _ZipPayload record,
    Uint8List localExtra,
  ) {
    final bool localNeedZip64 = localExtra.isNotEmpty;
    final int localVersionNeeded = localNeedZip64
        ? versionNeededZip64
        : versionNeededStandard;
    // Local file header (30 bytes + filename + extra + payload).
    final localHeader = ByteData(30 + nameBytes.length + localExtra.length);
    localHeader.setUint32(0, 0x04034b50, Endian.little);
    localHeader.setUint16(4, localVersionNeeded, Endian.little);
    localHeader.setUint16(6, 0x0800, Endian.little); // UTF-8 flag
    localHeader.setUint16(8, record.method, Endian.little);
    localHeader.setUint16(10, dosTime, Endian.little);
    localHeader.setUint16(12, dosDate, Endian.little);
    localHeader.setUint32(14, record.crc, Endian.little);
    localHeader.setUint32(
      18,
      localNeedZip64 ? zip64Limit32 : record.payload.length,
      Endian.little,
    );
    localHeader.setUint32(
      22,
      localNeedZip64 ? zip64Limit32 : record.uncompressedLen,
      Endian.little,
    );
    localHeader.setUint16(26, nameBytes.length, Endian.little);
    localHeader.setUint16(28, localExtra.length, Endian.little);
    localHeader.buffer.asUint8List().setRange(
      30,
      30 + nameBytes.length,
      nameBytes,
    );
    if (localExtra.isNotEmpty) {
      localHeader.buffer.asUint8List().setRange(
        30 + nameBytes.length,
        30 + nameBytes.length + localExtra.length,
        localExtra,
      );
    }
    localParts.add(localHeader.buffer.asUint8List());
    localParts.add(record.payload);
  }

  Uint8List _centralZip64Extra(
    int uncompressedLen,
    int compressedLen,
    int entryOffset,
  ) {
    final bool needUncompressed64 = uncompressedLen >= zip64Limit32;
    final bool needCompressed64 = compressedLen >= zip64Limit32;
    final bool needOffset64 = entryOffset >= zip64Limit32;
    if (!needUncompressed64 && !needCompressed64 && !needOffset64) {
      return Uint8List(0);
    }
    anyEntryZip64 = true;
    final int fieldCount =
        (needUncompressed64 ? 1 : 0) +
        (needCompressed64 ? 1 : 0) +
        (needOffset64 ? 1 : 0);
    final cdExtra = Uint8List(4 + fieldCount * 8);
    final extraBd = ByteData.sublistView(cdExtra);
    extraBd.setUint16(0, zip64HeaderId, Endian.little);
    extraBd.setUint16(2, fieldCount * 8, Endian.little);
    var fieldPos = 4;
    if (needUncompressed64) {
      setUint64LE(extraBd, fieldPos, uncompressedLen);
      fieldPos += 8;
    }
    if (needCompressed64) {
      setUint64LE(extraBd, fieldPos, compressedLen);
      fieldPos += 8;
    }
    if (needOffset64) {
      setUint64LE(extraBd, fieldPos, entryOffset);
      fieldPos += 8;
    }
    return cdExtra;
  }

  void _writeCentralRecord(
    List<int> nameBytes,
    _ZipPayload record,
    Uint8List localExtra,
    int externalAttrs,
  ) {
    final Uint8List cdExtra = _centralZip64Extra(
      record.uncompressedLen,
      record.payload.length,
      offset,
    );
    final bool cdNeedZip64 = cdExtra.isNotEmpty || localExtra.isNotEmpty;
    final int cdVersionMadeBy = cdNeedZip64
        ? versionMadeByZip64
        : versionMadeByStandard;
    final int cdVersionNeeded = cdNeedZip64
        ? versionNeededZip64
        : versionNeededStandard;
    // Central directory header (46 bytes + filename + extra).
    final centralHeader = ByteData(46 + nameBytes.length + cdExtra.length);
    centralHeader.setUint32(0, 0x02014b50, Endian.little);
    centralHeader.setUint16(4, cdVersionMadeBy, Endian.little);
    centralHeader.setUint16(6, cdVersionNeeded, Endian.little);
    centralHeader.setUint16(8, 0x0800, Endian.little); // UTF-8 flag
    centralHeader.setUint16(10, record.method, Endian.little);
    centralHeader.setUint16(12, dosTime, Endian.little);
    centralHeader.setUint16(14, dosDate, Endian.little);
    centralHeader.setUint32(16, record.crc, Endian.little);
    centralHeader.setUint32(
      20,
      record.payload.length >= zip64Limit32
          ? zip64Limit32
          : record.payload.length,
      Endian.little,
    );
    centralHeader.setUint32(
      24,
      record.uncompressedLen >= zip64Limit32
          ? zip64Limit32
          : record.uncompressedLen,
      Endian.little,
    );
    centralHeader.setUint16(28, nameBytes.length, Endian.little);
    centralHeader.setUint16(30, cdExtra.length, Endian.little);
    centralHeader.setUint16(32, 0, Endian.little); // comment len
    centralHeader.setUint16(34, 0, Endian.little); // disk number
    centralHeader.setUint16(36, 0, Endian.little); // internal attrs
    centralHeader.setUint32(38, externalAttrs, Endian.little);
    centralHeader.setUint32(
      42,
      offset >= zip64Limit32 ? zip64Limit32 : offset,
      Endian.little,
    );
    centralHeader.buffer.asUint8List().setRange(
      46,
      46 + nameBytes.length,
      nameBytes,
    );
    if (cdExtra.isNotEmpty) {
      centralHeader.buffer.asUint8List().setRange(
        46 + nameBytes.length,
        46 + nameBytes.length + cdExtra.length,
        cdExtra,
      );
    }
    centralParts.add(centralHeader.buffer.asUint8List());
  }

  Uint8List finish(int entryCount) {
    final Uint8List centralBytes = centralParts.takeBytes();
    final int cdSize = centralBytes.length;
    final int cdOffset = offset;
    localParts.add(centralBytes);
    final bool needZip64Eocd =
        anyEntryZip64 ||
        entryCount >= zip64Limit16 ||
        cdSize >= zip64Limit32 ||
        cdOffset >= zip64Limit32;
    if (needZip64Eocd) {
      _writeZip64Eocd(cdOffset, cdSize, entryCount);
    }
    _writeEocd(entryCount, cdSize, cdOffset);
    return localParts.takeBytes();
  }

  void _writeZip64Eocd(int cdOffset, int cdSize, int entryCount) {
    final int zip64EocdOffset = cdOffset + cdSize;
    // ZIP64 End of Central Directory Record (56 bytes).
    final zip64Eocd = ByteData(56);
    zip64Eocd.setUint32(0, 0x06064b50, Endian.little);
    setUint64LE(zip64Eocd, 4, 44); // size of remaining record (56 - 12)
    zip64Eocd.setUint16(12, versionMadeByZip64, Endian.little);
    zip64Eocd.setUint16(14, versionNeededZip64, Endian.little);
    zip64Eocd.setUint32(16, 0, Endian.little); // number of this disk
    zip64Eocd.setUint32(20, 0, Endian.little); // disk with start of CD
    setUint64LE(zip64Eocd, 24, entryCount);
    setUint64LE(zip64Eocd, 32, entryCount);
    setUint64LE(zip64Eocd, 40, cdSize);
    setUint64LE(zip64Eocd, 48, cdOffset);
    localParts.add(zip64Eocd.buffer.asUint8List());

    // ZIP64 End of Central Directory Locator (20 bytes).
    final zip64Locator = ByteData(20);
    zip64Locator.setUint32(0, 0x07064b50, Endian.little);
    zip64Locator.setUint32(4, 0, Endian.little); // disk with ZIP64 EOCD
    setUint64LE(zip64Locator, 8, zip64EocdOffset);
    zip64Locator.setUint32(16, 1, Endian.little); // total number of disks
    localParts.add(zip64Locator.buffer.asUint8List());
  }

  void _writeEocd(int entryCount, int cdSize, int cdOffset) {
    final eocd = ByteData(22);
    eocd.setUint32(0, 0x06054b50, Endian.little);
    eocd.setUint16(4, 0, Endian.little);
    eocd.setUint16(6, 0, Endian.little);
    eocd.setUint16(
      8,
      entryCount >= zip64Limit16 ? zip64Limit16 : entryCount,
      Endian.little,
    );
    eocd.setUint16(
      10,
      entryCount >= zip64Limit16 ? zip64Limit16 : entryCount,
      Endian.little,
    );
    eocd.setUint32(
      12,
      cdSize >= zip64Limit32 ? zip64Limit32 : cdSize,
      Endian.little,
    );
    eocd.setUint32(
      16,
      cdOffset >= zip64Limit32 ? zip64Limit32 : cdOffset,
      Endian.little,
    );
    eocd.setUint16(20, 0, Endian.little);
    localParts.add(eocd.buffer.asUint8List());
  }
}

/// Encodes [entries] into a deterministic ZIP (or ZIP64) byte buffer.
///
/// Automatically writes ZIP64 extended information extra fields (`0x0001`),
/// ZIP64 End of Central Directory record (`0x06064b50`), and ZIP64 End of
/// Central Directory Locator (`0x07064b50`) when entry count >= 65,535 or any
/// entry size or offset >= 4 GiB (`0xFFFFFFFF`).
Uint8List encodeDeterministicZip(List<ZipEntry> entries) {
  final sorted = [...entries]..sort((a, b) => a.path.compareTo(b.path));
  final encoder = _DeterministicZipEncoder();
  for (final entry in sorted) {
    encoder.writeEntry(entry);
  }
  return encoder.finish(sorted.length);
}
