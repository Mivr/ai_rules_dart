/// Mach-O load-command parsing.
///
/// Raw [LoadCommand] decoding, the [Segment64Spec] load-command shape, and
/// the payload-floor walk used to find free space for rewritten commands.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'macho_constants.dart';
import 'macho_fat.dart' show isMachO32, isMachO64;
import 'macho_ranges.dart'
    show isZeroFillSectionType, sectionTypeOf, segmentNameOf;

/// Represents a single raw Mach-O load command.
class LoadCommand {
  final int cmd;
  final Uint8List bytes;

  new(this.cmd, this.bytes);

  int get cmdsize => bytes.length;
}

/// The fields of a 72-byte `LC_SEGMENT_64` load command with 0 sections.
/// Shared by [buildLcSegment64] and xtool_pack's stub synthesizer so a segment
/// command is described once.
typedef Segment64Spec = ({
  String segname,
  int vmaddr,
  int vmsize,
  int fileoff,
  int filesize,
  int maxprot,
  int initprot,
  int nsects,
  int flags,
});

/// Builds a 72-byte `LC_SEGMENT_64` load command with 0 sections.
LoadCommand buildLcSegment64(Segment64Spec spec) {
  final buf = Uint8List(72);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcSegment64, Endian.little);
  bd.setUint32(4, 72, Endian.little);
  final Uint8List nameBytes = ascii.encode(spec.segname);
  buf.setRange(8, 8 + math.min<int>(16, nameBytes.length), nameBytes);
  bd.setUint64(24, spec.vmaddr, Endian.little);
  bd.setUint64(32, spec.vmsize, Endian.little);
  bd.setUint64(40, spec.fileoff, Endian.little);
  bd.setUint64(48, spec.filesize, Endian.little);
  bd.setUint32(56, spec.maxprot, Endian.little);
  bd.setUint32(60, spec.initprot, Endian.little);
  bd.setUint32(64, spec.nsects, Endian.little);
  bd.setUint32(68, spec.flags, Endian.little);
  return LoadCommand(lcSegment64, buf);
}

/// Builds a 24-byte `LC_SYMTAB` load command.
LoadCommand buildLcSymtab({
  required int symoff,
  required int nsyms,
  required int stroff,
  required int strsize,
}) {
  final buf = Uint8List(24);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcSymtab, Endian.little);
  bd.setUint32(4, 24, Endian.little);
  bd.setUint32(8, symoff, Endian.little);
  bd.setUint32(12, nsyms, Endian.little);
  bd.setUint32(16, stroff, Endian.little);
  bd.setUint32(20, strsize, Endian.little);
  return LoadCommand(lcSymtab, buf);
}

/// Builds an 80-byte `LC_DYSYMTAB` load command with empty symbol tables.
LoadCommand buildLcDysymtab() {
  final buf = Uint8List(80);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcDysymtab, Endian.little);
  bd.setUint32(4, 80, Endian.little);
  return LoadCommand(lcDysymtab, buf);
}

/// Builds a 24-byte `LC_UUID` load command with the given 16-byte [uuid].
LoadCommand buildLcUuid(Uint8List uuid) {
  if (uuid.length != 16) {
    throw ArgumentError.value(uuid.length, 'uuid.length', 'Must be 16 bytes.');
  }
  final buf = Uint8List(24);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcUuid, Endian.little);
  bd.setUint32(4, 24, Endian.little);
  buf.setRange(8, 24, uuid);
  return LoadCommand(lcUuid, buf);
}

/// Builds a 24-byte `LC_BUILD_VERSION` load command (`ntools = 0`).
LoadCommand buildLcBuildVersion({
  required int platform,
  required int minos,
  required int sdk,
}) {
  final buf = Uint8List(24);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcBuildVersion, Endian.little);
  bd.setUint32(4, 24, Endian.little);
  bd.setUint32(8, platform, Endian.little);
  bd.setUint32(12, minos, Endian.little);
  bd.setUint32(16, sdk, Endian.little);
  bd.setUint32(20, 0, Endian.little); // ntools = 0
  return LoadCommand(lcBuildVersion, buf);
}

