/// Minimal Mach-O `MH_EXECUTE` stub generation.
///
/// Builds a tiny unsigned executable from a [StubRunnerSpec]: Mach-O load
/// commands for `__TEXT`/`__LINKEDIT`, dyld, rpath and build version, plus
/// an optional metadata payload.

import 'dart:convert';
import 'dart:typed_data';

import 'macho_parse.dart' show Segment64Spec;
import 'xtool_bundle.dart' show encodeMachORpathCommand;
import 'xtool_hash.dart' show sha256Bytes;
import 'zip_writer.dart' show setUint64LE;

int _packMachOVersion(String version) {
  final List<String> parts = version.split('.');
  final int major = parts.isNotEmpty ? (int.tryParse(parts[0]) ?? 0) : 0;
  final int minor = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
  final int patch = parts.length > 2 ? (int.tryParse(parts[2]) ?? 0) : 0;
  return ((major & 0xffff) << 16) | ((minor & 0xff) << 8) | (patch & 0xff);
}

int _machOPlatformConstant(String platform) {
  switch (platform) {
    case 'macos':
      return 1; // PLATFORM_MACOS
    case 'ios':
      return 2; // PLATFORM_IOS
    case 'ios_sim':
      return 7; // PLATFORM_IOSSIMULATOR
    default:
      throw ArgumentError('Unsupported platform: $platform');
  }
}

Uint8List _encodeMachOSegment64Command(Segment64Spec spec) {
  final bytes = Uint8List(72);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x19, Endian.little); // LC_SEGMENT_64
  bd.setUint32(4, 72, Endian.little);
  final Uint8List nameBytes = ascii.encode(spec.segname);
  bytes.setRange(
    8,
    8 + (nameBytes.length > 16 ? 16 : nameBytes.length),
    nameBytes,
  );
  setUint64LE(bd, 24, spec.vmaddr);
  setUint64LE(bd, 32, spec.vmsize);
  setUint64LE(bd, 40, spec.fileoff);
  setUint64LE(bd, 48, spec.filesize);
  bd.setInt32(56, spec.maxprot, Endian.little);
  bd.setInt32(60, spec.initprot, Endian.little);
  bd.setUint32(64, spec.nsects, Endian.little); // nsects
  bd.setUint32(68, spec.flags, Endian.little); // flags
  return bytes;
}

Uint8List _encodeMachOSymtabCommand({
  required int symoff,
  required int nsyms,
  required int stroff,
  required int strsize,
}) {
  final bytes = Uint8List(24);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x02, Endian.little); // LC_SYMTAB
  bd.setUint32(4, 24, Endian.little);
  bd.setUint32(8, symoff, Endian.little);
  bd.setUint32(12, nsyms, Endian.little);
  bd.setUint32(16, stroff, Endian.little);
  bd.setUint32(20, strsize, Endian.little);
  return bytes;
}

Uint8List _encodeMachODysymtabCommand() {
  final bytes = Uint8List(80);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x0b, Endian.little); // LC_DYSYMTAB
  bd.setUint32(4, 80, Endian.little);
  return bytes;
}

Uint8List _encodeMachOUuidCommand(Uint8List uuid16) {
  final bytes = Uint8List(24);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x1b, Endian.little); // LC_UUID
  bd.setUint32(4, 24, Endian.little);
  bytes.setRange(8, 24, uuid16);
  return bytes;
}

Uint8List _encodeMachOLoadDylibCommand(String installName) {
  final Uint8List nameBytes = utf8.encode(installName);
  const headerSize = 24;
  final int unpadded = headerSize + nameBytes.length + 1;
  final int cmdSize = (unpadded + 7) & ~7;
  final bytes = Uint8List(cmdSize);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x0c, Endian.little); // LC_LOAD_DYLIB
  bd.setUint32(4, cmdSize, Endian.little);
  bd.setUint32(8, headerSize, Endian.little); // name offset
  bd.setUint32(12, 2, Endian.little); // timestamp
  bd.setUint32(16, 0x00010000, Endian.little); // current_version 1.0.0
  bd.setUint32(20, 0x00010000, Endian.little); // compatibility_version 1.0.0
  bytes.setRange(headerSize, headerSize + nameBytes.length, nameBytes);
  return bytes;
}

