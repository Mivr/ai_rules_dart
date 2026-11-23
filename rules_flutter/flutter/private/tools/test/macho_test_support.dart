/// Shared builders for the Mach-O `patch --strip-symbols` section tests.
///
/// The section-overlap tests in `macho_edit_test.dart` and
/// `macho_section_type_test.dart` build their inputs the same way: a small
/// unsigned arm64 dylib with a two-local-plus-one-global symbol table and
/// segments carrying explicit `section_64` records. The builders live here so
/// both test files share them instead of copying them.

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../macho_constants.dart' as constants;
import '../macho_parse.dart' as parse;
import '../macho_patch.dart' as patch;

/// One `section_64` record's test description: its names, the file range it
/// names, and the `flags`/`reserved` words. `flags` carries the section type
/// in its low byte with attribute bits above it; `reserved1` carries stub and
/// pointer sections' indirect-symbol index, never the type.
typedef SectionSpec = ({
  String sectname,
  String segname,
  int offset,
  int size,
  int flags,
  int reserved1,
  int reserved2,
});

/// A live (`S_REGULAR`) [SectionSpec] for [sectname] in [segname] naming the
/// file range [offset]/[size].
SectionSpec regularSection(
  String sectname,
  String segname,
  int offset,
  int size,
) {
  return (
    sectname: sectname,
    segname: segname,
    offset: offset,
    size: size,
    flags: 0,
    reserved1: 0,
    reserved2: 0,
  );
}

/// An 80-byte `section_64` record for [spec].
Uint8List sectionRecord(SectionSpec spec) {
  final buf = Uint8List(80);
  final bd = ByteData.sublistView(buf);
  final Uint8List sectBytes = ascii.encode(spec.sectname);
  buf.setRange(0, sectBytes.length, sectBytes);
  final Uint8List segBytes = ascii.encode(spec.segname);
  buf.setRange(16, 16 + segBytes.length, segBytes);
  bd.setUint64(32, 0x1000, Endian.little);
  bd.setUint64(40, spec.size, Endian.little);
  bd.setUint32(48, spec.offset, Endian.little);
  bd.setUint32(52, 2, Endian.little);
  bd.setUint32(64, spec.flags, Endian.little);
  bd.setUint32(68, spec.reserved1, Endian.little);
  bd.setUint32(72, spec.reserved2, Endian.little);
  return buf;
}

/// An `LC_SEGMENT_64` command for [segname] covering [fileoff]/[filesize]
/// with [sections] appended, `cmdsize` fixed up for the records.
Uint8List segmentWithSections(
  String segname,
  int fileoff,
  int filesize,
  List<Uint8List> sections,
) {
  final Uint8List header = parse.buildLcSegment64((
    segname: segname,
    vmaddr: 0,
    vmsize: filesize,
    fileoff: fileoff,
    filesize: filesize,
    maxprot: 5,
    initprot: 5,
    nsects: sections.length,
    flags: 0,
  )).bytes;
  final out = BytesBuilder(copy: false)..add(header);
  for (final section in sections) {
    out.add(section);
  }
  final Uint8List bytes = out.toBytes();
  ByteData.sublistView(bytes).setUint32(4, bytes.length, Endian.little);
  return bytes;
}

/// The shared symbol-table fixture: two locals plus one kept global, with the
/// string table holding just their names.
({Uint8List symtab, Uint8List strings}) buildSectionSymtab() {
  const names = ['_local_a', '_local_b', '_kept_global'];
  const types = [0x0e, 0x0e, 0x0f];
  final strings = BytesBuilder(copy: false)..addByte(0);
  final strx = <int>[];
  for (final name in names) {
    strx.add(strings.length);
    strings.add(utf8.encode(name));
    strings.addByte(0);
  }
  final Uint8List strBytes = strings.toBytes();
  final symBytes = BytesBuilder(copy: false);
  for (var i = 0; i < names.length; i++) {
    final entry = ByteData(16)
      ..setUint32(0, strx[i], Endian.little)
      ..setUint8(4, types[i])
      ..setUint8(5, 1)
      ..setUint16(6, 0, Endian.little)
      ..setUint64(8, 0x1000 + i * 8, Endian.little);
    symBytes.add(entry.buffer.asUint8List());
  }
  final Uint8List symTab = symBytes.toBytes();
  expect(symTab.length, 3 * 16);
  expect(strBytes.length, 1 + 9 + 9 + 13);
  return (symtab: symTab, strings: strBytes);
}

/// Assembles [commands] into a minimal 64-bit Mach-O header claiming a
/// [fileSize]-byte file: the header plus the commands laid out from byte 32.
Uint8List assembleTestMachO(List<Uint8List> commands, int fileSize) {
  var sizeofcmds = 0;
  for (final c in commands) {
    sizeofcmds += c.length;
  }
  final buf = Uint8List(fileSize);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, constants.mhMagic64, Endian.little);
  bd.setUint32(4, constants.cpuTypeArm64, Endian.little);
  bd.setUint32(8, constants.cpuSubtypeArm64All, Endian.little);
  bd.setUint32(12, constants.mhDylib, Endian.little);
  bd.setUint32(16, commands.length, Endian.little);
  bd.setUint32(20, sizeofcmds, Endian.little);
  bd.setUint32(24, constants.mhNoReexportedDylibs, Endian.little);
  int off = constants.mhHeaderSize64;
  for (final c in commands) {
    buf.setRange(off, off + c.length, c);
    off += c.length;
  }
  return buf;
}

