/// Fail-closed patch for `dartdev_aot.dart.snapshot`.
///
/// `dart pub`, `dart compile js|wasm`, and `dart compile exe` all run the
/// `dartdev` tool out of this AOT snapshot. Its
/// `DartNativeAssetsBuilder.findPubspec` walks the entrypoint's parent
/// directories for a `pubspec.yaml` and runs an implicit `pub get` without
/// `FLUTTER_ROOT`, which breaks hermetic Bazel actions. The patch rewrites
/// one call site to jump to the `return null` epilogue instead, so no walk
/// happens. Exactly five bytes change.
///
/// The program is byte-conservative on purpose: files that are not 64-bit
/// x86-64 ELF (the macOS Mach-O snapshots, the aarch64 ELF snapshot) are
/// left byte-identical with a message saying why. An x86-64 ELF snapshot
/// that lacks the symbol, or where either instruction pattern is missing or
/// appears more than once, is a hard error (non-zero exit), so the fetch
/// fails instead of silently shipping unpatched bytes.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Symbol whose function body carries both instruction patterns.
const String kFindPubspecSymbol = 'DartNativeAssetsBuilder.findPubspec';

/// ELF machine id for x86-64.
const int kMachineX86_64 = 62;

/// Failure carrying the fetch-facing message. Only this type is caught in
/// [runPatch]; anything else is a bug and must surface with a stack trace.
class PatchFailure implements Exception {
  /// Fetch-facing failure detail, naming what to update.
  final String message;

  const new(this.message);

  @override
  String toString() => 'dartdev patch failed: $message';
}

/// Section-header table location inside an ELF64 file.
typedef SectionTable = ({int off, int entsize, int num});

/// Program-header table location inside an ELF64 file.
typedef ProgramTable = ({int off, int entsize, int num});

/// A byte buffer plus the function body under test.
typedef MatchView = ({Uint8List bytes, int base});

/// Why [bytes] must stay untouched, or null when it is a patchable
/// x86-64 ELF64 file.
String? skipReason(Uint8List bytes) {
  if (bytes.length < 64) {
    return 'too short for an ELF header';
  }
  if (bytes[0] != 0x7f ||
      bytes[1] != 0x45 ||
      bytes[2] != 0x4c ||
      bytes[3] != 0x46) {
    return 'not an ELF file (for example a macOS Mach-O snapshot)';
  }
  if (bytes[4] != 2) {
    return 'not a 64-bit ELF file';
  }
  final int machine = ByteData.sublistView(
    bytes,
  ).getUint16(18, Endian.little);
  if (machine != kMachineX86_64) {
    return 'not an x86-64 ELF file (machine $machine, '
        'for example an aarch64 snapshot)';
  }
  return null;
}

/// Throws [PatchFailure] unless [offset]..[offset]+[size] is inside [bytes].
void checkRange(Uint8List bytes, int offset, int size, String what) {
  if (offset < 0 ||
      size < 0 ||
      offset > bytes.length ||
      size > bytes.length - offset) {
    throw PatchFailure(
      '$what is outside the file '
      '(offset $offset, size $size, file ${bytes.length} bytes); '
      'update the patch for this snapshot layout',
    );
  }
}

/// Reads the program- and section-header table locations.
({ProgramTable programs, SectionTable sections}) readTables(
  Uint8List bytes,
  ByteData view,
) {
  checkRange(bytes, 0, 64, 'ELF header');
  return (
    programs: (
      off: view.getUint64(32, Endian.little),
      entsize: view.getUint16(54, Endian.little),
      num: view.getUint16(56, Endian.little),
    ),
    sections: (
      off: view.getUint64(40, Endian.little),
      entsize: view.getUint16(58, Endian.little),
      num: view.getUint16(60, Endian.little),
    ),
  );
}