/// Builds an 8-byte-aligned `LC_ID_DYLIB` load command.
LoadCommand buildLcIdDylib(
  String installName, {
  int timestamp = 2,
  int currentVersion = 0x00010000,
  int compatibilityVersion = 0x00010000,
}) {
  final Uint8List strBytes = utf8.encode(installName);
  // dylib_command is 24 bytes header + string + NUL + padding to 8-byte boundary.
  final int unalignedSize = 24 + strBytes.length + 1;
  final int cmdsize = (unalignedSize + 7) & ~7;
  final buf = Uint8List(cmdsize);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcIdDylib, Endian.little);
  bd.setUint32(4, cmdsize, Endian.little);
  bd.setUint32(8, 24, Endian.little); // name.offset = 24
  bd.setUint32(12, timestamp, Endian.little);
  bd.setUint32(16, currentVersion, Endian.little);
  bd.setUint32(20, compatibilityVersion, Endian.little);
  buf.setRange(24, 24 + strBytes.length, strBytes);
  return LoadCommand(lcIdDylib, buf);
}

/// Builds an 8-byte-aligned `LC_RPATH` load command.
LoadCommand buildLcRpath(String rpath) {
  final Uint8List strBytes = utf8.encode(rpath);
  // rpath_command is 12 bytes header + string + NUL + padding to 8-byte boundary.
  final int unalignedSize = 12 + strBytes.length + 1;
  final int cmdsize = (unalignedSize + 7) & ~7;
  final buf = Uint8List(cmdsize);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcRpath, Endian.little);
  bd.setUint32(4, cmdsize, Endian.little);
  bd.setUint32(8, 12, Endian.little); // path.offset = 12
  buf.setRange(12, 12 + strBytes.length, strBytes);
  return LoadCommand(lcRpath, buf);
}

/// One `(offset, size)` file range a load command names: the range itself plus
/// [field], the offset of its `dataoff` word inside the command bytes, so a
/// rewrite can relocate the range without relearning the command layout.
/// Grouped as a class so range helpers stay under the parameter limit.
class CommandRange {
  const new({
    required this.field,
    required this.offset,
    required this.size,
  });

  /// Offset of the range's `dataoff` word inside the command bytes.
  final int field;

  /// The range's file offset.
  final int offset;

  /// The range's size in bytes.
  final int size;
}

/// Whether [cmd] is a single-range `linkedit_data` command: an
/// `(offset, size)` pair at command offsets +8/+12 naming a `__LINKEDIT`
/// payload the strip rewrite compacts. `LC_DYLD_INFO` and
/// `LC_DYLD_INFO_ONLY` carry five such pairs instead and are handled by
/// [movedTableRanges].
bool isSingleRangeLinkeditCommand(int cmd) {
  switch (cmd) {
    case lcFunctionStarts:
    case lcDataInCode:
    case lcDyldExportsTrie:
    case lcDyldChainedFixups:
    case lcCodeSignature:
    case lcSegmentSplitInfo:
    case lcDylibCodeSignDrs:
    case lcLinkerOptimizationHint:
      return true;
    default:
      return false;
  }
}

/// Every compactable file range [lc] names, in command order: all five
/// `(offset, size)` pairs for `LC_DYLD_INFO`/`LC_DYLD_INFO_ONLY`
/// (rebase, bind, weak bind, lazy bind, export), the single pair for the
/// commands [isSingleRangeLinkeditCommand] accepts, and nothing for any
/// other command.
///
/// Throws [FormatException] naming the command when a table command is
/// truncated.
List<CommandRange> movedTableRanges(LoadCommand lc) {
  if (lc.cmd == lcDyldInfo || lc.cmd == lcDyldInfoOnly) {
    if (lc.bytes.length < 48) {
      throw FormatException(
        'Truncated load command 0x${lc.cmd.toRadixString(16)}.',
      );
    }
    final bd = ByteData.sublistView(lc.bytes);
    return [
      for (var field = 8; field < 48; field += 8)
        CommandRange(
          field: field,
          offset: bd.getUint32(field, Endian.little),
          size: bd.getUint32(field + 4, Endian.little),
        ),
    ];
  }
  if (isSingleRangeLinkeditCommand(lc.cmd)) {
    if (lc.bytes.length < 16) {
      throw FormatException(
        'Truncated load command 0x${lc.cmd.toRadixString(16)}.',
      );
    }
    final bd = ByteData.sublistView(lc.bytes);
    return [
      CommandRange(
        field: 8,
        offset: bd.getUint32(8, Endian.little),
        size: bd.getUint32(12, Endian.little),
      ),
    ];
  }
  return const [];
}

