/// Fat (Universal) Mach-O binaries: detection, building and thinning.
///
/// 64-bit/32-bit/Fat magic detection, the [FatSlice] shape, deterministic
/// `FAT_MAGIC` assembly, single-arch extraction, and the `LC_BUILD_VERSION`
/// platform and version parsers.

import 'dart:typed_data';

import 'macho_constants.dart';

/// Returns true if [bytes] begins with a 64-bit little-endian Mach-O header.
bool isMachO64(Uint8List bytes) {
  if (bytes.length < mhHeaderSize64) return false;
  final bd = ByteData.sublistView(bytes);
  return bd.getUint32(0, Endian.little) == mhMagic64;
}

/// Returns true if [bytes] begins with a 32-bit Mach-O magic (`MH_MAGIC` or `MH_CIGAM`).
bool isMachO32(Uint8List bytes) {
  if (bytes.length < 4) return false;
  final bd = ByteData.sublistView(bytes);
  final int magic = bd.getUint32(0, Endian.little);
  return magic == mhMagic32 || magic == mhCigam32;
}

/// Returns true if [bytes] begins with a Universal (Fat) Mach-O header
/// (`FAT_MAGIC` `0xcafebabe` or `FAT_MAGIC_64` `0xcafebabf`).
bool isFatMachO(Uint8List bytes) {
  if (bytes.length < 8) return false;
  final bd = ByteData.sublistView(bytes);
  final int magicBE = bd.getUint32(0, Endian.big);
  if (magicBE == fatMagic || magicBE == fatMagic64) {
    final int nfat = bd.getUint32(4, Endian.big);
    return nfat >= 1 && nfat <= 32;
  }
  final int magicLE = bd.getUint32(0, Endian.little);
  if (magicLE == fatMagic || magicLE == fatMagic64) {
    final int nfat = bd.getUint32(4, Endian.little);
    return nfat >= 1 && nfat <= 32;
  }
  return false;
}

/// Represents a single architecture slice inside a universal (fat) Mach-O binary.
class FatSlice {
  final int cputype;
  final int cpusubtype;
  final int align;
  final Uint8List bytes;

  new({
    required this.cputype,
    required this.cpusubtype,
    required this.bytes,
    int? align,
  }) : align = align ?? (cputype == cpuTypeArm64 ? 14 : 12);
}

/// Extracts all architecture slices from a universal (fat) Mach-O binary.
List<FatSlice> extractFatSlices(Uint8List bytes) {
  if (bytes.length < 8) {
    throw const FormatException('Not a universal (fat) Mach-O binary.');
  }
  final bd = ByteData.sublistView(bytes);
  final int magicBE = bd.getUint32(0, Endian.big);
  final int magicLE = bd.getUint32(0, Endian.little);
  late final Endian headerEndian;
  late final bool is64;
  if (magicBE == fatMagic) {
    headerEndian = Endian.big;
    is64 = false;
  } else if (magicBE == fatMagic64) {
    headerEndian = Endian.big;
    is64 = true;
  } else if (magicLE == fatMagic) {
    headerEndian = Endian.little;
    is64 = false;
  } else if (magicLE == fatMagic64) {
    headerEndian = Endian.little;
    is64 = true;
  } else {
    throw const FormatException('Not a universal (fat) Mach-O binary.');
  }

  final int nfatArch = bd.getUint32(4, headerEndian);
  if (nfatArch == 0 || nfatArch > 32) {
    throw FormatException('Invalid fat Mach-O nfat_arch count: $nfatArch.');
  }
  final archEntrySize = is64 ? 32 : 20;
  final int tableEnd = 8 + nfatArch * archEntrySize;
  if (tableEnd > bytes.length) {
    throw const FormatException('Truncated fat Mach-O architecture table.');
  }

  final slices = <FatSlice>[];
  for (var i = 0; i < nfatArch; i++) {
    final int entryOff = 8 + i * archEntrySize;
    final int cputype = bd.getUint32(entryOff, headerEndian);
    final int cpusubtype = bd.getUint32(entryOff + 4, headerEndian);
    final int sliceOffset = is64
        ? bd.getUint64(entryOff + 8, headerEndian)
        : bd.getUint32(entryOff + 8, headerEndian);
    final int sliceSize = is64
        ? bd.getUint64(entryOff + 16, headerEndian)
        : bd.getUint32(entryOff + 12, headerEndian);
    final int align = is64
        ? bd.getUint32(entryOff + 24, headerEndian)
        : bd.getUint32(entryOff + 16, headerEndian);
    if (sliceOffset < tableEnd ||
        sliceSize == 0 ||
        sliceOffset + sliceSize > bytes.length) {
      throw FormatException(
        'Fat Mach-O slice $i (offset $sliceOffset, size $sliceSize) is out of '
        'bounds (file length ${bytes.length}).',
      );
    }
    slices.add(
      FatSlice(
        cputype: cputype,
        cpusubtype: cpusubtype,
        align: align,
        bytes: Uint8List.fromList(
          bytes.sublist(sliceOffset, sliceOffset + sliceSize),
        ),
      ),
    );
  }
  return slices;
}