/// Maps a virtual address to a file offset through the PT_LOAD segments.
int? fileOffsetOf(
  Uint8List bytes,
  ByteData view,
  ProgramTable programs,
  int vaddr,
) {
  for (var i = 0; i < programs.num; i++) {
    final int off = programs.off + i * programs.entsize;
    checkRange(bytes, off, 56, 'program header $i');
    if (view.getUint32(off, Endian.little) != 1) {
      continue;
    }
    final int fileOff = view.getUint64(off + 8, Endian.little);
    final int virtAddr = view.getUint64(off + 16, Endian.little);
    final int fileSize = view.getUint64(off + 32, Endian.little);
    if (fileOff > bytes.length || fileSize > bytes.length) {
      throw const PatchFailure(
        'PT_LOAD segment points outside the file; '
        'update the patch for this snapshot layout',
      );
    }
    if (vaddr >= virtAddr && vaddr - virtAddr < fileSize) {
      return fileOff + (vaddr - virtAddr);
    }
  }
  return null;
}

/// Reads a NUL-terminated string starting at [start], bounded by [limit].
String readCString(Uint8List bytes, int start, int limit) {
  if (start < 0 || start >= limit) {
    throw const PatchFailure(
      'symbol name points outside the string table; '
      'update the patch for this snapshot layout',
    );
  }
  var end = start;
  while (end < limit && bytes[end] != 0) {
    end++;
  }
  if (end >= limit) {
    throw const PatchFailure(
      'symbol name is not NUL-terminated; '
      'update the patch for this snapshot layout',
    );
  }
  return String.fromCharCodes(bytes.sublist(start, end));
}

/// The address and size of [kFindPubspecSymbol], or null when no symbol
/// table entry carries that name.
({int value, int size})? findPubspecSymbol(
  Uint8List bytes,
  ByteData view,
  SectionTable sections,
) {
  for (var i = 0; i < sections.num; i++) {
    final int header = sections.off + i * sections.entsize;
    checkRange(bytes, header, 64, 'section header $i');
    final int kind = view.getUint32(header + 4, Endian.little);
    if (kind != 2 && kind != 11) {
      continue;
    }
    final int tableOff = view.getUint64(header + 24, Endian.little);
    final int tableSize = view.getUint64(header + 32, Endian.little);
    final int strIndex = view.getUint32(header + 40, Endian.little);
    if (strIndex >= sections.num) {
      throw PatchFailure(
        'symbol table $i links string table $strIndex '
        'of ${sections.num} sections; '
        'update the patch for this snapshot layout',
      );
    }
    final int strHeader = sections.off + strIndex * sections.entsize;
    checkRange(bytes, strHeader, 64, 'string table header');
    final int strOff = view.getUint64(strHeader + 24, Endian.little);
    checkRange(bytes, tableOff, tableSize, 'symbol table $i');
    for (var entry = tableOff; entry < tableOff + tableSize; entry += 24) {
      checkRange(bytes, entry, 24, 'symbol table entry');
      final int nameOff = view.getUint32(entry, Endian.little);
      if (readCString(bytes, strOff + nameOff, bytes.length) !=
          kFindPubspecSymbol) {
        continue;
      }
      return (
        value: view.getUint64(entry + 8, Endian.little),
        size: view.getUint64(entry + 16, Endian.little),
      );
    }
  }
  return null;
}

/// True when a call followed by `mov 0x45(%rbp),%r?` starts at [j].
bool isCallSite(MatchView view, int j) {
  final int at = view.base + j;
  final Uint8List bytes = view.bytes;
  return bytes[at] == 0xe8 &&
      bytes[at + 5] == 0x48 &&
      bytes[at + 6] == 0x8b &&
      bytes[at + 7] == 0x45;
}

/// True when the `return null` epilogue starts at [j].
bool isReturnNull(MatchView view, int j) {
  final int at = view.base + j;
  final Uint8List bytes = view.bytes;
  return bytes[at] == 0x49 &&
      bytes[at + 1] == 0x8b &&
      bytes[at + 2] == 0x86 &&
      bytes[at + 5] == 0x00 &&
      bytes[at + 6] == 0x00 &&
      bytes[at + 7] == 0xe9;
}

