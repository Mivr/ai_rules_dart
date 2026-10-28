import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';

/// Inspects the split symbols file and the raw snapshot a build produces.
///
/// The symbols file must be a real DWARF container, not an empty placeholder:
/// it has to be ELF or Mach-O and carry a `.debug_info` / `__debug_info`
/// section. The snapshot file must still be the raw `.aot` bytes in the
/// `snapshot` output group, not the run launcher.
void main(List<String> args) {
  if (args.length != 3) {
    stderr.writeln(
      'usage: inspect_test.dart <exe-debug> <aot-debug> <snapshot>',
    );
    exit(64);
  }
  final runfiles = Runfiles.create();
  for (final path in args.take(2)) {
    final symbols = File(runfiles.rlocation(path)).readAsBytesSync();
    if (!_hasDebugSection(symbols)) {
      stderr.writeln('FAIL: $path has no .debug_info/__debug_info section');
      exit(1);
    }
  }
  final snapshot = File(runfiles.rlocation(args[2])).readAsBytesSync();
  if (!_isElf(snapshot)) {
    stderr.writeln(
      'FAIL: the snapshot output group did not expose the raw AOT ELF',
    );
    exit(1);
  }
  stdout.writeln(
    'PASS: split symbols carry DWARF and the snapshot group is raw',
  );
}

/// Whether [bytes] is an ELF or Mach-O container with a debug-info section.
bool _hasDebugSection(Uint8List bytes) {
  if (_isElf(bytes)) return _elfSections(bytes).contains('.debug_info');
  if (_isMachO(bytes)) return _machOSections(bytes).contains('__debug_info');
  return false;
}

/// Whether [bytes] starts with the ELF magic.
bool _isElf(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x7f &&
    bytes[1] == 0x45 &&
    bytes[2] == 0x4c &&
    bytes[3] == 0x46;

/// Whether [bytes] starts with a thin Mach-O magic.
bool _isMachO(Uint8List bytes) {
  if (bytes.length < 4) return false;
  final magic = _uint(ByteData.sublistView(bytes), 0, 4, Endian.big);
  return magic == 0xfeedface ||
      magic == 0xfeedfacf ||
      magic == 0xcefaedfe ||
      magic == 0xcffaedfe;
}

/// Returns the ELF section names in [bytes], or an empty list when malformed.
List<String> _elfSections(Uint8List bytes) {
  if (bytes.length < 0x34) return const [];
  final data = ByteData.sublistView(bytes);
  final is64 = bytes[4] == 2;
  final endian = bytes[5] == 2 ? Endian.big : Endian.little;
  final shoff = is64
      ? _uint(data, 0x28, 8, endian)
      : _uint(data, 0x20, 4, endian);
  final shentsize = _uint(data, is64 ? 0x3a : 0x2e, 2, endian);
  final shnum = _uint(data, is64 ? 0x3c : 0x30, 2, endian);
  final shstrndx = _uint(data, is64 ? 0x3e : 0x32, 2, endian);
  if (shoff == 0 || shentsize == 0 || shnum == 0 || shstrndx >= shnum) {
    return const [];
  }
  final strings = _elfSection(data, shoff, shentsize, shstrndx, endian);
  final names = <String>[];
  for (var i = 0; i < shnum; i++) {
    final section = _elfSection(data, shoff, shentsize, i, endian);
    final start = strings.offset + _uint(data, section.header, 4, endian);
    names.add(_cString(bytes, start, strings.offset + strings.size));
  }
  return names;
}

/// One ELF section header's position and payload range.
({int header, int offset, int size}) _elfSection(
  ByteData data,
  int shoff,
  int shentsize,
  int index,
  Endian endian,
) {
  final base = shoff + index * shentsize;
  final is64 = shentsize >= 64;
  return (
    header: base,
    offset: is64
        ? _uint(data, base + 0x18, 8, endian)
        : _uint(data, base + 0x10, 4, endian),
    size: is64
        ? _uint(data, base + 0x20, 8, endian)
        : _uint(data, base + 0x14, 4, endian),
  );
}

/// Returns the Mach-O section names in [bytes], or an empty list when
/// malformed.
List<String> _machOSections(Uint8List bytes) {
  if (bytes.length < 28) return const [];
  final data = ByteData.sublistView(bytes);
  final magic = _uint(data, 0, 4, Endian.big);
  final swap = magic == 0xcefaedfe || magic == 0xcffaedfe;
  final endian = swap ? Endian.little : Endian.big;
  final is64 = magic == 0xfeedfacf || magic == 0xcffaedfe;
  final ncmds = _uint(data, 16, 4, endian);
  var offset = is64 ? 32 : 28;
  final names = <String>[];
  for (var i = 0; i < ncmds && offset + 8 <= bytes.length; i++) {
    final cmd = _uint(data, offset, 4, endian);
    final size = _uint(data, offset + 4, 4, endian);
    if (size < 8) return const [];
    if (cmd == (is64 ? 0x19 : 0x1)) {
      names.addAll(_segmentSections(data, offset, is64, endian));
    }
    offset += size;
  }
  return names;
}

/// Returns the section names of one Mach-O segment load command.
List<String> _segmentSections(
  ByteData data,
  int offset,
  bool is64,
  Endian endian,
) {
  final header = is64 ? 72 : 56;
  final sectionSize = is64 ? 80 : 68;
  final count = _uint(data, offset + (is64 ? 64 : 48), 4, endian);
  final names = <String>[];
  for (var i = 0; i < count; i++) {
    final base = offset + header + i * sectionSize;
    if (base + 16 > data.lengthInBytes) break;
    names.add(_fixedString(data, base, 16));
  }
  return names;
}

/// Reads an unsigned integer of [size] bytes at [offset] in [endian].
int _uint(ByteData data, int offset, int size, Endian endian) {
  if (size == 8) return data.getUint64(offset, endian);
  if (size == 4) return data.getUint32(offset, endian);
  return data.getUint16(offset, endian);
}

/// Reads a NUL-terminated string from [start] up to [limit].
String _cString(Uint8List bytes, int start, int limit) {
  if (start < 0 || start >= bytes.length) return '';
  final end = limit < bytes.length ? limit : bytes.length;
  var stop = start;
  while (stop < end && bytes[stop] != 0) {
    stop++;
  }
  return String.fromCharCodes(bytes.sublist(start, stop));
}

/// Reads a fixed-width NUL-padded field at [offset].
String _fixedString(ByteData data, int offset, int length) {
  final codes = <int>[];
  for (var i = 0; i < length; i++) {
    final code = data.getUint8(offset + i);
    if (code == 0) break;
    codes.add(code);
  }
  return String.fromCharCodes(codes);
}
