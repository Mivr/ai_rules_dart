/// Shared readers for the iOS example's bundle verification tests.
///
/// The Mach-O header and load commands, the engine's VM features string and
/// the runfiles bookkeeping are read here once, so the release-framework and
/// unsigned-device tests inspect a binary the same way. Every failure names
/// what was expected and what was found; a missing input fails, never skips.
library;

// This library's diagnostics are its product: it reports what it found in a
// built artifact to the bazel test log, so `print` is its output channel
// rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Mach-O magic of a little-endian 64-bit binary.
const machOMagic64 = 0xfeedfacf;

/// Mach-O `cputype` of arm64.
const machOArm64CpuType = 0x0100000c;

/// `LC_BUILD_VERSION` load command number.
const machOLcBuildVersion = 0x32;

/// `LC_SYMTAB` load command number.
const machOLcSymtab = 0x2;

/// `LC_DYSYMTAB` load command number.
const machOLcDysymtab = 0xb;

/// `LC_DYLD_INFO_ONLY` load command number.
const machOLcDyldInfoOnly = 0x80000022;

/// `LC_DYLD_EXPORTS_TRIE` load command number.
const machOLcDyldExportsTrie = 0x80000033;

/// `LC_CODE_SIGNATURE` load command number.
const machOLcCodeSignature = 0x1d;

/// `LC_BUILD_VERSION` platform number of iOS (7 would be the simulator).
const machOPlatformIos = 2;

/// Stops the test with [message]: a missing input fails, never skips.
Never abort(String message) {
  stderr.writeln(message);
  exit(1);
}

/// Every file under [root], following the runfiles symlinks.
List<File> allFiles(Directory root) {
  final out = <File>[];
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File) out.add(entity);
  }
  return out;
}

/// The single file matching [matches], or a failure naming what was found.
File takeSingle(
  List<File> files,
  bool Function(File) matches,
  String description,
) {
  final hits = [
    for (final f in files)
      if (matches(f)) f,
  ];
  if (hits.length != 1) {
    final paths = [for (final f in hits.take(4)) f.path].join(', ');
    abort(
      'FAIL: expected $description; found ${hits.length}'
      '${paths.isEmpty ? '' : ': $paths'}',
    );
  }
  return hits[0];
}

/// The bytes of [file], or a failure naming the read error.
Uint8List readOrAbort(File file) {
  try {
    return file.readAsBytesSync();
  } on FileSystemException catch (e) {
    abort('FAIL: could not read ${file.path}: $e');
  }
}

/// Collects passing and failing checks; every failure names expected/found.
class BundleReport {
  final _failures = <String>[];

  /// Whether every check so far passed.
  bool get passed => _failures.isEmpty;

  /// Records one check of [description], printing the outcome.
  void check(String description, {required bool ok, String? found}) {
    if (ok) {
      print('OK: $description');
    } else {
      stderr.writeln(
        'FAIL: expected $description; found ${found ?? 'nothing'}',
      );
      _failures.add(description);
    }
  }
}

/// The VM features string in [bytes], or empty when the binary holds none.
///
/// The string is a space-separated word list starting at `product` (for
/// example `product no-asan ... arm64 ios no-compressed-pointers`). It is
/// stored glued to a hash with no separator, so it is found by its opening
/// word rather than as a whole printable run, and read to the next
/// non-printable byte.
String snapshotFeatures(Uint8List bytes) {
  final text = latin1.decode(bytes);
  final at = text.indexOf('product ');
  if (at < 0) return '';
  var end = at;
  while (end < text.length) {
    final unit = text.codeUnitAt(end);
    if (unit < 0x20 || unit > 0x7e) break;
    end++;
  }
  return text.substring(at, end);
}

/// Names the entries directly inside [dir], or notes that it is missing.
String childNames(Directory dir) {
  if (!dir.existsSync()) return 'no directory at ${dir.path}';
  final names = dir.listSync().map((e) => e.uri.pathSegments.last).toList()
    ..sort();
  return names.isEmpty ? 'an empty directory' : names.join(', ');
}