/// Builds a small unsigned arm64 dylib with no `__LINKEDIT` segment: the
/// shared two-local-plus-one-global table at 0x400, an empty `LC_DYSYMTAB`, a
/// `__TEXT` segment covering [0, textSegEnd) with [textSection], and, when
/// [dataSegEnd] is nonzero, a `__DATA` segment covering
/// [dataSegOff, dataSegEnd) carrying [dataSection] unless it is null, which
/// builds the segment with no sections. The file spans the tables and both
/// segments.
({Uint8List bytes, int symoff, int stroff, int strsize, int oldEnd})
buildSectionDylib({
  required int textSegEnd,
  required SectionSpec textSection,
  int dataSegOff = 0,
  int dataSegEnd = 0,
  SectionSpec? dataSection,
}) {
  const symoff = 0x400;
  final ({Uint8List strings, Uint8List symtab}) fixture = buildSectionSymtab();
  final Uint8List symTab = fixture.symtab;
  final Uint8List strBytes = fixture.strings;
  final int stroff = symoff + symTab.length;
  final int oldEnd = stroff + strBytes.length;

  final commands = <Uint8List>[
    segmentWithSections('__TEXT', 0, textSegEnd, [
      sectionRecord(textSection),
    ]),
    parse
        .buildLcSymtab(
          symoff: symoff,
          nsyms: symTab.length ~/ 16,
          stroff: stroff,
          strsize: strBytes.length,
        )
        .bytes,
    parse.buildLcDysymtab().bytes,
    parse.buildLcIdDylib('@rpath/Section.dylib').bytes,
    if (dataSegEnd != 0)
      segmentWithSections('__DATA', dataSegOff, dataSegEnd - dataSegOff, [
        if (dataSection != null) sectionRecord(dataSection),
      ]),
    parse
        .buildLcBuildVersion(
          platform: 2,
          minos: 0x000e0000,
          sdk: 0x00110000,
        )
        .bytes,
  ];
  var fileSize = oldEnd;
  for (final end in [textSegEnd, dataSegEnd]) {
    if (end > fileSize) fileSize = end;
  }
  final Uint8List buf = assembleTestMachO(commands, fileSize);
  buf.setRange(symoff, symoff + symTab.length, symTab);
  buf.setRange(stroff, stroff + strBytes.length, strBytes);
  return (
    bytes: buf,
    symoff: symoff,
    stroff: stroff,
    strsize: strBytes.length,
    oldEnd: oldEnd,
  );
}

/// Builds a small unsigned arm64 dylib with a `__LINKEDIT` segment: the
/// shared table at [linkeditOff], an empty `LC_DYSYMTAB`, a `__TEXT` segment
/// covering [0, textSegEnd) with [textSection], and `__LINKEDIT` covering
/// [linkeditOff] to the end of the file. The file spans the tables, the
/// segment, and [textSection]'s named range.
({Uint8List bytes, int linkeditOff, int symoff, int stroff, int strsize})
buildLinkeditSectionDylib({
  required int textSegEnd,
  required SectionSpec textSection,
  required int linkeditOff,
}) {
  final ({Uint8List strings, Uint8List symtab}) fixture = buildSectionSymtab();
  final Uint8List symTab = fixture.symtab;
  final Uint8List strBytes = fixture.strings;
  final symoff = linkeditOff;
  final int stroff = symoff + symTab.length;
  final int tablesEnd = stroff + strBytes.length;
  var fileSize = tablesEnd;
  for (final int end in [textSegEnd, textSection.offset + textSection.size]) {
    if (end > fileSize) fileSize = end;
  }
  final int linkeditSize = fileSize - linkeditOff;

  final commands = <Uint8List>[
    segmentWithSections('__TEXT', 0, textSegEnd, [
      sectionRecord(textSection),
    ]),
    parse.buildLcSegment64((
      segname: '__LINKEDIT',
      vmaddr: 0x4000,
      vmsize: linkeditSize,
      fileoff: linkeditOff,
      filesize: linkeditSize,
      maxprot: 1,
      initprot: 1,
      nsects: 0,
      flags: 0,
    )).bytes,
    parse
        .buildLcSymtab(
          symoff: symoff,
          nsyms: symTab.length ~/ 16,
          stroff: stroff,
          strsize: strBytes.length,
        )
        .bytes,
    parse.buildLcDysymtab().bytes,
    parse.buildLcIdDylib('@rpath/Section.dylib').bytes,
    parse
        .buildLcBuildVersion(
          platform: 2,
          minos: 0x000e0000,
          sdk: 0x00110000,
        )
        .bytes,
  ];
  final Uint8List buf = assembleTestMachO(commands, fileSize);
  buf.setRange(symoff, symoff + symTab.length, symTab);
  buf.setRange(stroff, stroff + strBytes.length, strBytes);
  return (
    bytes: buf,
    linkeditOff: linkeditOff,
    symoff: symoff,
    stroff: stroff,
    strsize: strBytes.length,
  );
}

/// Strips [bytes]' local symbols the way the release strip does.
Uint8List stripTestDylib(Uint8List bytes) {
  return patch.patchMachO(bytes, patch.PatchOptions(stripSymbols: true));
}

/// Expects stripping [bytes] to be refused with a message matching [message].
void expectStripRefusal(Uint8List bytes, Matcher message) {
  expect(
    () => patch.patchMachO(bytes, patch.PatchOptions(stripSymbols: true)),
    throwsA(
      isA<FormatException>().having((e) => e.message, 'message', message),
    ),
  );
}
