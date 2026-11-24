/// Deterministic framework ZIP archives and framework verification.
///
/// Creates and extracts versioned `.framework` ZIP bundles and verifies
/// on-disk frameworks ([verifyMacosFramework]) and their archives.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'crc32.dart' as crc32lib;

import 'macho_constants.dart';
import 'macho_copy.dart' show createSymlinkReplacingSync;
import 'macho_fat.dart' show extractFatSlices, isFatMachO, isMachO64;
import 'macho_parse.dart' show parseLoadCommands;

/// An entry in a deterministic framework ZIP archive.
class FrameworkZipEntry {
  final String path;
  final Uint8List data;
  final bool isExecutable;
  final bool isSymlink;

  const new({
    required this.path,
    required this.data,
    this.isExecutable = false,
    this.isSymlink = false,
  });
}

/// Builds a deterministic ZIP archive for [frameworkDir] (e.g. `App.framework`)
/// suitable for `rules_apple`'s `AppleBundleInfo.archive` (`bundle_merge_zips`).
///
/// Only file and symlink entries are emitted (no directory entries), matching
/// `rules_apple`'s `imported_dynamic_framework_processor.py` and `bundletool.py`.
/// Symbolic links are stored with Unix mode `0120777` (`S_IFLNK`) and
/// uncompressed target bytes; [executableRelPaths] receive `0100755`.
Uint8List createFrameworkZipBytes(
  Directory frameworkDir, {
  required String archiveRootName,
  Set<String> executableRelPaths = const {},
}) {
  final List<FrameworkZipEntry> entries = _collectFrameworkEntries(
    frameworkDir,
    archiveRootName,
    executableRelPaths,
  );
  entries.sort((a, b) => a.path.compareTo(b.path));

  final localParts = BytesBuilder(copy: false);
  final centralParts = BytesBuilder(copy: false);
  final rawDeflate = ZLibCodec(raw: true);

  const dosTime = 0x0000;
  const dosDate = 0x0021;
  const int versionMadeBy = (3 << 8) | 20;
  const versionNeeded = 20;

  var offset = 0;
  for (final entry in entries) {
    final Uint8List nameBytes = utf8.encode(entry.path);
    final int crc = crc32lib.crc32(entry.data);
    final (:Uint8List payload, :int method) = _zipEntryPayload(
      entry,
      rawDeflate,
    );
    final int externalAttrs = _zipExternalAttrs(entry);
    final ({
      int crc,
      int dosDate,
      int dosTime,
      int externalAttrs,
      int method,
      Uint8List nameBytes,
      int offset,
      Uint8List payload,
      int uncompressedLength,
      int versionMadeBy,
      int versionNeeded,
    })
    header = (
      nameBytes: nameBytes,
      payload: payload,
      method: method,
      crc: crc,
      uncompressedLength: entry.data.length,
      dosTime: dosTime,
      dosDate: dosDate,
      versionNeeded: versionNeeded,
      externalAttrs: externalAttrs,
      offset: offset,
      versionMadeBy: versionMadeBy,
    );
    _writeZipLocalEntry(localParts, header);
    _writeZipCentralEntry(centralParts, header);
    offset += 30 + nameBytes.length + payload.length;
  }

  return _finishFrameworkZip(localParts, centralParts, entries.length, offset);
}

/// Collects the framework's file and symlink entries in sorted path order.
List<FrameworkZipEntry> _collectFrameworkEntries(
  Directory frameworkDir,
  String archiveRootName,
  Set<String> executableRelPaths,
) {
  final entries = <FrameworkZipEntry>[];
  _walkFrameworkEntries(
    frameworkDir,
    archiveRootName,
    entries,
    executableRelPaths,
  );
  return entries;
}

/// Walks [dir] depth-first, appending file and symlink entries to [into].
void _walkFrameworkEntries(
  Directory dir,
  String relPrefix,
  List<FrameworkZipEntry> into,
  Set<String> executableRelPaths,
) {
  final List<FileSystemEntity> children = dir.listSync(followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in children) {
    final String name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final relPath = '$relPrefix/$name';
    if (entity is Link) {
      final String target = entity.targetSync();
      into.add(
        FrameworkZipEntry(
          path: relPath,
          data: Uint8List.fromList(utf8.encode(target)),
          isSymlink: true,
        ),
      );
    } else if (entity is Directory) {
      _walkFrameworkEntries(entity, relPath, into, executableRelPaths);
    } else if (entity is File) {
      final FileStat stat = entity.statSync();
      final bool isExec =
          executableRelPaths.contains(relPath) || ((stat.mode & 0x49) != 0);
      into.add(
        FrameworkZipEntry(
          path: relPath,
          data: entity.readAsBytesSync(),
          isExecutable: isExec,
        ),
      );
    }
  }
}

