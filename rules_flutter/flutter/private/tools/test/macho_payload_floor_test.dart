/// Payload-floor handling of the `patch` growth path (RT33-flutter observation).
///
/// `macho_edit patch` may grow the load commands up to the first file byte any
/// segment, section or linkedit table names. Two defects pinned here: a
/// zero-fill section's `offset` field used to lower that floor even though the
/// section names no file bytes, and an overgrown patch died with a bare
/// `StateError` naming no file, payload or slice. These tests build their
/// inputs with `macho_test_support.dart`, the same builders
/// `macho_edit_test.dart` uses.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../macho_constants.dart' as macho;
import '../macho_fat.dart' as macho;
import '../macho_parse.dart' as macho;
import '../macho_patch.dart' as macho;
import 'macho_test_support.dart' as support;

typedef _Input = ({Uint8List bytes, int probe, Uint8List zeroBytes});

/// The rpath every growth probe adds.
const _probeRpath = '@executable_path/Frameworks';

/// The bytes one probe rpath adds: 12 header plus string plus NUL, 8-aligned.
final _probeGrowth = (_probeRpath.length + 12 + 1 + 7) & ~7;

/// Growth options adding one `LC_RPATH` to the load commands.
macho.PatchOptions _growthOptions() =>
    macho.PatchOptions(rpaths: [_probeRpath]);

/// The file offset where [bytes]' load commands end (header plus `cmdsize`s).
int _commandsEnd(Uint8List bytes) {
  int end = macho.mhHeaderSize64;
  for (final macho.LoadCommand c in macho.parseLoadCommands(bytes)) {
    end += c.cmdsize;
  }
  return end;
}

/// Builds the probe dylib: the shared section fixture whose text section sits
/// just past the current command end, inside the room one added rpath needs.
/// Returns the placed bytes, the same bytes with the section offset field set
/// to 0, and the placed offset.
({Uint8List bytes, Uint8List zeroBytes, int probe}) _buildRoomProbe({
  required String sectname,
  required String segname,
  required int size,
  required int flags,
  int reserved1 = 0,
  int reserved2 = 0,
}) {
  ({
    String sectname,
    String segname,
    int offset,
    int size,
    int flags,
    int reserved1,
    int reserved2,
  })
  at(int offset) => (
    sectname: sectname,
    segname: segname,
    offset: offset,
    size: size,
    flags: flags,
    reserved1: reserved1,
    reserved2: reserved2,
  );
  final ({Uint8List bytes, int oldEnd, int stroff, int strsize, int symoff})
  zero = support.buildSectionDylib(
    textSegEnd: 0x300,
    textSection: at(0),
  );
  final int probe = _commandsEnd(zero.bytes) + 16;
  final ({Uint8List bytes, int oldEnd, int stroff, int strsize, int symoff})
  placed = support.buildSectionDylib(
    textSegEnd: 0x300,
    textSection: at(probe),
  );
  return (bytes: placed.bytes, zeroBytes: zero.bytes, probe: probe);
}

/// Copies [patched] with its first section's `offset` word zeroed, so a patch
/// that ignored the zero-fill offset compares equal to the zero-offset patch.
Uint8List _withSectionOffsetZeroed(Uint8List patched) {
  int at = macho.mhHeaderSize64;
  for (final macho.LoadCommand c in macho.parseLoadCommands(patched)) {
    if (c.cmd == macho.lcSegment64 && c.bytes.length >= 72 + 80) {
      final int nsects = ByteData.sublistView(c.bytes)
          .getUint32(64, Endian.little);
      if (nsects >= 1) {
        final out = Uint8List.fromList(patched);
        ByteData.sublistView(out).setUint32(at + 72 + 48, 0, Endian.little);
        return out;
      }
    }
    at += c.cmdsize;
  }
  fail('patched probe fixture has no section to normalize');
}

/// Expects patching [input] with the growth options to succeed and to match
/// the zero-offset patch once the ignored offset field is normalized away.
void _expectRoomPatch(
  ({Uint8List bytes, Uint8List zeroBytes, int probe}) input,
) {
  final Uint8List patched = macho.patchMachO(input.bytes, _growthOptions());
  final Uint8List patchedZero = macho.patchMachO(
    input.zeroBytes,
    _growthOptions(),
  );
  expect(_withSectionOffsetZeroed(patched), equals(patchedZero));
}

void main() {
  group('payload floor (RT33-flutter observation)', () {
    for (final type in <int>[
      macho.sectionTypeZerofill,
      macho.sectionTypeGbZerofill,
      macho.sectionTypeThreadLocalZerofill,
    ]) {
      test(
        'zero-fill 0x${type.toRadixString(16)} offset inside the growth room '
        'still patches',
        () {
          _expectRoomPatch(
            _buildRoomProbe(
              sectname: '__bss',
              segname: '__DATA',
              size: 0x100,
              flags: type,
            ),
          );
        },
      );
    }

    test('zero-fill with attribute bits and reserved words still patches', () {
      _expectRoomPatch(
        _buildRoomProbe(
          sectname: '__bss',
          segname: '__DATA',
          size: 0x100,
          flags: 0x80000000 | macho.sectionTypeZerofill,
          reserved1: 3,
          reserved2: 0xdeadbeef,
        ),
      );
    });

    test('live section in the growth room is refused naming the section', () {
      final _Input input = _buildRoomProbe(
        sectname: '__text',
        segname: '__TEXT',
        size: 0x100,
        flags: 0,
        reserved1: 1,
        reserved2: 0x1234,
      );
      final Directory dir = Directory.systemTemp.createTempSync('macho_floor_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final inPath = '${dir.path}/in.dylib';
      final outPath = '${dir.path}/out.dylib';
      File(inPath).writeAsBytesSync(input.bytes);
      final int newEnd = _commandsEnd(input.bytes) + _probeGrowth;
      expect(
        () => macho.runPatch([
          '--input',
          inPath,
          '--output',
          outPath,
          '--rpath',
          _probeRpath,
        ]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Input file'),
              contains(inPath),
              contains('__text'),
              contains('__TEXT'),
              contains('$newEnd'),
              contains('${input.probe}'),
            ),
          ),
        ),
      );
    });

    test('fat slice without room names the slice', () {
      final _Input roomy = _buildRoomProbe(
        sectname: '__bss',
        segname: '__DATA',
        size: 0x100,
        flags: macho.sectionTypeZerofill,
      );
      final _Input tight = _buildRoomProbe(
        sectname: '__text',
        segname: '__TEXT',
        size: 0x100,
        flags: 0,
      );
      final x86 = Uint8List.fromList(roomy.zeroBytes);
      ByteData.sublistView(x86).setUint32(
        4,
        macho.cpuTypeX86_64,
        Endian.little,
      );
      final Uint8List fat = macho.buildFatMachO([
        macho.FatSlice(
          cputype: macho.cpuTypeX86_64,
          cpusubtype: macho.cpuSubtypeX86_64All,
          bytes: x86,
        ),
        macho.FatSlice(
          cputype: macho.cpuTypeArm64,
          cpusubtype: macho.cpuSubtypeArm64All,
          bytes: tight.bytes,
        ),
      ]);
      final int newEnd = _commandsEnd(tight.bytes) + _probeGrowth;
      expect(
        () => macho.patchMachO(fat, _growthOptions()),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('slice 1'),
              contains('arm64'),
              contains('__text'),
              contains('__TEXT'),
              contains('$newEnd'),
              contains('${tight.probe}'),
            ),
          ),
        ),
      );
    });
  });
}
