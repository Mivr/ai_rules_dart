/// A small, dependency-free Mach-O reader for the add-to-app e2e test.
///
/// The test only needs the header CPU and the `LC_BUILD_VERSION` platform of
/// each architecture slice, so this reader stays intentionally narrow. It
/// accepts a thin 64-bit Mach-O or a universal (fat) container and returns one
/// [MachOSliceInfo] per architecture.
library;

import 'dart:typed_data';

/// `cputype` of 64-bit arm64.
const int machoCpuArm64 = 0x0100000c;

/// `cputype` of x86_64.
const int machoCpuX8664 = 0x01000007;

/// `LC_BUILD_VERSION` platform number for iOS.
const int machoPlatformIos = 2;

/// `LC_BUILD_VERSION` platform number for the iOS simulator.
const int machoPlatformIosSimulator = 7;

const int _magic64 = 0xfeedfacf;
const int _fatMagic = 0xcafebabe;
const int _fatMagic64 = 0xcafebabf;
const int _lcBuildVersion = 0x32;

/// The parts of one Mach-O slice the e2e test asserts on.
class MachOSliceInfo {
  /// Creates one slice record.
  const new({
    required this.cpuType,
    required this.platform,
    required this.is64Bit,
  });

  /// The header `cputype` (`machoCpuArm64` or `machoCpuX8664` expected).
  final int cpuType;

  /// The `LC_BUILD_VERSION` platform, or null when the command is absent.
  final int? platform;

  /// Whether the slice uses the 64-bit Mach-O header.
  final bool is64Bit;
}

/// Reads every slice in [bytes], which must be a thin or universal Mach-O.
///
/// Throws [FormatException] naming [path] and the offset when the bytes are
/// not a supported Mach-O, so a malformed binary fails the test rather than
/// passing it vacuously.
List<MachOSliceInfo> readMachOSlices(Uint8List bytes, String path) {
  if (bytes.length < 8) {
    throw FormatException('$path is shorter than a Mach-O header');
  }
  final data = ByteData.sublistView(bytes);
  final int magic = data.getUint32(0);
  if (magic == _fatMagic || magic == _fatMagic64) {
    return _readFat(data, path, wide: magic == _fatMagic64);
  }
  return [_readThin(data, 0, bytes.length, path)];
}

/// Reads the architecture table of a universal container.
List<MachOSliceInfo> _readFat(
  ByteData data,
  String path, {
  required bool wide,
}) {
  final int count = data.getUint32(4);
  if (count == 0 || count > 32) {
    throw FormatException('$path has an invalid fat slice count $count');
  }
  final entrySize = wide ? 32 : 20;
  final int tableEnd = 8 + count * entrySize;
  if (tableEnd > data.lengthInBytes) {
    throw FormatException('$path has a truncated fat architecture table');
  }
  final slices = <MachOSliceInfo>[];
  for (var i = 0; i < count; i++) {
    final int entry = 8 + i * entrySize;
    final int offset = wide
        ? data.getUint64(entry + 8)
        : data.getUint32(entry + 8);
    final int size = wide
        ? data.getUint64(entry + 16)
        : data.getUint32(entry + 12);
    if (offset + size > data.lengthInBytes) {
      throw FormatException(
        '$path fat slice $i runs past the file '
        '(offset $offset, size $size of ${data.lengthInBytes} bytes)',
      );
    }
    slices.add(_readThin(data, offset, size, path));
  }
  return slices;
}

/// Reads the header and `LC_BUILD_VERSION` of one thin 64-bit Mach-O.
MachOSliceInfo _readThin(ByteData data, int start, int size, String path) {
  if (size < 32) {
    throw FormatException('$path has a truncated Mach-O at $start');
  }
  final int magic = data.getUint32(start, Endian.little);
  if (magic != _magic64) {
    throw FormatException(
      '$path at $start is not a 64-bit Mach-O '
      '(magic 0x${magic.toRadixString(16)})',
    );
  }
  final int cpuType = data.getUint32(start + 4, Endian.little);
  final int commandCount = data.getUint32(start + 16, Endian.little);
  int offset = start + 32;
  int? platform;
  for (var i = 0; i < commandCount; i++) {
    if (offset + 8 > start + size) {
      throw FormatException('$path load command $i runs past the slice');
    }
    final int command = data.getUint32(offset, Endian.little);
    final int commandSize = data.getUint32(offset + 4, Endian.little);
    if (commandSize < 8 || offset + commandSize > start + size) {
      throw FormatException(
        '$path load command $i has invalid cmdsize $commandSize at $offset',
      );
    }
    if (command == _lcBuildVersion) {
      platform ??= data.getUint32(offset + 8, Endian.little);
    }
    offset += commandSize;
  }
  return MachOSliceInfo(
    cpuType: cpuType,
    platform: platform,
    is64Bit: true,
  );
}
