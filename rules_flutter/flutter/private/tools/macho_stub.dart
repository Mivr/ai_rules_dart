/// Mach-O stub generation: the `stub` subcommand and its core.
///
/// Builds a minimal unsigned `MH_DYLIB` or `MH_EXECUTE` image from raw
/// load commands, with a deterministic content-derived `LC_UUID`.

import 'dart:io';
import 'dart:typed_data';

import 'sha256.dart' as sha256lib;

import 'macho_cli.dart' show FlagCursor, usageError;
import 'macho_constants.dart';
import 'macho_fat.dart' show parsePackedVersion, parsePlatform;
import 'macho_parse.dart'
    show
        LoadCommand,
        buildLcBuildVersion,
        buildLcDysymtab,
        buildLcIdDylib,
        buildLcRpath,
        buildLcSegment64,
        buildLcSymtab,
        buildLcUuid;

/// Parsed `stub` subcommand flags.
class _StubArgs {
  new({
    required this.outputPath,
    required this.arch,
    required this.platformName,
    required this.minOsStr,
    required this.sdkVersionStr,
    required this.installName,
    required this.typeStr,
  });

  final String? outputPath;
  final String? arch;
  final String? platformName;
  final String? minOsStr;
  final String? sdkVersionStr;
  final String? installName;
  final String typeStr;
}

/// Parses `stub` flags; unknown flags fail usage.
_StubArgs _parseStubArgs(List<String> args) {
  String? outputPath;
  String? arch;
  String? platformName;
  String? minOsStr;
  String? sdkVersionStr;
  String? installName;
  var typeStr = 'dylib';
  final flags = FlagCursor(args);
  while (flags.moveNext()) {
    final String arg = flags.current;
    switch (arg) {
      case '--output':
        outputPath = flags.take('--output');
      case '--arch':
        arch = flags.take('--arch');
      case '--platform':
        platformName = flags.take('--platform');
      case '--min-os':
        minOsStr = flags.take('--min-os');
      case '--sdk-version':
        sdkVersionStr = flags.take('--sdk-version');
      case '--install-name':
        installName = flags.take('--install-name');
      case '--type':
        typeStr = flags.take('--type');
      default:
        usageError('Unknown flag for stub: $arg');
    }
  }
  return _StubArgs(
    outputPath: outputPath,
    arch: arch,
    platformName: platformName,
    minOsStr: minOsStr,
    sdkVersionStr: sdkVersionStr,
    installName: installName,
    typeStr: typeStr,
  );
}