/// Whether [haystack] holds [needle] as contiguous bytes.
bool hasBytes(Uint8List haystack, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

/// What the test learned from one Mach-O binary.
class MachO {
  const MachO({
    required this.cpuType,
    required this.platform,
    required this.exportNames,
    required this.localSymbolCount,
    required this.stabSymbolCount,
    required this.hasCodeSignature,
  });

  /// The header `cputype` (arm64 expected).
  final int cpuType;

  /// The `LC_BUILD_VERSION` platform, or null when the command is absent.
  final int? platform;

  /// Exported symbol names: the `LC_SYMTAB` entries in `LC_DYSYMTAB`'s
  /// external-defined range, plus any dyld export trie entries.
  final Set<String> exportNames;

  /// `LC_DYSYMTAB` `nlocalsym`, or null when the command is absent.
  final int? localSymbolCount;

  /// `LC_SYMTAB` entries whose `n_type` has a stab bit (`& 0xe0 != 0`).
  final int stabSymbolCount;

  /// Whether the binary carries an `LC_CODE_SIGNATURE` load command.
  final bool hasCodeSignature;
}

/// Parses the Mach-O header and load commands of [bytes].
///
/// Throws a [FormatException] naming the offset when the bytes are truncated
/// or shaped unexpectedly, so a binary the loader would reject fails this
/// test instead of passing it.
MachO parseMachO(Uint8List bytes) {
  final head = _Reader(bytes);
  final magic = head.u32();
  if (magic != machOMagic64) {
    throw FormatException(
      'expected a 64-bit Mach-O magic 0x${machOMagic64.toRadixString(16)}, '
      'found 0x${magic.toRadixString(16)}',
    );
  }
  final cpuType = head.u32();
  head.skip(8);
  final ncmds = head.u32();
  head.skip(12);
  int? platform;
  final exportNames = <String>{};
  int? localSymbolCount;
  var stabSymbolCount = 0;
  var hasCodeSignature = false;
  int? symtabAt;
  int? dysymtabAt;
  for (var i = 0; i < ncmds; i++) {
    final commandAt = head.offset;
    final command = head.u32();
    final cmdsize = head.u32();
    if (cmdsize < 8 || commandAt + cmdsize > bytes.length) {
      throw FormatException(
        'load command $i runs past the file at $commandAt '
        '(cmdsize $cmdsize of ${bytes.length} bytes)',
      );
    }
    switch (command) {
      case machOLcBuildVersion:
        platform ??= _buildVersionPlatform(bytes, commandAt);
      case machOLcSymtab:
        symtabAt ??= commandAt;
        stabSymbolCount += _symtabStabCount(bytes, commandAt);
      case machOLcDysymtab:
        dysymtabAt ??= commandAt;
        localSymbolCount = _dysymtabLocalCount(bytes, commandAt);
      case machOLcDyldInfoOnly:
        exportNames.addAll(_infoTrieNames(bytes, commandAt));
      case machOLcDyldExportsTrie:
        exportNames.addAll(_exportsTrieNames(bytes, commandAt));
      case machOLcCodeSignature:
        hasCodeSignature = true;
    }
    head.offset = commandAt + cmdsize;
  }
  if (symtabAt != null && dysymtabAt != null) {
    exportNames.addAll(_externalDefinedNames(bytes, symtabAt, dysymtabAt));
  }
  return MachO(
    cpuType: cpuType,
    platform: platform,
    exportNames: exportNames,
    localSymbolCount: localSymbolCount,
    stabSymbolCount: stabSymbolCount,
    hasCodeSignature: hasCodeSignature,
  );
}

/// The platform field of the `LC_BUILD_VERSION` at [commandAt].
int _buildVersionPlatform(Uint8List bytes, int commandAt) {
  final reader = _Reader(bytes)..offset = commandAt + 8;
  return reader.u32();
}

/// How many `LC_SYMTAB` entries at [commandAt] are debugging (stab) entries.
///
/// An `nlist_64` entry is 16 bytes with `n_type` at offset 4; a stab entry
/// has a bit in the `N_STAB` mask 0xe0 set.
int _symtabStabCount(Uint8List bytes, int commandAt) {
  final reader = _Reader(bytes)..offset = commandAt + 8;
  final symoff = reader.u32();
  final nsyms = reader.u32();
  reader.skip(8);
  if (symoff + nsyms * 16 > bytes.length) {
    throw FormatException(
      'LC_SYMTAB at $commandAt points past the file '
      '(symbols $symoff+$nsyms)',
    );
  }
  var stabs = 0;
  for (var i = 0; i < nsyms; i++) {
    if (bytes[symoff + i * 16 + 4] & 0xe0 != 0) stabs++;
  }
  return stabs;
}

/// The `LC_DYSYMTAB` `nlocalsym` at [commandAt] (`ilocalsym` is skipped).
int _dysymtabLocalCount(Uint8List bytes, int commandAt) {
  final reader = _Reader(bytes)
    ..offset = commandAt + 8
    ..skip(4);
  return reader.u32();
}

/// Names of the external defined symbols: the `LC_SYMTAB` entries in the
/// `LC_DYSYMTAB` `iextdefsym .. iextdefsym + nextdefsym` range.
///
/// A range past the table is a [FormatException], never a pass.
Set<String> _externalDefinedNames(
  Uint8List bytes,
  int symtabAt,
  int dysymtabAt,
) {
  final symtab = _Reader(bytes)..offset = symtabAt + 8;
  final symoff = symtab.u32();
  final nsyms = symtab.u32();
  final stroff = symtab.u32();
  final strsize = symtab.u32();
  final dysymtab = _Reader(bytes)
    ..offset = dysymtabAt + 8
    ..skip(8);
  final extdef = dysymtab.u32();
  final ndef = dysymtab.u32();
  if (symoff + nsyms * 16 > bytes.length || stroff + strsize > bytes.length) {
    throw FormatException(
      'LC_SYMTAB at $symtabAt points past the file '
      '(symbols $symoff+$nsyms, strings $stroff+$strsize)',
    );
  }
  if (extdef + ndef > nsyms) {
    throw FormatException(
      'LC_DYSYMTAB external range $extdef+$ndef runs past the $nsyms-entry '
      'LC_SYMTAB at $symtabAt',
    );
  }
  final names = <String>{};
  for (var i = extdef; i < extdef + ndef; i++) {
    final strx = _u32At(bytes, symoff + i * 16);
    names.add(_tableString(bytes, stroff, strsize, strx));
  }
  return names;
}

/// Reads one little-endian u32 at [offset], failing past the end.
int _u32At(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 4 > bytes.length) {
    throw FormatException('u32 at $offset runs past ${bytes.length} bytes');
  }
  return ByteData.sublistView(
    bytes,
    offset,
    offset + 4,
  ).getUint32(0, Endian.little);
}