/// Every relocatable file range [lc] names: the symbol and string tables for
/// `LC_SYMTAB`, the indirect table for `LC_DYSYMTAB`, and [movedTableRanges]
/// for the linkedit table commands. Used both to rewrite ranges after the
/// strip compacts `__LINKEDIT` and to verify the result.
List<CommandRange> fileRangesOf(LoadCommand lc) {
  if (lc.cmd == lcSymtab) {
    if (lc.bytes.length < 24) return const [];
    final bd = ByteData.sublistView(lc.bytes);
    return [
      CommandRange(
        field: 8,
        offset: bd.getUint32(8, Endian.little),
        size: bd.getUint32(12, Endian.little) * 16,
      ),
      CommandRange(
        field: 16,
        offset: bd.getUint32(16, Endian.little),
        size: bd.getUint32(20, Endian.little),
      ),
    ];
  }
  if (lc.cmd == lcDysymtab) {
    if (lc.bytes.length < 64) return const [];
    final bd = ByteData.sublistView(lc.bytes);
    return [
      CommandRange(
        field: 56,
        offset: bd.getUint32(56, Endian.little),
        size: bd.getUint32(60, Endian.little) * 4,
      ),
    ];
  }
  return movedTableRanges(lc);
}

/// The first payload byte of a Mach-O binary and what owns it: the segment
/// and section for a section, the load command and its table for a linkedit
/// table (for example `LC_SYMTAB`'s symbol table), or the segment for a
/// segment's own file range. [owner] is null when no range names a byte, in
/// which case [offset] is the file length.
typedef FirstPayload = ({int offset, String? owner});

/// The `LC_DYLD_INFO` pair table names, in command order: rebase, bind, weak
/// bind, lazy bind, export.
const _dyldInfoPairNames = [
  'rebase',
  'bind',
  'weak bind',
  'lazy bind',
  'export',
];

/// Tracks the lowest referenced file offset seen so far, and what owns it.
/// When two ranges share the lowest offset, the owner is the first one found
/// in load-command order: commands walk in list order, and within one command
/// the ranges walk in the order [_considerCommandPayload] reads them.
class _PayloadFloor {
  new(this.value);

  int value;

  String? owner;

  void consider(int offset, int size, String owner) {
    if (offset > 0 && size > 0 && offset < value) {
      value = offset;
      this.owner = owner;
    }
  }
}

/// Folds one load command's referenced file range into [floor], keeping each
/// range's owner alongside its offset so the refusal names what is in the way.
void _considerCommandPayload(LoadCommand lc, _PayloadFloor floor) {
  final bd = ByteData.sublistView(lc.bytes);
  switch (lc.cmd) {
    case lcSegment64:
      _considerSegmentPayload(lc, bd, floor);
    case lcSymtab:
      if (lc.bytes.length >= 24) {
        floor.consider(
          bd.getUint32(8, Endian.little),
          bd.getUint32(12, Endian.little) * 16,
          'LC_SYMTAB symbol table',
        );
        floor.consider(
          bd.getUint32(16, Endian.little),
          bd.getUint32(20, Endian.little),
          'LC_SYMTAB string table',
        );
      }
    case lcFunctionStarts:
    case lcDataInCode:
    case lcCodeSignature:
    case lcDyldExportsTrie:
    case lcDyldChainedFixups:
    case lcSegmentSplitInfo:
    case lcDylibCodeSignDrs:
    case lcLinkerOptimizationHint:
      if (lc.bytes.length >= 16) {
        floor.consider(
          bd.getUint32(8, Endian.little),
          bd.getUint32(12, Endian.little),
          '${_loadCommandName(lc.cmd)} table',
        );
      }
    case lcDyldInfo:
    case lcDyldInfoOnly:
      if (lc.bytes.length >= 48) {
        for (var i = 0; i < 5; i++) {
          final int field = 8 + i * 8;
          floor.consider(
            bd.getUint32(field, Endian.little),
            bd.getUint32(field + 4, Endian.little),
            '${_loadCommandName(lc.cmd)} ${_dyldInfoPairNames[i]} table',
          );
        }
      }
  }
}

