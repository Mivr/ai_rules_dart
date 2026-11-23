// Unit tests for patch.dart over synthetic inputs built here.
//
// Every input is constructed byte by byte below, so the tests pin the exact
// contract: an x86-64 ELF file with the symbol and both patterns is patched
// to exact bytes; the same file without the symbol or without a pattern
// fails; Mach-O and aarch64 ELF inputs are left alone. The two fail-closed
// cases fail against the old silent program too: it returned success on
// exactly these inputs.
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'patch.dart';

const int _machineX64 = 62;
const int _machineAarch64 = 183;
const int _funcVirtAddr = 0x400000;
const int _funcSize = 200;
const int _callAt = 10;
const int _retAt = 150;

/// Writes [value] as little-endian [width] bytes at [off] in [bytes].
void _put(Uint8List bytes, int off, int value, int width) {
  final view = ByteData.sublistView(bytes);
  if (width == 2) {
    view.setUint16(off, value, Endian.little);
  } else if (width == 4) {
    view.setUint32(off, value, Endian.little);
  } else {
    view.setUint64(off, value, Endian.little);
  }
}

/// Builds a minimal ELF64 file: header, one PT_LOAD segment, one function
/// body, one DYNSYM entry, and a string table.
///
/// The function body holds the call-site pattern at [_callAt] and the
/// return-null pattern at [_retAt] when [withPattern] is set; otherwise it
/// is zeros. The string table names the patched symbol when [withSymbol] is
/// set and an unrelated name otherwise. [extraCallAt] plants a second
/// call-site pattern to test ambiguity.
Uint8List buildElf({
  required bool withSymbol,
  required bool withPattern,
  int machine = _machineX64,
  int? extraCallAt,
  List<int> magic = const [0x7f, 0x45, 0x4c, 0x46],
}) {
  final int funcOff = 64 + 56;
  final int symOff = funcOff + _funcSize;
  final String name = withSymbol ? kFindPubspecSymbol : 'other.symbol';
  final List<int> nameBytes = name.codeUnits + [0];
  final int strOff = symOff + 24;
  final int sectionOff = strOff + nameBytes.length;
  final int total = sectionOff + 3 * 64;
  final bytes = Uint8List(total);

  bytes.setRange(0, 4, magic);
  bytes[4] = 2;
  bytes[5] = 1;
  bytes[6] = 1;
  _put(bytes, 16, 3, 2);
  _put(bytes, 18, machine, 2);
  _put(bytes, 20, 1, 4);
  _put(bytes, 32, 64, 8);
  _put(bytes, 40, sectionOff, 8);
  _put(bytes, 52, 64, 2);
  _put(bytes, 54, 56, 2);
  _put(bytes, 56, 1, 2);
  _put(bytes, 58, 64, 2);
  _put(bytes, 60, 3, 2);

  _put(bytes, 64, 1, 4);
  _put(bytes, 68, 5, 4);
  _put(bytes, 72, funcOff, 8);
  _put(bytes, 80, _funcVirtAddr, 8);
  _put(bytes, 96, _funcSize, 8);
  _put(bytes, 104, _funcSize, 8);
  _put(bytes, 112, 0x1000, 8);

  if (withPattern) {
    _plantCall(bytes, funcOff + _callAt);
    _plantReturnNull(bytes, funcOff + _retAt);
  }
  if (extraCallAt != null) {
    _plantCall(bytes, funcOff + extraCallAt);
  }

  _put(bytes, symOff, 0, 4);
  bytes[symOff + 4] = 0x12;
  _put(bytes, symOff + 6, 1, 2);
  _put(bytes, symOff + 8, _funcVirtAddr, 8);
  _put(bytes, symOff + 16, _funcSize, 8);
  bytes.setRange(strOff, strOff + nameBytes.length, nameBytes);

  _put(bytes, sectionOff + 64 + 4, 11, 4);
  _put(bytes, sectionOff + 64 + 24, symOff, 8);
  _put(bytes, sectionOff + 64 + 32, 24, 8);
  _put(bytes, sectionOff + 64 + 40, 2, 4);
  _put(bytes, sectionOff + 64 + 56, 24, 8);
  _put(bytes, sectionOff + 128 + 4, 3, 4);
  _put(bytes, sectionOff + 128 + 24, strOff, 8);
  _put(bytes, sectionOff + 128 + 32, nameBytes.length, 8);
  return bytes;
}

/// Plants `call <rel> ; mov 0x45(%rbp),%r?` at [at].
void _plantCall(Uint8List bytes, int at) {
  bytes.setRange(at, at + 8, [0xe8, 0x11, 0x22, 0x33, 0x44, 0x48, 0x8b, 0x45]);
}

/// Plants the return-null epilogue at [at].
void _plantReturnNull(Uint8List bytes, int at) {
  bytes.setRange(at, at + 8, [0x49, 0x8b, 0x86, 0x34, 0x12, 0x00, 0x00, 0xe9]);
}