Uint8List _encodeMachOBuildVersionCommand({
  required int platform,
  required int minos,
  required int sdk,
}) {
  final bytes = Uint8List(24);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x32, Endian.little); // LC_BUILD_VERSION
  bd.setUint32(4, 24, Endian.little); // cmdsize
  bd.setUint32(8, platform, Endian.little);
  bd.setUint32(12, minos, Endian.little);
  bd.setUint32(16, sdk, Endian.little);
  bd.setUint32(20, 0, Endian.little); // ntools = 0
  return bytes;
}

({int cpuType, int cpuSubtype, int pageSize}) _stubArchParams(String arch) {
  switch (arch) {
    case 'arm64':
      // CPU_TYPE_ARM64 / CPU_SUBTYPE_ARM64_ALL, 16 KiB pages.
      return (cpuType: 0x0100000c, cpuSubtype: 0, pageSize: 0x4000);
    case 'x86_64':
      // CPU_TYPE_X86_64 / CPU_SUBTYPE_X86_64_ALL, 4 KiB pages.
      return (cpuType: 0x01000007, cpuSubtype: 3, pageSize: 0x1000);
    default:
      throw ArgumentError('Unsupported architecture "$arch".');
  }
}

List<Uint8List> _stubLoadCommands(
  StubRunnerSpec spec,
  int versionPacked,
  int pageSize,
  int linkeditFileSize,
) {
  final String platform = spec.platform;
  return [
    _encodeMachOBuildVersionCommand(
      platform: _machOPlatformConstant(platform),
      minos: versionPacked,
      sdk: versionPacked,
    ),
    _encodeMachOSegment64Command((
      segname: '__TEXT',
      vmaddr: 0,
      vmsize: pageSize,
      fileoff: 0,
      filesize: pageSize,
      maxprot: 5,
      initprot: 5,
      nsects: 0,
      flags: 0,
    )),
    _encodeMachOSegment64Command((
      segname: '__LINKEDIT',
      vmaddr: pageSize,
      vmsize: pageSize,
      fileoff: pageSize,
      filesize: linkeditFileSize,
      maxprot: 1,
      initprot: 1,
      nsects: 0,
      flags: 0,
    )),
    _encodeMachOSymtabCommand(
      symoff: pageSize,
      nsyms: 0,
      stroff: pageSize,
      strsize: linkeditFileSize,
    ),
    _encodeMachODysymtabCommand(),
    _encodeMachOUuidCommand(Uint8List(16)),
    encodeMachORpathCommand('@executable_path/Frameworks'),
    if (platform == 'macos')
      encodeMachORpathCommand('@executable_path/../Frameworks'),
    for (final fw in spec.linkedFrameworkNames)
      _encodeMachOLoadDylibCommand('@rpath/$fw.framework/$fw'),
    for (final sdkFw in spec.sdkFrameworks)
      _encodeMachOLoadDylibCommand(
        platform == 'macos'
            ? '/System/Library/Frameworks/$sdkFw.framework/Versions/A/$sdkFw'
            : '/System/Library/Frameworks/$sdkFw.framework/$sdkFw',
      ),
    for (final dylib in spec.sdkDylibs)
      _encodeMachOLoadDylibCommand(
        '/usr/lib/${dylib.startsWith('lib') ? dylib : 'lib$dylib'}.dylib',
      ),
  ];
}

/// Writes [loadCommands] after the Mach-O header, returning the file offset
/// of the `LC_UUID` payload for later stamping.
int _writeStubCommands(Uint8List out, List<Uint8List> loadCommands) {
  var offset = 32;
  var uuidDataOffset = -1;
  for (final cmd in loadCommands) {
    final int cmdId = ByteData.sublistView(cmd).getUint32(0, Endian.little);
    if (cmdId == 0x1b) {
      uuidDataOffset = offset + 8;
    }
    out.setRange(offset, offset + cmd.length, cmd);
    offset += cmd.length;
  }
  return uuidDataOffset;
}