/// The stored payload for [entry]: deflated when that is smaller.
({Uint8List payload, int method}) _zipEntryPayload(
  FrameworkZipEntry entry,
  ZLibCodec rawDeflate,
) {
  final Uint8List uncompressed = entry.data;
  if (entry.isSymlink || uncompressed.isEmpty) {
    return (payload: uncompressed, method: 0);
  }
  final deflated = Uint8List.fromList(rawDeflate.encode(uncompressed));
  if (deflated.length < uncompressed.length) {
    return (payload: deflated, method: 8);
  }
  return (payload: uncompressed, method: 0);
}

/// The ZIP external-attributes word for [entry]'s file type and mode.
int _zipExternalAttrs(FrameworkZipEntry entry) {
  if (entry.isSymlink) {
    return 0xA1FF << 16; // lrwxrwxrwx (0120777)
  }
  if (entry.isExecutable) {
    return 0x81ED << 16; // -rwxr-xr-x (0100755)
  }
  return 0x81A4 << 16; // -rw-r--r-- (0100644)
}

/// The header fields shared by one ZIP local file header and its central
/// directory entry. Grouped into a record so the ZIP writers stay small.
typedef _ZipEntryHeader = ({
  List<int> nameBytes,
  Uint8List payload,
  int method,
  int crc,
  int uncompressedLength,
  int dosTime,
  int dosDate,
  int versionNeeded,
  int externalAttrs,
  int offset,
  int versionMadeBy,
});

/// Appends one local file header and payload to [into].
void _writeZipLocalEntry(BytesBuilder into, _ZipEntryHeader header) {
  final localHeader = ByteData(30 + header.nameBytes.length);
  localHeader.setUint32(0, 0x04034b50, Endian.little);
  localHeader.setUint16(4, header.versionNeeded, Endian.little);
  localHeader.setUint16(6, 0x0800, Endian.little);
  localHeader.setUint16(8, header.method, Endian.little);
  localHeader.setUint16(10, header.dosTime, Endian.little);
  localHeader.setUint16(12, header.dosDate, Endian.little);
  localHeader.setUint32(14, header.crc, Endian.little);
  localHeader.setUint32(18, header.payload.length, Endian.little);
  localHeader.setUint32(22, header.uncompressedLength, Endian.little);
  localHeader.setUint16(26, header.nameBytes.length, Endian.little);
  localHeader.setUint16(28, 0, Endian.little);
  localHeader.buffer.asUint8List().setRange(
    30,
    30 + header.nameBytes.length,
    header.nameBytes,
  );

  into.add(localHeader.buffer.asUint8List());
  into.add(header.payload);
}

/// Appends one central directory header to [into].
void _writeZipCentralEntry(BytesBuilder into, _ZipEntryHeader header) {
  final centralHeader = ByteData(46 + header.nameBytes.length);
  centralHeader.setUint32(0, 0x02014b50, Endian.little);
  centralHeader.setUint16(4, header.versionMadeBy, Endian.little);
  centralHeader.setUint16(6, header.versionNeeded, Endian.little);
  centralHeader.setUint16(8, 0x0800, Endian.little);
  centralHeader.setUint16(10, header.method, Endian.little);
  centralHeader.setUint16(12, header.dosTime, Endian.little);
  centralHeader.setUint16(14, header.dosDate, Endian.little);
  centralHeader.setUint32(16, header.crc, Endian.little);
  centralHeader.setUint32(20, header.payload.length, Endian.little);
  centralHeader.setUint32(24, header.uncompressedLength, Endian.little);
  centralHeader.setUint16(28, header.nameBytes.length, Endian.little);
  centralHeader.setUint16(30, 0, Endian.little);
  centralHeader.setUint16(32, 0, Endian.little);
  centralHeader.setUint16(34, 0, Endian.little);
  centralHeader.setUint16(36, 0, Endian.little);
  centralHeader.setUint32(38, header.externalAttrs, Endian.little);
  centralHeader.setUint32(42, header.offset, Endian.little);
  centralHeader.buffer.asUint8List().setRange(
    46,
    46 + header.nameBytes.length,
    header.nameBytes,
  );

  into.add(centralHeader.buffer.asUint8List());
}

