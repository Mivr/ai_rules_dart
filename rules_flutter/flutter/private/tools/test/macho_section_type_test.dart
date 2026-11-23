/// Section-type handling of the `patch --strip-symbols` rewrite
/// (RT32-flutter:01, finding F1-section-type-misread).
///
/// The strip used to read a `section_64` record's type from `reserved1` (+68)
/// instead of the low byte of `flags` (+64), and only honoured `S_ZEROFILL`.
/// These tests pin the fixed behaviour on both strip paths: a live section
/// is refused whatever `reserved1`, `reserved2` and the `flags` attribute
/// bits hold, while `S_ZEROFILL`, `S_GB_ZEROFILL` and
/// `S_THREAD_LOCAL_ZEROFILL` name no file bytes whatever their offset or
/// `reserved1` holds. Inputs are built with `macho_test_support.dart`, the
/// same builders `macho_edit_test.dart` uses.

import 'dart:typed_data';

import 'package:test/test.dart';

import '../macho_constants.dart' as macho;
import '../macho_parse.dart' as macho;
import '../macho_ranges.dart' as macho;
import 'macho_test_support.dart' as support;

typedef _Input = ({
  Uint8List bytes,
  int oldEnd,
  int stroff,
  int strsize,
  int symoff,
});
typedef _Input2 = ({
  Uint8List bytes,
  int linkeditOff,
  int stroff,
  int strsize,
  int symoff,
});

/// The shared fixture's table start: two locals plus one global at 0x400.
const _symoff = 0x400;

/// The shared fixture's table end: three 16-byte entries plus 32 string bytes.
const _tablesEnd = 0x450;

/// The in-place probe: a section over [0x300, _tablesEnd), covering the
/// rewritten tables while its segment ends where they start, so only the
/// section can be refused.
const _inPlaceOff = 0x300;

/// The `__LINKEDIT`-path probe: a section over [0x3c0, 0x420), reaching into
/// `__LINKEDIT` at 0x400 while its segment ends there.
const _linkeditProbeOff = 0x3c0;
const _linkeditProbeSize = 0x60;

/// `S_ATTR_PURE_INSTRUCTIONS`, an attribute bit above the type byte.
const _attrPureInstructions = 0x80000000;

void main() {
  group('sectionType (RT32-flutter:01 F1-section-type-misread)', () {
    _inPlaceLiveSectionTests();
    _inPlaceZerofillSectionTests();
    _linkeditLiveSectionTests();
    _linkeditZerofillSectionTests();
    _sectionLayoutTests();
  });
}

/// The one surviving global after a successful strip.
void _expectOneGlobal(Uint8List bytes) {
  final macho.LoadCommand symtab = macho
      .parseLoadCommands(bytes)
      .singleWhere((c) => c.cmd == macho.lcSymtab);
  expect(ByteData.sublistView(symtab.bytes).getUint32(12, Endian.little), 1);
}

void _inPlaceLiveSectionTests() {
  test('live section with reserved1=1 over the tables is refused', () {
    final _Input input = support.buildSectionDylib(
      textSegEnd: _symoff,
      textSection: (
        sectname: '__text',
        segname: '__TEXT',
        offset: _inPlaceOff,
        size: _tablesEnd - _inPlaceOff,
        flags: 0,
        reserved1: 1,
        reserved2: 0,
      ),
    );
    support.expectStripRefusal(
      input.bytes,
      allOf(
        contains('section __text of segment __TEXT'),
        contains('$_inPlaceOff'),
        contains('__LINKEDIT'),
      ),
    );
  });

  test('live section with another nonzero reserved1 is refused', () {
    final _Input input = support.buildSectionDylib(
      textSegEnd: _symoff,
      textSection: (
        sectname: '__text',
        segname: '__TEXT',
        offset: _inPlaceOff,
        size: _tablesEnd - _inPlaceOff,
        flags: 0,
        reserved1: 0x1000001,
        reserved2: 0x12345678,
      ),
    );
    support.expectStripRefusal(
      input.bytes,
      allOf(
        contains('section __text of segment __TEXT'),
        contains('$_inPlaceOff'),
        contains('__LINKEDIT'),
      ),
    );
  });

  test('live section with reserved1=7 and reserved2 set is refused', () {
    final _Input input = support.buildSectionDylib(
      textSegEnd: _symoff,
      textSection: (
        sectname: '__text',
        segname: '__TEXT',
        offset: _inPlaceOff,
        size: _tablesEnd - _inPlaceOff,
        flags: 0,
        reserved1: 7,
        reserved2: 0xdeadbeef,
      ),
    );
    support.expectStripRefusal(
      input.bytes,
      allOf(
        contains('section __text of segment __TEXT'),
        contains('$_inPlaceOff'),
        contains('__LINKEDIT'),
      ),
    );
  });

  test('live section with attribute bits in flags is still live', () {
    final _Input input = support.buildSectionDylib(
      textSegEnd: _symoff,
      textSection: (
        sectname: '__text',
        segname: '__TEXT',
        offset: _inPlaceOff,
        size: _tablesEnd - _inPlaceOff,
        flags: _attrPureInstructions,
        reserved1: 1,
        reserved2: 0,
      ),
    );
    support.expectStripRefusal(
      input.bytes,
      allOf(
        contains('section __text of segment __TEXT'),
        contains('$_inPlaceOff'),
        contains('__LINKEDIT'),
      ),
    );
  });
}

