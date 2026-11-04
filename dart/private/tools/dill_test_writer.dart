// Shared byte writer and component builders for the kernel `.dill` fixtures
// that `kernel_module_test` and `app_jit_snapshot_test` synthesize.
import 'dart:convert';
import 'dart:typed_data';

/// The kernel component file magic number.
const int dillComponentMagic = 0x90ABCDEF;

/// The offsets a kernel component's trailing index records, in the order the
/// index lists them.
typedef ComponentIndex = ({
  int sourceTable,
  int constantTable,
  int constantIndex,
  int linkTable,
  int metaPayloads,
  int metaMappings,
  int stringTable,
  int componentIndex,
  int libStart,
  int libEnd,
});

/// An append-only writer for kernel binary primitives.
class DillWriter {
  final BytesBuilder _out = BytesBuilder();

  /// The number of bytes written so far.
  int get length => _out.length;

  /// Appends one raw byte.
  void byte(int v) => _out.addByte(v);

  /// Appends raw [v] bytes.
  void bytes(List<int> v) => _out.add(v);

  /// Appends a variable-length unsigned integer.
  void u30(int v) {
    if (v < 0x80) {
      _out.addByte(v);
    } else if (v < 0x4000) {
      _out.addByte(0x80 | (v >> 8));
      _out.addByte(v & 0xff);
    } else {
      _out.addByte(0xc0 | ((v >> 24) & 0x3f));
      _out.addByte((v >> 16) & 0xff);
      _out.addByte((v >> 8) & 0xff);
      _out.addByte(v & 0xff);
    }
  }

  /// Appends each of [values] as a variable-length unsigned integer.
  void u30s(Iterable<int> values) => values.forEach(u30);

  /// Appends a big-endian 32-bit unsigned integer.
  void u32(int v) {
    _out.addByte((v >> 24) & 0xff);
    _out.addByte((v >> 16) & 0xff);
    _out.addByte((v >> 8) & 0xff);
    _out.addByte(v & 0xff);
  }

  /// Appends each of [values] as a big-endian 32-bit unsigned integer.
  void u32s(Iterable<int> values) => values.forEach(u32);

  /// Appends a length-prefixed UTF-8 string.
  void str(String s) {
    final Uint8List encoded = utf8.encode(s);
    u30(encoded.length);
    _out.add(encoded);
  }

  /// The bytes written so far.
  Uint8List toBytes() => _out.toBytes();
}

/// Writes the 18-byte component header and the empty problems string.
void writeDillHeader(DillWriter w, int formatVersion) {
  w.u32(dillComponentMagic);
  w.u32(formatVersion);
  w.bytes(List<int>.filled(10, 0));
  w.u30(0);
}

/// Writes a library node's fields up to and including its type-definition
/// count, for a library at language major version [languageMajor].
void writeLibraryPrefix(DillWriter w, int languageMajor) {
  w.byte(0); // Flags.
  w.u30s([languageMajor, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0]);
}

/// Writes an empty constant table and its index, returning their offsets.
({int table, int index}) writeEmptyConstantTable(DillWriter w) {
  final int table = w.length;
  w.u30(0);
  final int index = w.length;
  w.u32(0);
  return (table: table, index: index);
}

/// Writes a link table holding one root canonical name, returning its offset.
int writeSingleLinkTable(DillWriter w) {
  final int offset = w.length;
  w.u30s([1, 0, 1]);
  return offset;
}

/// Writes the string table `["", "f"]`, returning its offset.
int writeFStringTable(DillWriter w) {
  final int offset = w.length;
  w.u30s([2, 0, 1]);
  w.byte(102); // "f"
  return offset;
}

/// Writes the component index and the trailing file size.
void writeComponentIndex(DillWriter w, ComponentIndex index) {
  w.u32s([
    index.sourceTable,
    index.constantTable,
    index.constantIndex,
    index.linkTable,
    index.metaPayloads,
    index.metaMappings,
    index.stringTable,
    index.componentIndex,
    0, // mainMethodReference
    index.libStart,
    index.libEnd,
    1, // libraryCount
  ]);
  w.u32(w.length + 4);
}

/// Writes a source table holding [sources] as (`fileUri`, `importUri`) pairs
/// with empty source code, line starts and coverage, returning its offset.
int writeSourceTable(DillWriter w, List<(String, String)> sources) {
  final int offset = w.length;
  w.u32(sources.length);
  for (final (fileUri, importUri) in sources) {
    w.str(fileUri);
    w.str('');
    w.u30(0);
    w.str(importUri);
    w.u30(0);
  }
  return offset;
}

/// A structurally valid kernel component whose source table holds [sources]
/// as (`fileUri`, `importUri`) pairs and whose library table holds one node
/// per entry of [libraries]: a source-table index with a canonical-name root
/// (null for a null reference). The string table holds the empty node name
/// plus each distinct canonical name, and the link table one root per
/// library — plus each of [extraRoots], which no node mentions, so the bytes
/// exercise a smuggled canonical root the library walk alone would miss.
Uint8List buildLibraryTableDill({
  required int formatVersion,
  required List<(String, String)> sources,
  required List<(int, String?)> libraries,
  List<String> extraRoots = const [],
}) {
  final w = DillWriter();
  final strings = <String>[''];
  int stringIndexOf(String s) {
    int index = strings.indexOf(s);
    if (index < 0) {
      index = strings.length;
      strings.add(s);
    }
    return index;
  }

  w.u32(dillComponentMagic);
  w.u32(formatVersion);
  w.bytes(List<int>.filled(64, 0));
  final int sourceTableOffset = writeSourceTable(w, sources);
  final int constantTableOffset = w.length;
  w.u30(0);
  final int linkTableOffset = w.length;
  w.u30(libraries.length + extraRoots.length);
  for (final (_, canon) in libraries) {
    w.u30(0); // Parent: the nameless root.
    w.u30(canon == null ? 0 : stringIndexOf(canon));
  }
  for (final root in extraRoots) {
    w.u30(0); // Parent: the nameless root no node references.
    w.u30(stringIndexOf(root));
  }
  final int stringTableOffset = _writeStringTable(w, strings);
  final List<int> libraryOffsets = _writeLibraryNodes(w, libraries);
  w.u32s([
    sourceTableOffset,
    constantTableOffset,
    constantTableOffset,
    linkTableOffset,
    linkTableOffset,
    linkTableOffset,
    stringTableOffset,
    stringTableOffset,
    stringTableOffset,
    ...libraryOffsets,
    libraries.length,
  ]);
  w.u32(w.length + 4);
  return w.toBytes();
}

int _writeStringTable(DillWriter w, List<String> strings) {
  final int offset = w.length;
  w.u30(strings.length);
  var end = 0;
  final ends = <int>[];
  for (final s in strings) {
    end += utf8.encode(s).length;
    ends.add(end);
  }
  w.u30s(ends);
  for (final s in strings) {
    w.bytes(utf8.encode(s));
  }
  return offset;
}

List<int> _writeLibraryNodes(DillWriter w, List<(int, String?)> libraries) {
  final offsets = <int>[];
  for (var i = 0; i < libraries.length; i++) {
    offsets.add(w.length);
    final (int source, String? canon) = libraries[i];
    w.byte(4); // Flags.
    w.u30(3); // Major version.
    w.u30(0); // Minor version.
    // Canonical-name reference, biased by one; zero names no reference.
    w.u30(canon == null ? 0 : i + 1);
    w.u30(0); // Name string reference: the empty name.
    w.u30(source);
  }
  offsets.add(w.length);
  return offsets;
}