/// Runs the `stub` subcommand: parses [args] and writes a stub Mach-O file.
void runStub(List<String> args) {
  final _StubArgs parsed = _parseStubArgs(args);
  final String? outputPath = parsed.outputPath;
  final String? arch = parsed.arch;
  final String? platformName = parsed.platformName;
  final String? minOsStr = parsed.minOsStr;
  if (parsed.typeStr != 'dylib' && parsed.typeStr != 'execute') {
    usageError('--type must be "dylib" or "execute", got "${parsed.typeStr}"');
  }

  if (outputPath == null ||
      arch == null ||
      platformName == null ||
      minOsStr == null ||
      (parsed.typeStr == 'dylib' && parsed.installName == null)) {
    usageError(
      'stub requires --output, --arch, --platform, --min-os, and --install-name',
    );
  }

  final int platform = parsePlatform(platformName);
  final int minOs = parsePackedVersion(minOsStr);
  final String? sdkVersionStr = parsed.sdkVersionStr;
  final int sdkVersion = sdkVersionStr != null
      ? parsePackedVersion(sdkVersionStr)
      : minOs;

  final Uint8List bytes = generateStubMachO(
    arch: arch,
    platform: platform,
    minOs: minOs,
    sdkVersion: sdkVersion,
    installName: parsed.installName ?? '',
    fileType: parsed.typeStr == 'execute' ? mhExecute : mhDylib,
  );

  final outFile = File(outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(bytes);
}

/// Synthesizes a well-formed 64-bit Mach-O `MH_DYLIB` or `MH_EXECUTE` stub binary.
///
/// Includes `__TEXT` and `__LINKEDIT` segments, `LC_ID_DYLIB` (for `MH_DYLIB`),
/// `LC_SYMTAB`, `LC_DYSYMTAB`, a deterministic content-derived `LC_UUID`,
/// `LC_BUILD_VERSION`, and `MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL` flags
/// so Apple tools (`codesign`, `otool`, `ld64`, `llvm-objdump`) accept it.
Uint8List generateStubMachO({
  required String arch,
  required int platform,
  required int minOs,
  required int sdkVersion,
  required String installName,
  int fileType = mhDylib,
}) {
  final (int cputype, int cpusubtype) = _stubCpuType(arch);

  // Page size: 16 KB (0x4000) for arm64, 4 KB (0x1000) for x86_64.
  final pageSize = arch == 'arm64' ? 0x4000 : 0x1000;

  final List<LoadCommand> commands = _stubCommands(
    platform: platform,
    minOs: minOs,
    sdkVersion: sdkVersion,
    installName: installName,
    fileType: fileType,
    pageSize: pageSize,
  );

  var sizeofcmds = 0;
  for (final lc in commands) {
    sizeofcmds += lc.cmdsize;
  }

  final int flags =
      mhNoundefs |
      mhDyldlink |
      mhTwolevel |
      (fileType == mhExecute ? mhPie : mhNoReexportedDylibs);

  final out = Uint8List(pageSize + _stubLinkeditFileSize);
  _writeStubHeader(
    out,
    (
      cputype: cputype,
      cpusubtype: cpusubtype,
      fileType: fileType,
      commandCount: commands.length,
      sizeofcmds: sizeofcmds,
      flags: flags,
    ),
  );

  int offset = mhHeaderSize64;
  var uuidDataOffset = -1;
  for (final lc in commands) {
    if (lc.cmd == lcUuid) {
      uuidDataOffset = offset + 8;
    }
    out.setRange(offset, offset + lc.cmdsize, lc.bytes);
    offset += lc.cmdsize;
  }

  // Standard Mach-O string table begins with a leading space and NUL byte.
  out[pageSize] = 0x20;
  out[pageSize + 1] = 0x00;

  // Compute deterministic UUID from the binary content (with UUID bytes zeroed),
  // formatted as an RFC 4122 v5 UUID (matching ld64 / ld64.lld).
  _stampStubUuid(out, uuidDataOffset);

  return out;
}

// 8-byte aligned empty string table (" \0" padded to 8 bytes) in the stub's
// __LINKEDIT.
const _stubLinkeditFileSize = 8;

/// The cputype/cpusubtype pair for a stub [arch].
(int, int) _stubCpuType(String arch) {
  switch (arch) {
    case 'arm64':
      return (cpuTypeArm64, cpuSubtypeArm64All);
    case 'x86_64':
      return (cpuTypeX86_64, cpuSubtypeX86_64All);
    default:
      throw ArgumentError.value(arch, 'arch', 'Expected "arm64" or "x86_64".');
  }
}

/// The stub's load commands: segments, symtabs, identity, UUID and version.
List<LoadCommand> _stubCommands({
  required int platform,
  required int minOs,
  required int sdkVersion,
  required String installName,
  required int fileType,
  required int pageSize,
}) {
  // LC_SEGMENT_64 (__TEXT) - 72 bytes (0 sections).
  final LoadCommand textSeg = buildLcSegment64((
    segname: '__TEXT',
    vmaddr: 0,
    vmsize: pageSize,
    fileoff: 0,
    filesize: pageSize,
    maxprot: 5, // VM_PROT_READ | VM_PROT_EXECUTE
    initprot: 5, // VM_PROT_READ | VM_PROT_EXECUTE
    nsects: 0,
    flags: 0,
  ));

  // LC_SEGMENT_64 (__LINKEDIT) - 72 bytes (0 sections).
  final LoadCommand linkeditSeg = buildLcSegment64((
    segname: '__LINKEDIT',
    vmaddr: pageSize,
    vmsize: pageSize,
    fileoff: pageSize,
    filesize: _stubLinkeditFileSize,
    maxprot: 1, // VM_PROT_READ
    initprot: 1, // VM_PROT_READ
    nsects: 0,
    flags: 0,
  ));

  // LC_SYMTAB and LC_DYSYMTAB pointing into __LINKEDIT.
  final LoadCommand symtab = buildLcSymtab(
    symoff: pageSize,
    nsyms: 0,
    stroff: pageSize,
    strsize: _stubLinkeditFileSize,
  );
  final LoadCommand dysymtab = buildLcDysymtab();
  final LoadCommand placeholderUuid = buildLcUuid(Uint8List(16));
  final LoadCommand buildVersion = buildLcBuildVersion(
    platform: platform,
    minos: minOs,
    sdk: sdkVersion,
  );

  return <LoadCommand>[
    textSeg,
    linkeditSeg,
    if (fileType == mhDylib && installName.isNotEmpty)
      buildLcIdDylib(installName),
    symtab,
    dysymtab,
    placeholderUuid,
    buildVersion,
    if (fileType == mhExecute) ...[
      buildLcRpath('@executable_path/Frameworks'),
      if (platform == platformMacos)
        buildLcRpath('@executable_path/../Frameworks'),
    ],
  ];
}

/// The Mach-O header fields written over a synthesized stub binary. Grouped
/// into a record so the header writer stays small.
typedef _StubHeader = ({
  int cputype,
  int cpusubtype,
  int fileType,
  int commandCount,
  int sizeofcmds,
  int flags,
});

/// Writes the 64-bit Mach-O header over [out].
void _writeStubHeader(Uint8List out, _StubHeader header) {
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, mhMagic64, Endian.little);
  bd.setUint32(4, header.cputype, Endian.little);
  bd.setUint32(8, header.cpusubtype, Endian.little);
  bd.setUint32(12, header.fileType, Endian.little);
  bd.setUint32(16, header.commandCount, Endian.little);
  bd.setUint32(20, header.sizeofcmds, Endian.little);
  bd.setUint32(24, header.flags, Endian.little);
  bd.setUint32(28, 0, Endian.little);
}

/// Stamps the content-derived UUID at [uuidDataOffset] (or skips when absent).
void _stampStubUuid(Uint8List out, int uuidDataOffset) {
  if (uuidDataOffset < 0) return;
  final Uint8List digest = sha256(out);
  final uuid = Uint8List.fromList(digest.sublist(0, 16));
  uuid[6] = (uuid[6] & 0x0f) | 0x50;
  uuid[8] = (uuid[8] & 0x3f) | 0x80;
  out.setRange(uuidDataOffset, uuidDataOffset + 16, uuid);
}

/// Computes the 32-byte SHA-256 digest of [data].
Uint8List sha256(Uint8List data) => Uint8List.fromList(sha256lib.sha256(data));