void _inPlaceZerofillSectionTests() {
  for (final type in <int>[
    macho.sectionTypeZerofill,
    macho.sectionTypeGbZerofill,
    macho.sectionTypeThreadLocalZerofill,
  ]) {
    test(
      'zero-fill 0x${type.toRadixString(16)} with a nonzero offset strips '
      'over the tables',
      () {
        final _Input input = support.buildSectionDylib(
          textSegEnd: _symoff,
          textSection: (
            sectname: '__bss',
            segname: '__DATA',
            offset: _inPlaceOff,
            size: _tablesEnd - _inPlaceOff,
            flags: type,
            reserved1: 0,
            reserved2: 0,
          ),
        );
        final Uint8List stripped = support.stripTestDylib(input.bytes);
        expect(stripped.length, input.bytes.length);
        _expectOneGlobal(stripped);
      },
    );
  }

  test('zero-fill with attribute bits still names no bytes', () {
    final _Input input = support.buildSectionDylib(
      textSegEnd: _symoff,
      textSection: (
        sectname: '__bss',
        segname: '__DATA',
        offset: _inPlaceOff,
        size: _tablesEnd - _inPlaceOff,
        flags: _attrPureInstructions | macho.sectionTypeZerofill,
        reserved1: 0,
        reserved2: 0,
      ),
    );
    final Uint8List stripped = support.stripTestDylib(input.bytes);
    expect(stripped.length, input.bytes.length);
    _expectOneGlobal(stripped);
  });
}

void _linkeditLiveSectionTests() {
  test('live section with reserved1=1 reaching into __LINKEDIT is refused', () {
    final _Input2 input = support.buildLinkeditSectionDylib(
      textSegEnd: _symoff,
      textSection: (
        sectname: '__text',
        segname: '__TEXT',
        offset: _linkeditProbeOff,
        size: _linkeditProbeSize,
        flags: 0,
        reserved1: 1,
        reserved2: 0,
      ),
      linkeditOff: _symoff,
    );
    support.expectStripRefusal(
      input.bytes,
      allOf(contains('__TEXT'), contains('__LINKEDIT')),
    );
  });

  test('live section with another nonzero reserved1 is refused', () {
    final _Input2 input = support.buildLinkeditSectionDylib(
      textSegEnd: _symoff,
      textSection: (
        sectname: '__text',
        segname: '__TEXT',
        offset: _linkeditProbeOff,
        size: _linkeditProbeSize,
        flags: 0,
        reserved1: 0x1000001,
        reserved2: 0x12345678,
      ),
      linkeditOff: _symoff,
    );
    support.expectStripRefusal(
      input.bytes,
      allOf(contains('__TEXT'), contains('__LINKEDIT')),
    );
  });

  test('live section with reserved1=7 and reserved2 set is refused', () {
    final _Input2 input = support.buildLinkeditSectionDylib(
      textSegEnd: _symoff,
      textSection: (
        sectname: '__text',
        segname: '__TEXT',
        offset: _linkeditProbeOff,
        size: _linkeditProbeSize,
        flags: 0,
        reserved1: 7,
        reserved2: 0xdeadbeef,
      ),
      linkeditOff: _symoff,
    );
    support.expectStripRefusal(
      input.bytes,
      allOf(contains('__TEXT'), contains('__LINKEDIT')),
    );
  });

  test('live section with attribute bits in flags is still live', () {
    final _Input2 input = support.buildLinkeditSectionDylib(
      textSegEnd: _symoff,
      textSection: (
        sectname: '__text',
        segname: '__TEXT',
        offset: _linkeditProbeOff,
        size: _linkeditProbeSize,
        flags: _attrPureInstructions,
        reserved1: 1,
        reserved2: 0,
      ),
      linkeditOff: _symoff,
    );
    support.expectStripRefusal(
      input.bytes,
      allOf(contains('__TEXT'), contains('__LINKEDIT')),
    );
  });
}