/// Reads the NUL-terminated string at [tableAt] + [index].
String _tableString(Uint8List bytes, int tableAt, int tableSize, int index) {
  if (index < 0 || tableAt + index >= tableAt + tableSize) {
    throw FormatException(
      'string index $index runs past the $tableSize-byte table at $tableAt',
    );
  }
  var end = tableAt + index;
  while (end < tableAt + tableSize && bytes[end] != 0) {
    end++;
  }
  return utf8.decode(bytes.sublist(tableAt + index, end), allowMalformed: true);
}

/// Export names from the `LC_DYLD_INFO_ONLY` export trie at [commandAt].
Set<String> _infoTrieNames(Uint8List bytes, int commandAt) {
  final reader = _Reader(bytes)
    ..offset = commandAt + 8
    ..skip(32);
  final dataoff = reader.u32();
  final datasize = reader.u32();
  return _Trie(bytes, dataoff, datasize).names();
}

/// Export names from the `LC_DYLD_EXPORTS_TRIE` at [commandAt].
Set<String> _exportsTrieNames(Uint8List bytes, int commandAt) {
  final reader = _Reader(bytes)..offset = commandAt + 8;
  final dataoff = reader.u32();
  final datasize = reader.u32();
  return _Trie(bytes, dataoff, datasize).names();
}

/// A dyld export trie: child offsets count from the trie's own start.
class _Trie {
  _Trie(this.bytes, this.start, this.size) {
    if (start < 0 || size < 0 || start + size > bytes.length) {
      throw FormatException(
        'export trie at $start runs past the file '
        '(size $size of ${bytes.length} bytes)',
      );
    }
  }

  final Uint8List bytes;
  final int start;
  final int size;

  /// Every exported name in the trie.
  Set<String> names() {
    final out = <String>{};
    _walk(start, '', out);
    return out;
  }

  /// Collects the names under the node at [node], prefixed by [prefix].
  void _walk(int node, String prefix, Set<String> out) {
    if (node < start || node >= start + size) {
      throw FormatException(
        'export trie node at $node runs past the trie at $start '
        '(size $size)',
      );
    }
    final reader = _Reader(bytes)..offset = node;
    final terminalSize = reader.uleb();
    final terminalEnd = reader.offset + terminalSize;
    if (terminalEnd > start + size) {
      throw FormatException(
        'export trie terminal at $node runs past the trie end',
      );
    }
    if (terminalSize > 0) {
      reader.uleb();
      out.add(prefix);
      reader.offset = terminalEnd;
    }
    final children = reader.u8();
    for (var i = 0; i < children; i++) {
      final edge = reader.cstring();
      final child = reader.uleb();
      _walk(start + child, prefix + edge, out);
    }
  }
}

/// A bounds-checked cursor over Mach-O bytes.
class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  /// Skips [count] bytes.
  void skip(int count) {
    _need(count);
    offset += count;
  }

  /// Reads one byte.
  int u8() {
    _need(1);
    return bytes[offset++];
  }

  /// Reads one little-endian u32.
  int u32() {
    _need(4);
    final value = ByteData.sublistView(
      bytes,
      offset,
      offset + 4,
    ).getUint32(0, Endian.little);
    offset += 4;
    return value;
  }

  /// Reads one uleb128 value.
  int uleb() {
    var result = 0;
    var shift = 0;
    while (true) {
      final byte = u8();
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
      if (shift >= 64) {
        throw FormatException('uleb128 overflows at ${offset - 1}');
      }
    }
  }

  /// Reads one NUL-terminated string.
  String cstring() {
    final start = offset;
    while (true) {
      _need(1);
      if (bytes[offset++] == 0) break;
    }
    return utf8.decode(bytes.sublist(start, offset - 1), allowMalformed: true);
  }

  /// Throws a [FormatException] unless [count] bytes are readable.
  void _need(int count) {
    if (offset < 0 || offset + count > bytes.length) {
      throw FormatException(
        'truncated Mach-O at $offset (needs $count of ${bytes.length})',
      );
    }
  }
}