/// Appends the central directory and end-of-central-directory record.
Uint8List _finishFrameworkZip(
  BytesBuilder localParts,
  BytesBuilder centralParts,
  int entryCount,
  int offset,
) {
  final Uint8List centralBytes = centralParts.takeBytes();
  final eocd = ByteData(22);
  eocd.setUint32(0, 0x06054b50, Endian.little);
  eocd.setUint16(4, 0, Endian.little);
  eocd.setUint16(6, 0, Endian.little);
  eocd.setUint16(8, entryCount, Endian.little);
  eocd.setUint16(10, entryCount, Endian.little);
  eocd.setUint32(12, centralBytes.length, Endian.little);
  eocd.setUint32(16, offset, Endian.little);
  eocd.setUint16(20, 0, Endian.little);

  localParts.add(centralBytes);
  localParts.add(eocd.buffer.asUint8List());
  return localParts.takeBytes();
}

/// One central-directory entry of a framework ZIP with its payload inflated.
/// Mode bits stay packed: each reader interprets [externalAttrs] itself.
List<({String path, Uint8List data, int externalAttrs})>
readRawFrameworkZipEntries(
  ByteData bd,
  Uint8List zipBytes,
  int entryCount,
  int cdOffset,
) {
  final rawInflate = ZLibCodec(raw: true);
  final entries = <({String path, Uint8List data, int externalAttrs})>[];
  var pos = cdOffset;
  for (var i = 0; i < entryCount; i++) {
    if (bd.getUint32(pos, Endian.little) != 0x02014b50) {
      throw FormatException('Invalid central directory header at $pos.');
    }
    final int method = bd.getUint16(pos + 10, Endian.little);
    final int compressedSize = bd.getUint32(pos + 20, Endian.little);
    final int nameLen = bd.getUint16(pos + 28, Endian.little);
    final int extraLen = bd.getUint16(pos + 30, Endian.little);
    final int commentLen = bd.getUint16(pos + 32, Endian.little);
    final int externalAttrs = bd.getUint32(pos + 38, Endian.little);
    final int localOffset = bd.getUint32(pos + 42, Endian.little);

    final String path = utf8.decode(
      zipBytes.sublist(pos + 46, pos + 46 + nameLen),
    );
    pos += 46 + nameLen + extraLen + commentLen;

    final int localNameLen = bd.getUint16(localOffset + 26, Endian.little);
    final int localExtraLen = bd.getUint16(localOffset + 28, Endian.little);
    final int dataStart = localOffset + 30 + localNameLen + localExtraLen;
    final Uint8List rawPayload = zipBytes.sublist(
      dataStart,
      dataStart + compressedSize,
    );

    final Uint8List data;
    if (method == 0) {
      data = Uint8List.fromList(rawPayload);
    } else if (method == 8) {
      data = Uint8List.fromList(rawInflate.decode(rawPayload));
    } else {
      throw UnsupportedError('Unsupported ZIP compression method: $method');
    }
    entries.add((path: path, data: data, externalAttrs: externalAttrs));
  }
  return entries;
}

/// Decodes a ZIP archive into [FrameworkZipEntry] items for inspection/testing.
List<FrameworkZipEntry> readFrameworkZipEntries(Uint8List zipBytes) {
  final bd = ByteData.sublistView(zipBytes);
  var eocdOffset = -1;
  for (int i = zipBytes.length - 22; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      eocdOffset = i;
      break;
    }
  }
  if (eocdOffset == -1) {
    throw const FormatException('Invalid ZIP archive: EOCD not found.');
  }
  final int entryCount = bd.getUint16(eocdOffset + 10, Endian.little);
  final int cdOffset = bd.getUint32(eocdOffset + 16, Endian.little);

  final entries = <FrameworkZipEntry>[];
  for (final ({Uint8List data, int externalAttrs, String path}) raw
      in readRawFrameworkZipEntries(
        bd,
        zipBytes,
        entryCount,
        cdOffset,
      )) {
    final int unixMode = (raw.externalAttrs >>> 16) & 0xFFFF;
    final int fileType = unixMode & 0xF000;
    final isSymlink = fileType == 0xA000;
    entries.add(
      FrameworkZipEntry(
        path: raw.path,
        data: raw.data,
        isExecutable: !isSymlink && ((unixMode & 0x49) != 0),
        isSymlink: isSymlink,
      ),
    );
  }
  return entries;
}