/// Folds a `LC_SEGMENT_64` command's file range and its sections into [floor].
/// Zero-fill sections name no file bytes whatever their `offset` field holds,
/// so they never lower the floor; every other section counts.
void _considerSegmentPayload(
  LoadCommand lc,
  ByteData bd,
  _PayloadFloor floor,
) {
  if (lc.bytes.length < 72) return;
  final String segname = segmentNameOf(lc);
  final int fileoff = bd.getUint64(40, Endian.little);
  final int filesize = bd.getUint64(48, Endian.little);
  final int nsects = bd.getUint32(64, Endian.little);
  if (fileoff > 0 && filesize > 0) {
    floor.consider(
      fileoff,
      filesize,
      segname.isEmpty
          ? '${_loadCommandName(lc.cmd)} segment'
          : 'segment $segname',
    );
  }
  // Inspect each section_64 (80 bytes each starting at offset 72).
  for (var s = 0; s < nsects; s++) {
    final int sectOff = 72 + s * 80;
    if (sectOff + 80 <= lc.bytes.length) {
      if (isZeroFillSectionType(sectionTypeOf(bd, sectOff))) {
        continue;
      }
      final int sSize = bd.getUint64(sectOff + 40, Endian.little);
      final int sOffset = bd.getUint32(sectOff + 48, Endian.little);
      final String name = ascii
          .decode(lc.bytes.sublist(sectOff, sectOff + 16))
          .split('\x00')
          .first;
      floor.consider(sOffset, sSize, 'section $name of segment $segname');
    }
  }
}

/// Finds the lowest non-zero file offset referenced by any segment, section,
/// or linkedit table in the Mach-O binary, and what owns it. Load commands
/// may grow up to this boundary without overwriting section/segment payload
/// bytes. When two ranges share the lowest offset, the owner is the first one
/// found in load-command order (see [_PayloadFloor]).
FirstPayload findFirstPayload(List<LoadCommand> commands, int totalLength) {
  final floor = _PayloadFloor(totalLength);
  for (final lc in commands) {
    _considerCommandPayload(lc, floor);
  }
  return (offset: floor.value, owner: floor.owner);
}

/// The `LC_*` name of a payload-floor load command [cmd], or its hex type.
String _loadCommandName(int cmd) {
  switch (cmd) {
    case lcSegment64:
      return 'LC_SEGMENT_64';
    case lcSymtab:
      return 'LC_SYMTAB';
    case lcDysymtab:
      return 'LC_DYSYMTAB';
    case lcFunctionStarts:
      return 'LC_FUNCTION_STARTS';
    case lcDataInCode:
      return 'LC_DATA_IN_CODE';
    case lcCodeSignature:
      return 'LC_CODE_SIGNATURE';
    case lcDyldExportsTrie:
      return 'LC_DYLD_EXPORTS_TRIE';
    case lcDyldChainedFixups:
      return 'LC_DYLD_CHAINED_FIXUPS';
    case lcSegmentSplitInfo:
      return 'LC_SEGMENT_SPLIT_INFO';
    case lcDylibCodeSignDrs:
      return 'LC_DYLIB_CODE_SIGN_DRS';
    case lcLinkerOptimizationHint:
      return 'LC_LINKER_OPTIMIZATION_HINT';
    case lcDyldInfo:
      return 'LC_DYLD_INFO';
    case lcDyldInfoOnly:
      return 'LC_DYLD_INFO_ONLY';
    default:
      return 'load command 0x${cmd.toRadixString(16)}';
  }
}

/// Parses the load commands from a 64-bit Mach-O binary.
List<LoadCommand> parseLoadCommands(Uint8List bytes) {
  if (!isMachO64(bytes)) {
    if (isMachO32(bytes)) {
      throw const FormatException(
        'Unsupported 32-bit Mach-O binary; expected 64-bit Mach-O.',
      );
    }
    throw const FormatException('Not a 64-bit little-endian Mach-O binary.');
  }
  final bd = ByteData.sublistView(bytes);
  final int ncmds = bd.getUint32(16, Endian.little);
  final int sizeofcmds = bd.getUint32(20, Endian.little);
  if (mhHeaderSize64 + sizeofcmds > bytes.length) {
    throw const FormatException('Truncated Mach-O load commands.');
  }
  final commands = <LoadCommand>[];
  int offset = mhHeaderSize64;
  for (var i = 0; i < ncmds; i++) {
    if (offset + 8 > mhHeaderSize64 + sizeofcmds) {
      throw const FormatException(
        'Load command header extends past sizeofcmds.',
      );
    }
    final int cmd = bd.getUint32(offset, Endian.little);
    final int cmdsize = bd.getUint32(offset + 4, Endian.little);
    if (cmdsize < 8 || offset + cmdsize > mhHeaderSize64 + sizeofcmds) {
      throw FormatException('Invalid cmdsize $cmdsize at offset $offset.');
    }
    commands.add(
      LoadCommand(
        cmd,
        Uint8List.fromList(bytes.sublist(offset, offset + cmdsize)),
      ),
    );
    offset += cmdsize;
  }
  return commands;
}