void _linkeditZerofillSectionTests() {
  for (final type in <int>[
    macho.sectionTypeZerofill,
    macho.sectionTypeGbZerofill,
    macho.sectionTypeThreadLocalZerofill,
  ]) {
    test(
      'zero-fill 0x${type.toRadixString(16)} with a nonzero offset strips '
      'over __LINKEDIT',
      () {
        final _Input2 input = support.buildLinkeditSectionDylib(
          textSegEnd: _symoff,
          textSection: (
            sectname: '__bss',
            segname: '__DATA',
            offset: _linkeditProbeOff,
            size: _linkeditProbeSize,
            flags: type,
            reserved1: 0,
            reserved2: 0,
          ),
          linkeditOff: _symoff,
        );
        final Uint8List stripped = support.stripTestDylib(input.bytes);
        expect(stripped.length, lessThan(input.bytes.length));
        _expectOneGlobal(stripped);
      },
    );
  }

  test('zero-fill with attribute bits still names no bytes', () {
    final _Input2 input = support.buildLinkeditSectionDylib(
      textSegEnd: _symoff,
      textSection: (
        sectname: '__bss',
        segname: '__DATA',
        offset: _linkeditProbeOff,
        size: _linkeditProbeSize,
        flags: _attrPureInstructions | macho.sectionTypeGbZerofill,
        reserved1: 0,
        reserved2: 0,
      ),
      linkeditOff: _symoff,
    );
    final Uint8List stripped = support.stripTestDylib(input.bytes);
    expect(stripped.length, lessThan(input.bytes.length));
    _expectOneGlobal(stripped);
  });
}

void _sectionLayoutTests() {
  test('sectionLayoutsOf reads the type from flags, not reserved1', () {
    final command = macho.LoadCommand(
      macho.lcSegment64,
      support.segmentWithSections('__TEXT', 0, _symoff, [
        support.sectionRecord((
          sectname: '__bss',
          segname: '__DATA',
          offset: _inPlaceOff,
          size: 0x100,
          flags: macho.sectionTypeGbZerofill,
          reserved1: 1,
          reserved2: 0,
        )),
      ]),
    );
    final List<macho.SectionLayout> sections = macho.sectionLayoutsOf(command);
    expect(sections, hasLength(1));
    expect(sections.single.type, macho.sectionTypeGbZerofill);
  });

  test(
    'accountedRangesOf keeps live sections with nonzero reserved1 and '
    'skips every zero-fill type',
    () {
      final command = macho.LoadCommand(
        macho.lcSegment64,
        support.segmentWithSections('__TEXT', 0, _symoff, [
          support.sectionRecord((
            sectname: '__text',
            segname: '__TEXT',
            offset: _inPlaceOff,
            size: 0x100,
            flags: 0,
            reserved1: 1,
            reserved2: 0,
          )),
          support.sectionRecord((
            sectname: '__bss1',
            segname: '__DATA',
            offset: _inPlaceOff,
            size: 0x100,
            flags: macho.sectionTypeZerofill,
            reserved1: 0,
            reserved2: 0,
          )),
          support.sectionRecord((
            sectname: '__bss2',
            segname: '__DATA',
            offset: _inPlaceOff,
            size: 0x100,
            flags: macho.sectionTypeGbZerofill,
            reserved1: 0,
            reserved2: 0,
          )),
          support.sectionRecord((
            sectname: '__bss3',
            segname: '__DATA',
            offset: _inPlaceOff,
            size: 0x100,
            flags: macho.sectionTypeThreadLocalZerofill,
            reserved1: 0,
            reserved2: 0,
          )),
        ]),
      );
      final List<macho.CommandRange> ranges = macho.accountedRangesOf(command);
      expect(
        ranges.map((r) => (r.offset, r.size)).toList(),
        equals([
          (0, _symoff),
          (_inPlaceOff, 0x100),
        ]),
      );
    },
  );
}