/// The exact bytes [patchElfBytes] must produce for the standard input.
Uint8List expectedPatched(Uint8List input) {
  final int patchAt = 64 + 56 + _callAt + 5;
  final int retNullAt = 64 + 56 + _retAt;
  final int rel = retNullAt - (patchAt + 5);
  final out = Uint8List.fromList(input);
  out[patchAt] = 0xe9;
  ByteData.sublistView(out).setInt32(patchAt + 1, rel, Endian.little);
  return out;
}

bool _equal(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// Runs [runPatch] over [input] in a scratch file, returning the exit code
/// and the file's final bytes.
({int code, Uint8List bytes}) runOverFile(Uint8List input) {
  final Directory dir = Directory.systemTemp.createTempSync('dartdev_patch');
  try {
    final path = '${dir.path}/dartdev_aot.dart.snapshot';
    File(path).writeAsBytesSync(input);
    final int code = runPatch([path]);
    return (code: code, bytes: File(path).readAsBytesSync());
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void main() {
  group('patchElfBytes', () {
    test('patches exact bytes with symbol and pattern', () {
      final Uint8List input = buildElf(withSymbol: true, withPattern: true);
      expect(_equal(patchElfBytes(input), expectedPatched(input)), isTrue);
      expect(patchElfBytes(input).length, input.length);
    });

    test('rewrites one call into a jump to the epilogue', () {
      final Uint8List input = buildElf(withSymbol: true, withPattern: true);
      final Uint8List out = patchElfBytes(input);
      const int patchAt = 64 + 56 + _callAt + 5;
      expect(out[patchAt], 0xe9);
      final int rel = ByteData.sublistView(
        out,
      ).getInt32(patchAt + 1, Endian.little);
      expect(rel, 64 + 56 + _retAt - (patchAt + 5));
    });

    test('missing symbol fails', () {
      final Uint8List input = buildElf(withSymbol: false, withPattern: true);
      expect(() => patchElfBytes(input), throwsA(isA<PatchFailure>()));
    });

    test('missing pattern fails', () {
      final Uint8List input = buildElf(withSymbol: true, withPattern: false);
      expect(() => patchElfBytes(input), throwsA(isA<PatchFailure>()));
    });

    test('ambiguous call site fails', () {
      final Uint8List input = buildElf(
        withSymbol: true,
        withPattern: true,
        extraCallAt: 40,
      );
      expect(() => patchElfBytes(input), throwsA(isA<PatchFailure>()));
    });

    test('truncated headers fail', () {
      final input = Uint8List(64);
      input.setRange(0, 4, [0x7f, 0x45, 0x4c, 0x46]);
      input[4] = 2;
      ByteData.sublistView(input).setUint16(18, _machineX64, Endian.little);
      expect(() => patchElfBytes(input), throwsA(isA<PatchFailure>()));
    });
  });

  group('skipReason', () {
    test('Mach-O stays untouched', () {
      final input = Uint8List(128);
      input.setRange(0, 4, [0xcf, 0xfa, 0xed, 0xfe]);
      expect(skipReason(input), isNotNull);
    });

    test('aarch64 ELF stays untouched even with symbol and pattern', () {
      final Uint8List input = buildElf(
        withSymbol: true,
        withPattern: true,
        machine: _machineAarch64,
      );
      expect(skipReason(input), isNotNull);
    });

    test('x86-64 ELF is patchable', () {
      final Uint8List input = buildElf(withSymbol: true, withPattern: true);
      expect(skipReason(input), isNull);
    });
  });

  group('runPatch files', () {
    test('patches a file and exits 0', () {
      final Uint8List input = buildElf(withSymbol: true, withPattern: true);
      final ({Uint8List bytes, int code}) result = runOverFile(input);
      expect(result.code, 0);
      expect(_equal(result.bytes, expectedPatched(input)), isTrue);
    });

    test('fails and keeps the file on a missing pattern', () {
      final Uint8List input = buildElf(withSymbol: true, withPattern: false);
      final ({Uint8List bytes, int code}) result = runOverFile(input);
      expect(result.code, 1);
      expect(_equal(result.bytes, input), isTrue);
    });

    test('fails and keeps the file on a missing symbol', () {
      final Uint8List input = buildElf(withSymbol: false, withPattern: true);
      final ({Uint8List bytes, int code}) result = runOverFile(input);
      expect(result.code, 1);
      expect(_equal(result.bytes, input), isTrue);
    });

    test('leaves Mach-O alone with exit 0', () {
      final input = Uint8List(128);
      input.setRange(0, 4, [0xcf, 0xfa, 0xed, 0xfe]);
      final ({Uint8List bytes, int code}) result = runOverFile(input);
      expect(result.code, 0);
      expect(_equal(result.bytes, input), isTrue);
    });

    test('missing file exits 0', () {
      final Directory dir = Directory.systemTemp.createTempSync(
        'dartdev_patch',
      );
      try {
        expect(runPatch(['${dir.path}/absent.snapshot']), 0);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('no arguments exits 2', () {
      expect(runPatch([]), 2);
    });
  });
}