/// The single offset in [lo]..[hi] where [at] holds, or throws
/// [PatchFailure] when there are none or several.
int onlyMatch(
  MatchView view,
  int lo,
  int hi,
  bool Function(MatchView, int) at,
  String what,
) {
  var found = 0;
  var count = 0;
  for (var j = lo; j < hi; j++) {
    if (j < 0) {
      continue;
    }
    if (at(view, j)) {
      found = j;
      count++;
    }
  }
  if (count == 0) {
    throw PatchFailure(
      '$what pattern not found in $kFindPubspecSymbol; '
      'update the patch for this snapshot version',
    );
  }
  if (count > 1) {
    throw PatchFailure(
      '$what pattern is ambiguous ($count matches) '
      'in $kFindPubspecSymbol; update the patch for this snapshot version',
    );
  }
  return view.base + found;
}

/// Returns a patched copy of [bytes], which must be a patchable x86-64
/// ELF64 file (see [skipReason]). Throws [PatchFailure] when the symbol
/// or either pattern does not apply exactly once.
Uint8List patchElfBytes(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  final ({ProgramTable programs, SectionTable sections}) tables = readTables(
    bytes,
    view,
  );
  final ({int size, int value})? symbol = findPubspecSymbol(
    bytes,
    view,
    tables.sections,
  );
  if (symbol == null) {
    throw const PatchFailure(
      "symbol '$kFindPubspecSymbol' not found in x86-64 ELF snapshot; "
      'update the patch for this snapshot version',
    );
  }
  final int? fnOff = fileOffsetOf(bytes, view, tables.programs, symbol.value);
  if (fnOff == null) {
    throw const PatchFailure(
      "symbol '$kFindPubspecSymbol' maps to no PT_LOAD segment; "
      'update the patch for this snapshot version',
    );
  }
  checkRange(bytes, fnOff, symbol.size, 'findPubspec function body');
  final ({int base, Uint8List bytes}) scan = (bytes: bytes, base: fnOff);
  final int callAt = onlyMatch(
    scan,
    0,
    min(80, symbol.size - 8),
    isCallSite,
    'call-site rewrite',
  );
  final int patchAt = callAt + 5;
  final int retNullAt = onlyMatch(
    scan,
    symbol.size - 80,
    symbol.size - 12,
    isReturnNull,
    'return-null epilogue',
  );
  final int rel = retNullAt - (patchAt + 5);
  final out = Uint8List.fromList(bytes);
  out[patchAt] = 0xe9;
  ByteData.sublistView(out).setInt32(patchAt + 1, rel, Endian.little);
  return out;
}

/// Patches the snapshot file in `args[0]`. Returns the process exit code:
/// 0 when patched or correctly left alone, 1 on a patch failure, 2 on
/// misuse. Only [PatchFailure] is caught; anything else is a bug.
int runPatch(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: patch.dart <dartdev_aot.dart.snapshot>');
    return 2;
  }
  final String path = args[0];
  final file = File(path);
  if (!file.existsSync()) {
    stdout.writeln('dartdev patch: $path is absent; nothing to patch');
    return 0;
  }
  final Uint8List original = file.readAsBytesSync();
  final String? reason = skipReason(original);
  if (reason != null) {
    stdout.writeln('dartdev patch: leaving $path unchanged ($reason)');
    return 0;
  }
  late final Uint8List patched;
  try {
    patched = patchElfBytes(original);
  } on PatchFailure catch (e) {
    stderr.writeln('dartdev patch: $path: ${e.message}');
    return 1;
  }
  file.writeAsBytesSync(patched);
  stdout.writeln('dartdev patch: patched $path');
  return 0;
}

/// Runs [runPatch] and uses its return as the process exit code.
void main(List<String> args) {
  exitCode = runPatch(args);
}