/// Extracts a framework ZIP archive produced by [createFrameworkZipBytes] into
/// [destDir], recreating symbolic links with their exact stored targets.
///
/// Bazel does not preserve directory symlinks inside tree artifacts when it
/// stages them as action or test inputs (a link to a directory is materialized
/// as a real directory), so `App.framework` travels between actions as its
/// deterministic `.framework.zip` and each consumer extracts it locally with
/// this helper. Extraction is deterministic: entries are applied in sorted
/// path order, and only file contents and link targets affect the result.
///
/// Entry paths and symlink targets must be relative and free of `..`
/// segments; anything else throws, since archives only ever come from the
/// rules' own producer.
void extractFrameworkZip(Uint8List zipBytes, Directory destDir) {
  final List<FrameworkZipEntry> entries = readFrameworkZipEntries(zipBytes)
    ..sort((a, b) => a.path.compareTo(b.path));
  if (entries.isEmpty) {
    throw const FormatException('Refusing to extract an empty ZIP archive.');
  }
  for (final entry in entries) {
    final List<String> segments = entry.path.split('/');
    if (segments.any((s) => s.isEmpty || s == '.' || s == '..') ||
        entry.path.startsWith('/')) {
      throw FormatException(
        'Refusing to extract unsafe ZIP entry: ${entry.path}',
      );
    }
    final destPath = '${destDir.path}/${entry.path}';
    if (entry.isSymlink) {
      final String target = utf8.decode(entry.data);
      final List<String> targetSegments = target.split('/');
      if (target.isEmpty ||
          target.startsWith('/') ||
          targetSegments.any((s) => s == '..')) {
        throw FormatException(
          'Refusing to extract unsafe symlink ${entry.path} -> $target',
        );
      }
      Directory(destPath).parent.createSync(recursive: true);
      createSymlinkReplacingSync(destPath, target);
    } else {
      final destFile = File(destPath);
      destFile.parent.createSync(recursive: true);
      destFile.writeAsBytesSync(entry.data);
    }
  }
}

void _verifyMachODylibBytes(Uint8List bytes, String description) {
  if (!isMachO64(bytes) && !isFatMachO(bytes)) {
    throw FormatException(
      '$description is not a 64-bit or universal Mach-O binary.',
    );
  }
  final List<Uint8List> slices = isFatMachO(bytes)
      ? extractFatSlices(bytes).map((s) => s.bytes).toList()
      : <Uint8List>[bytes];
  for (final slice in slices) {
    final bd = ByteData.sublistView(slice);
    final int filetype = bd.getUint32(12, Endian.little);
    if (filetype != mhDylib) {
      throw FormatException(
        '$description has Mach-O filetype 0x${filetype.toRadixString(16)}, '
        'expected MH_DYLIB (0x6).',
      );
    }
    parseLoadCommands(slice);
  }
}

void _verifyFrameworkInfoPlistXml(
  String plistXml,
  String frameworkName,
  String sourceDesc,
) {
  final RegExpMatch? pkgTypeMatch = RegExp(
    r'<key>\s*CFBundlePackageType\s*</key>\s*<string>\s*([^<\s]+)\s*</string>',
  ).firstMatch(plistXml);
  if (pkgTypeMatch == null || pkgTypeMatch.group(1) != 'FMWK') {
    throw FormatException(
      '$sourceDesc must declare CFBundlePackageType = FMWK, got: '
      '${pkgTypeMatch?.group(1)}',
    );
  }
  final RegExpMatch? execMatch = RegExp(
    r'<key>\s*CFBundleExecutable\s*</key>\s*<string>\s*([^<\s]+)\s*</string>',
  ).firstMatch(plistXml);
  if (execMatch == null || execMatch.group(1) != frameworkName) {
    throw FormatException(
      '$sourceDesc must declare CFBundleExecutable = $frameworkName, got: '
      '${execMatch?.group(1)}',
    );
  }
}