/// Builds a universal (fat) Mach-O binary from [slices].
Uint8List buildFatMachO(List<FatSlice> slices, {bool fat64 = false}) {
  if (slices.isEmpty) {
    throw ArgumentError.value(
      slices,
      'slices',
      'Must contain at least one slice.',
    );
  }
  final archEntrySize = fat64 ? 32 : 20;
  final int headerAndTableSize = 8 + slices.length * archEntrySize;
  final sliceOffsets = <int>[];
  var currentOffset = headerAndTableSize;
  for (final s in slices) {
    final int effAlign = s.align.clamp(0, 20);
    final int alignment = 1 << effAlign;
    currentOffset = (currentOffset + alignment - 1) & ~(alignment - 1);
    sliceOffsets.add(currentOffset);
    currentOffset += s.bytes.length;
  }

  final out = Uint8List(currentOffset);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, fat64 ? fatMagic64 : fatMagic, Endian.big);
  bd.setUint32(4, slices.length, Endian.big);
  for (var i = 0; i < slices.length; i++) {
    final FatSlice s = slices[i];
    final int entryOff = 8 + i * archEntrySize;
    final int off = sliceOffsets[i];
    bd.setUint32(entryOff, s.cputype, Endian.big);
    bd.setUint32(entryOff + 4, s.cpusubtype, Endian.big);
    if (fat64) {
      bd.setUint64(entryOff + 8, off, Endian.big);
      bd.setUint64(entryOff + 16, s.bytes.length, Endian.big);
      bd.setUint32(entryOff + 24, s.align, Endian.big);
      bd.setUint32(entryOff + 28, 0, Endian.big);
    } else {
      bd.setUint32(entryOff + 8, off, Endian.big);
      bd.setUint32(entryOff + 12, s.bytes.length, Endian.big);
      bd.setUint32(entryOff + 16, s.align, Endian.big);
    }
    out.setRange(off, off + s.bytes.length, s.bytes);
  }
  return out;
}

/// Returns the Mach-O CPU type for [arch] (`arm64` or `x86_64`).
int cpuTypeForArch(String arch) {
  switch (arch) {
    case 'arm64':
      return cpuTypeArm64;
    case 'x86_64':
      return cpuTypeX86_64;
    default:
      throw ArgumentError.value(arch, 'arch', 'Expected "arm64" or "x86_64".');
  }
}

/// Extracts the single 64-bit Mach-O slice matching [arch] (`arm64` or `x86_64`)
/// from a universal (fat) Mach-O binary.
Uint8List thinFatMachO(Uint8List bytes, String arch) {
  final int targetCpuType = cpuTypeForArch(arch);
  final List<FatSlice> slices = extractFatSlices(bytes);
  for (final s in slices) {
    if (s.cputype == targetCpuType) {
      if (isMachO32(s.bytes) || (s.cputype & cpuArchAbi64) == 0) {
        throw FormatException(
          'Fat Mach-O slice for "$arch" is an unsupported 32-bit Mach-O binary.',
        );
      }
      if (!isMachO64(s.bytes)) {
        throw FormatException(
          'Fat Mach-O slice for "$arch" is not a valid 64-bit Mach-O binary.',
        );
      }
      return s.bytes;
    }
  }
  final bool has32Bit = slices.any(
    (s) => isMachO32(s.bytes) || (s.cputype & cpuArchAbi64) == 0,
  );
  if (has32Bit) {
    throw FormatException(
      'Fat Mach-O binary contains unsupported 32-bit Mach-O slice(s) and no '
      '64-bit slice for architecture "$arch".',
    );
  }
  throw FormatException(
    'Fat Mach-O binary does not contain a slice for architecture "$arch".',
  );
}

/// Parses a platform name (`ios`, `iossim`, `macos`) into its Mach-O constant.
int parsePlatform(String name) {
  switch (name) {
    case 'macos':
      return platformMacos;
    case 'ios':
      return platformIos;
    case 'iossim':
      return platformIosSimulator;
    default:
      throw ArgumentError.value(
        name,
        'platform',
        'Expected "ios", "iossim", or "macos".',
      );
  }
}

/// Encodes `"major[.minor[.patch]]"` into `(major << 16) | (minor << 8) | patch`.
int parsePackedVersion(String version) {
  final List<String> parts = version.split('.');
  if (parts.isEmpty || parts.length > 3) {
    throw FormatException('Invalid version string "$version"');
  }
  final int major = int.parse(parts[0]);
  final int minor = parts.length > 1 ? int.parse(parts[1]) : 0;
  final int patch = parts.length > 2 ? int.parse(parts[2]) : 0;
  if (major < 0 ||
      major > 0xffff ||
      minor < 0 ||
      minor > 0xff ||
      patch < 0 ||
      patch > 0xff) {
    throw FormatException('Version component out of range in "$version"');
  }
  return (major << 16) | (minor << 8) | patch;
}