void _stampStubUuid(Uint8List out, int uuidDataOffset) {
  if (uuidDataOffset < 0) return;
  final Uint8List digest = sha256Bytes(out);
  final uuid = Uint8List.fromList(digest.sublist(0, 16));
  uuid[6] = (uuid[6] & 0x0f) | 0x50;
  uuid[8] = (uuid[8] & 0x3f) | 0x80;
  out.setRange(uuidDataOffset, uuidDataOffset + 16, uuid);
}

/// The inputs for synthesizing a stub runner Mach-O binary: target platform
/// and version plus linked frameworks, libraries, and metadata. Grouped so
/// the stub entry points stay small.
class StubRunnerSpec {
  const new({
    required this.platform,
    this.arch = 'arm64',
    required this.minimumOsVersion,
    this.linkedFrameworkNames = const [],
    this.sdkFrameworks = const [],
    this.sdkDylibs = const [],
    this.metadataEntries = const [],
  });

  /// The target platform (`ios`, `ios_sim`, or `macos`).
  final String platform;

  /// The target architecture (`arm64` or `x86_64`).
  final String arch;

  /// The minimum-OS version string.
  final String minimumOsVersion;

  /// The embedded frameworks to `LC_LOAD_DYLIB`.
  final List<String> linkedFrameworkNames;

  /// The system frameworks to `LC_LOAD_DYLIB`.
  final List<String> sdkFrameworks;

  /// The `/usr/lib` libraries to `LC_LOAD_DYLIB`.
  final List<String> sdkDylibs;

  /// The metadata lines embedded in `__TEXT`.
  final List<String> metadataEntries;
}

/// Synthesizes a 64-bit Mach-O `MH_EXECUTE` runner binary with
/// `LC_BUILD_VERSION`, `__TEXT` / `__LINKEDIT` segments, `LC_SYMTAB`,
/// `LC_DYSYMTAB`, `LC_UUID`, `LC_RPATH`, and `LC_LOAD_DYLIB` commands.
Uint8List generateStubExecutableMachO(StubRunnerSpec spec) {
  final ({int cpuSubtype, int cpuType, int pageSize}) archParams =
      _stubArchParams(spec.arch);
  final int pageSize = archParams.pageSize;
  const linkeditFileSize = 8;
  final int versionPacked = _packMachOVersion(spec.minimumOsVersion);

  final List<Uint8List> loadCommands = _stubLoadCommands(
    spec,
    versionPacked,
    pageSize,
    linkeditFileSize,
  );
  final int sizeofcmds = loadCommands.fold<int>(0, (s, c) => s + c.length);
  final metadataText = spec.metadataEntries.isEmpty
      ? ''
      : '${spec.metadataEntries.join('\n')}\n';
  final Uint8List metadataBytes = utf8.encode(metadataText);

  final int totalSize = pageSize + linkeditFileSize;
  final out = Uint8List(totalSize);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, 0xfeedfacf, Endian.little); // MH_MAGIC_64
  bd.setInt32(4, archParams.cpuType, Endian.little);
  bd.setInt32(8, archParams.cpuSubtype, Endian.little);
  bd.setUint32(12, 0x2, Endian.little); // MH_EXECUTE
  bd.setUint32(16, loadCommands.length, Endian.little);
  bd.setUint32(20, sizeofcmds, Endian.little);
  bd.setUint32(24, 0x00200001, Endian.little); // MH_NOUNDEFS | MH_PIE
  bd.setUint32(28, 0, Endian.little); // reserved

  final int uuidDataOffset = _writeStubCommands(out, loadCommands);

  // Leave 64 bytes of zero padding after load commands before writing metadata
  // inside __TEXT so any subsequent load-command patching has room.
  final int metaStart = 32 + sizeofcmds + 64;
  if (metadataBytes.isNotEmpty &&
      metaStart + metadataBytes.length <= pageSize) {
    out.setRange(metaStart, metaStart + metadataBytes.length, metadataBytes);
  }

  // Standard Mach-O string table in __LINKEDIT begins with " \0".
  out[pageSize] = 0x20;
  out[pageSize + 1] = 0x00;

  _stampStubUuid(out, uuidDataOffset);
  return out;
}