/// Verifies that a macOS `.framework` directory (and optional `AppleBundleInfo`
/// `.framework.zip` archive) has the canonical versioned layout required by
/// macOS `codesign`:
///   - `Versions/A/<binary>` (Mach-O `MH_DYLIB`),
///   - `Versions/A/Resources/Info.plist` (`CFBundlePackageType = FMWK`),
///   - `Versions/Current -> A` symlink,
///   - top-level symlinks `<binary> -> Versions/Current/<binary>` and
///     `Resources -> Versions/Current/Resources`,
///   - no unversioned regular files or directories at the framework root.
void verifyMacosFramework(
  String frameworkOrWrapperPath, {
  String frameworkName = 'App',
  String? frameworkZipPath,
}) {
  final Directory fwDir = _resolveFrameworkDir(
    frameworkOrWrapperPath,
    frameworkName,
  );

  final versionABinary = File('${fwDir.path}/Versions/A/$frameworkName');
  final versionAPlist = File('${fwDir.path}/Versions/A/Resources/Info.plist');
  _expectFrameworkFile(versionABinary.path);
  _expectFrameworkFile(versionAPlist.path);

  final currentLinkPath = '${fwDir.path}/Versions/Current';
  _expectFrameworkSymlink(currentLinkPath, 'A', 'symlink');

  final topBinaryLinkPath = '${fwDir.path}/$frameworkName';
  _expectFrameworkSymlink(
    topBinaryLinkPath,
    'Versions/Current/$frameworkName',
    'top-level symlink',
  );

  final topResourcesLinkPath = '${fwDir.path}/Resources';
  _expectFrameworkSymlink(
    topResourcesLinkPath,
    'Versions/Current/Resources',
    'top-level symlink',
  );

  _checkFrameworkTopEntries(fwDir, frameworkName);

  if (File(topBinaryLinkPath).resolveSymbolicLinksSync() !=
      versionABinary.resolveSymbolicLinksSync()) {
    throw StateError(
      '$topBinaryLinkPath does not resolve to ${versionABinary.path}.',
    );
  }
  if (File('$topResourcesLinkPath/Info.plist').resolveSymbolicLinksSync() !=
      versionAPlist.resolveSymbolicLinksSync()) {
    throw StateError(
      '$topResourcesLinkPath/Info.plist does not resolve to ${versionAPlist.path}.',
    );
  }

  final Uint8List binaryBytes = versionABinary.readAsBytesSync();
  _verifyMachODylibBytes(binaryBytes, versionABinary.path);
  _verifyFrameworkInfoPlistXml(
    versionAPlist.readAsStringSync(),
    frameworkName,
    versionAPlist.path,
  );

  if (frameworkZipPath != null && frameworkZipPath.isNotEmpty) {
    _verifyFrameworkZipEntries(frameworkZipPath, frameworkName);
  }
}

/// Resolves [frameworkOrWrapperPath] to the framework directory, unwrapping
/// Bazel's symlinked tree-artifact staging when present.
Directory _resolveFrameworkDir(
  String frameworkOrWrapperPath,
  String frameworkName,
) {
  var fwDir = frameworkOrWrapperPath.endsWith('.framework')
      ? Directory(frameworkOrWrapperPath)
      : Directory('$frameworkOrWrapperPath/$frameworkName.framework');
  if (!fwDir.existsSync()) {
    throw StateError('macOS framework directory not found: ${fwDir.path}');
  }

  // When Bazel's sandbox or runfiles tree materializes a tree artifact by
  // symlinking its leaf files into the execroot, unwrap to the underlying
  // tree artifact directory in the execroot so we inspect the real entries.
  final probeBinary = '${fwDir.path}/Versions/A/$frameworkName';
  if (FileSystemEntity.typeSync(probeBinary, followLinks: false) ==
      FileSystemEntityType.link) {
    final String target = Link(probeBinary).targetSync().replaceAll('\\', '/');
    final suffix = '/$frameworkName.framework/Versions/A/$frameworkName';
    if (target.startsWith('/') && target.endsWith(suffix)) {
      fwDir = Directory(
        target.substring(
          0,
          target.length - '/Versions/A/$frameworkName'.length,
        ),
      );
    }
  }
  return fwDir;
}

/// Throws unless [path] is a regular file.
void _expectFrameworkFile(String path) {
  final FileSystemEntityType type = FileSystemEntity.typeSync(
    path,
    followLinks: false,
  );
  if (type != FileSystemEntityType.file) {
    throw StateError('Expected regular file at $path, found $type');
  }
}

/// Throws unless [linkPath] is a symlink pointing at [expectedTarget].
/// [noun] names the link kind in the error ('symlink', 'top-level symlink').
void _expectFrameworkSymlink(
  String linkPath,
  String expectedTarget,
  String noun,
) {
  if (FileSystemEntity.typeSync(linkPath, followLinks: false) !=
      FileSystemEntityType.link) {
    throw StateError(
      'Expected $noun at $linkPath, found '
      '${FileSystemEntity.typeSync(linkPath, followLinks: false)}',
    );
  }
  final String target = Link(linkPath).targetSync();
  if (target != expectedTarget) {
    throw StateError('Expected $linkPath -> "$expectedTarget", got "$target"');
  }
}

/// Checks the framework root holds only `Versions/` and approved symlinks,
/// and that `Versions/` holds only `A` and `Current`.
void _checkFrameworkTopEntries(Directory fwDir, String frameworkName) {
  // Ensure no unsealed files or non-Versions directories exist at framework root.
  final allowedTopSymlinks = <String>{
    frameworkName,
    'Resources',
    'Headers',
    'Modules',
  };
  for (final FileSystemEntity entity in fwDir.listSync(followLinks: false)) {
    final String name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name == 'Versions') {
      if (entity is! Directory || entity is Link) {
        throw StateError('Expected Versions to be a real directory.');
      }
      continue;
    }
    if (entity is! Link || !allowedTopSymlinks.contains(name)) {
      throw StateError(
        'Ambiguous unsealed entry "$name" (${entity.runtimeType}) at root of '
        '${fwDir.path}; macOS codesign requires only Versions/ and top-level '
        'symlinks into Versions/Current/.',
      );
    }
  }

  for (final FileSystemEntity entity
      in Directory('${fwDir.path}/Versions').listSync(
        followLinks: false,
      )) {
    final String name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name != 'A' && name != 'Current') {
      throw StateError(
        'Unexpected entry "$name" inside ${fwDir.path}/Versions.',
      );
    }
  }
}

/// Verifies the framework ZIP archive entries for [frameworkName].
void _verifyFrameworkZipEntries(
  String frameworkZipPath,
  String frameworkName,
) {
  final zipFile = File(frameworkZipPath);
  if (!zipFile.existsSync()) {
    throw StateError('Framework zip archive not found: $frameworkZipPath');
  }
  final Map<String, FrameworkZipEntry> entries = {
    for (final e in readFrameworkZipEntries(zipFile.readAsBytesSync()))
      e.path: e,
  };
  final prefix = '$frameworkName.framework';
  final FrameworkZipEntry? binEntry =
      entries['$prefix/Versions/A/$frameworkName'];
  if (binEntry == null || binEntry.isSymlink || !binEntry.isExecutable) {
    throw StateError(
      'Expected executable Mach-O entry "$prefix/Versions/A/$frameworkName" '
      'in $frameworkZipPath, got: $binEntry',
    );
  }
  _verifyMachODylibBytes(
    binEntry.data,
    '$frameworkZipPath:$prefix/Versions/A/$frameworkName',
  );

  final FrameworkZipEntry? plistEntry =
      entries['$prefix/Versions/A/Resources/Info.plist'];
  if (plistEntry == null || plistEntry.isSymlink) {
    throw StateError(
      'Expected regular file entry "$prefix/Versions/A/Resources/Info.plist" '
      'in $frameworkZipPath',
    );
  }
  _verifyFrameworkInfoPlistXml(
    utf8.decode(plistEntry.data),
    frameworkName,
    '$frameworkZipPath:$prefix/Versions/A/Resources/Info.plist',
  );

  _checkFrameworkZipSymlinks(entries, frameworkZipPath, prefix, frameworkName);
}

/// Checks the expected symlink entries of a framework ZIP archive.
void _checkFrameworkZipSymlinks(
  Map<String, FrameworkZipEntry> entries,
  String frameworkZipPath,
  String prefix,
  String frameworkName,
) {
  final expectedLinks = <String, String>{
    '$prefix/Versions/Current': 'A',
    '$prefix/$frameworkName': 'Versions/Current/$frameworkName',
    '$prefix/Resources': 'Versions/Current/Resources',
  };
  for (final MapEntry<String, String> expected in expectedLinks.entries) {
    final FrameworkZipEntry? entry = entries[expected.key];
    if (entry == null || !entry.isSymlink) {
      throw StateError(
        'Expected symlink entry "${expected.key}" in $frameworkZipPath, '
        'found: ${entry == null ? "missing" : "regular file"}',
      );
    }
    final String target = utf8.decode(entry.data);
    if (target != expected.value) {
      throw StateError(
        'Expected symlink "${expected.key}" -> "${expected.value}" in '
        '$frameworkZipPath, got "$target"',
      );
    }
  }
}
