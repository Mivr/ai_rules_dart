// Kernel byte builders for `kernel_module_test`: synthetic `.dill` components
// the planner and the source-stripping tests read.

import 'dart:convert';
import 'dart:typed_data';

import 'dill_outline.dart';

/// A minimal kernel component holding one class with one field, written with
/// the given [formatVersion] and [languageMajor]; [hasConstConstructor] adds
/// a const constructor.
Uint8List buildMinimalFieldDill({
  int formatVersion = Tag.BinaryFormatVersion,
  int languageMajor = 3,
  bool hasConstConstructor = true,
}) {
  final out = BytesBuilder();
  void u30(int v) {
    assert(v >= 0 && v < 0x80, 'u30 value out of range: $v');
    out.addByte(v);
  }

  void u32(int v) {
    out.addByte((v >> 24) & 0xff);
    out.addByte((v >> 16) & 0xff);
    out.addByte((v >> 8) & 0xff);
    out.addByte(v & 0xff);
  }

  // 18-byte header + problemsAsJson (UInt30(0))
  u32(Tag.ComponentFile);
  u32(formatVersion);
  for (var i = 0; i < 10; i++) {
    out.addByte(0);
  }
  u30(0);

  final int libStart = out.length;
  out.addByte(0); // flags
  u30(languageMajor); // major
  u30(0); // minor
  u30(1); // canonicalName
  u30(1); // name
  u30(0); // fileUri
  u30(0); // problemsAsJson
  u30(0); // annotations
  u30(0); // depCount
  u30(0); // expCount
  u30(0); // partCount
  u30(0); // tdCount
  u30(1); // clsCount = 1

  final int clsStart = out.length;
  out.addByte(Tag.Class);
  u30(1); // canonicalName
  u30(0); // fileUri
  u30(0);
  u30(0);
  u30(0); // 3 offsets
  u30(0); // flags (not a mixin)
  u30(1); // name
  u30(0); // annotations
  u30(0); // typeParameters
  out.addByte(Tag.Nothing); // supertype
  out.addByte(Tag.Nothing); // mixedInType
  u30(0); // implementedTypes

  // 3 fields: (flags=1 final instance, val=42), (flags=5 static final, val=99), (flags=0 mutable, val=77)
  u30(3);
  for (final (flags, val) in [(1, 42), (5, 99), (0, 77)]) {
    out.addByte(Tag.Field);
    u30(1);
    u30(1);
    u30(0); // 3 canonRefs
    u30(0); // uriRef
    u30(0);
    u30(0); // 2 offsets
    u30(flags);
    u30(1); // name ("f")
    u30(0); // scopeSize
    u30(0); // annotations
    out.addByte(Tag.DynamicType);
    out.addByte(Tag.Nothing); // option variable
    out.addByte(Tag.Something); // option expression
    out.addByte(Tag.PositiveIntLiteral);
    u30(0); // fileOffset
    u30(val);
    out.addByte(Tag.Nothing); // option scope
  }
  if (hasConstConstructor) {
    u30(1); // ctorCount = 1
    out.addByte(Tag.Constructor);
    u30(1); // canonicalName
    u30(0); // fileUri
    u30(0);
    u30(0);
    u30(0); // 3 offsets
    out.addByte(1); // flags = 1 (isConst)
    u30(1); // name ("f")
    u30(0); // annotations
    out.addByte(Tag.FunctionNode);
    u30(0);
    u30(0); // 2 offsets
    out.addByte(0); // asyncMarker
    out.addByte(0); // dartAsyncMarker
    u30(0); // scopeSize
    u30(0); // typeParameters
    out.addByte(Tag.Nothing); // thisVariable
    u30(0); // totalParameterCount
    u30(0); // requiredParameterCount
    u30(0); // posCount
    u30(0); // namedCount
    out.addByte(Tag.DynamicType); // returnType
    out.addByte(Tag.Nothing); // futureValueType
    out.addByte(0); // rftTag
    out.addByte(Tag.Nothing); // body Option<Statement>
    out.addByte(Tag.Nothing); // option scope
    out.addByte(Tag.Nothing); // option captured contexts
    u30(0); // initCount
  } else {
    u30(0); // ctorCount = 0
  }
  u30(0); // pCount = 0
  final int clsProcEnd = out.length;
  u32(clsProcEnd);
  u32(0); // procCount = 0
  final int clsEnd = out.length;

  u30(0); // extCount
  u30(0); // extTypeCount
  u30(0); // fieldCount
  u30(2); // pCount = 2
  final procOffsets = <int>[];
  for (final (flags, val) in [(9, 88), (1, 66)]) {
    procOffsets.add(out.length);
    out.addByte(Tag.Procedure);
    u30(1); // canonicalName
    u30(0); // fileUri
    u30(0);
    u30(0);
    u30(0); // 3 offsets
    out.addByte(0); // kind
    out.addByte(0); // stubKind
    u30(flags); // flags (9 = FlagStatic | FlagConst, 1 = FlagStatic)
    u30(1); // name ("f")
    u30(0); // annotations
    u30(0); // stubTarget
    out.addByte(Tag.Nothing); // signatureType
    out.addByte(Tag.FunctionNode);
    u30(0);
    u30(0); // 2 offsets
    out.addByte(0); // asyncMarker
    out.addByte(0); // dartAsyncMarker
    u30(0); // scopeSize
    u30(0); // typeParameters
    out.addByte(Tag.Nothing); // thisVariable
    u30(0); // totalParameterCount
    u30(0); // requiredParameterCount
    u30(0); // posCount
    u30(0); // namedCount
    out.addByte(Tag.DynamicType); // returnType
    out.addByte(Tag.Nothing); // futureValueType
    out.addByte(0); // rftTag
    out.addByte(Tag.Something); // body Option<Statement>
    out.addByte(Tag.ReturnStatement);
    u30(0); // fileOffset
    out.addByte(Tag.Something); // expression
    out.addByte(Tag.PositiveIntLiteral);
    u30(0); // fileOffset
    u30(val);
    out.addByte(Tag.Nothing); // option scope
    out.addByte(Tag.Nothing); // option captured contexts
  }
  final int libProcEnd = out.length;
  procOffsets.add(libProcEnd);
  final int sourceRefsOffset = out.length;
  u30(0); // usedCount = 0
  u32(sourceRefsOffset);
  u32(clsStart);
  u32(clsEnd);
  u32(1); // classCount = 1
  procOffsets.forEach(u32);
  u32(2); // procCount = 2
  final int libEnd = out.length;

  // Source table
  final sourceTableOffset = libEnd;
  u32(1); // uriCount = 1
  final int uriEntry0 = out.length;
  u30(0); // uriLen
  u30(0); // srcLen
  u30(0); // lineCount
  u30(0); // impLen
  u30(0); // covCount
  u32(uriEntry0);

  // Constant table
  final int constantTableOffset = out.length;
  u30(0); // constCount = 0
  final int constantTableIndexOffset = out.length;
  u32(0); // constCount = 0

  // Link table
  final int linkTableOffset = out.length;
  u30(1); // canonCount = 1
  u30(0); // parent
  u30(1); // string index 1

  // Metadata
  final int metaOffset = out.length;
  u32(0);

  // String table: ["", "f"]
  final int stringTableOffset = out.length;
  u30(2);
  u30(0);
  u30(1);
  out.addByte(102); // "f"

  // Component index
  final int componentIndexOffset = out.length;
  u32(sourceTableOffset);
  u32(constantTableOffset);
  u32(constantTableIndexOffset);
  u32(linkTableOffset);
  u32(metaOffset);
  u32(metaOffset);
  u32(stringTableOffset);
  u32(componentIndexOffset);
  u32(0); // mainMethodReference
  u32(libStart);
  u32(libEnd);
  u32(1); // libraryCount = 1
  u32(out.length + 4);
  return out.toBytes();
}

/// A structurally valid kernel component whose source table holds exactly [uris]
/// (with empty source code, line starts, import URIs and coverage), for
/// read-set verification tests. The bytes between the header and the source
/// table are filler: the verifier reads only the source table and the trailer
/// index.
Uint8List buildDillWithUris(
  List<String> uris, {
  int formatVersion = Tag.BinaryFormatVersion,
}) {
  final out = BytesBuilder();
  void u30(int v) {
    if (v < 0x80) {
      out.addByte(v);
    } else if (v < 0x4000) {
      out.addByte(0x80 | (v >> 8));
      out.addByte(v & 0xff);
    } else {
      out.addByte(0xc0 | ((v >> 24) & 0x3f));
      out.addByte((v >> 16) & 0xff);
      out.addByte((v >> 8) & 0xff);
      out.addByte(v & 0xff);
    }
  }

  void u32(int v) {
    out.addByte((v >> 24) & 0xff);
    out.addByte((v >> 16) & 0xff);
    out.addByte((v >> 8) & 0xff);
    out.addByte(v & 0xff);
  }

  void str(String s) {
    final Uint8List bytes = utf8.encode(s);
    u30(bytes.length);
    out.add(bytes);
  }

  u32(Tag.ComponentFile);
  u32(formatVersion);
  out.add(List.filled(64, 0));
  final int sourceTableOffset = out.length;
  u32(uris.length);
  for (final uri in uris) {
    str(uri);
    str('');
    u30(0);
    str('');
    u30(0);
  }
  final int constantTableOffset = out.length;
  u30(0);
  u32(sourceTableOffset);
  u32(constantTableOffset);
  for (var i = 0; i < 8; i++) {
    u32(constantTableOffset);
  }
  u32(0); // libraryCount = 0
  u32(out.length + 4);
  return out.toBytes();
}

/// A structurally valid kernel component whose source table holds [sources]
/// as (`fileUri`, `importUri`) pairs and whose library table holds one node
/// per entry of [libraries]: a source-table index with a canonical-name root
/// (null for a null reference). The string table holds the empty node name
/// plus each distinct canonical name, and the link table one root per
/// library — plus each of [extraRoots], which no node mentions, so the bytes
/// exercise a smuggled canonical root the library walk alone would miss.
Uint8List buildDillWithLibraries({
  required List<(String, String)> sources,
  required List<(int, String?)> libraries,
  int formatVersion = Tag.BinaryFormatVersion,
  List<String> extraRoots = const [],
}) {
  final out = BytesBuilder();
  void u30(int v) {
    if (v < 0x80) {
      out.addByte(v);
    } else if (v < 0x4000) {
      out.addByte(0x80 | (v >> 8));
      out.addByte(v & 0xff);
    } else {
      out.addByte(0xc0 | ((v >> 24) & 0x3f));
      out.addByte((v >> 16) & 0xff);
      out.addByte((v >> 8) & 0xff);
      out.addByte(v & 0xff);
    }
  }

  void u32(int v) {
    out.addByte((v >> 24) & 0xff);
    out.addByte((v >> 16) & 0xff);
    out.addByte((v >> 8) & 0xff);
    out.addByte(v & 0xff);
  }

  void str(String s) {
    final Uint8List bytes = utf8.encode(s);
    u30(bytes.length);
    out.add(bytes);
  }

  final strings = <String>[''];
  int stringIndexOf(String s) {
    int index = strings.indexOf(s);
    if (index < 0) {
      index = strings.length;
      strings.add(s);
    }
    return index;
  }

  u32(Tag.ComponentFile);
  u32(formatVersion);
  out.add(List.filled(64, 0));
  final int sourceTableOffset = out.length;
  u32(sources.length);
  for (final (fileUri, importUri) in sources) {
    str(fileUri);
    str('');
    u30(0);
    str(importUri);
    u30(0);
  }
  final int constantTableOffset = out.length;
  u30(0);
  final int linkTableOffset = out.length;
  u30(libraries.length + extraRoots.length);
  for (final (_, canon) in libraries) {
    u30(0); // Parent: the nameless root.
    u30(canon == null ? 0 : stringIndexOf(canon));
  }
  for (final root in extraRoots) {
    u30(0); // Parent: the nameless root no node references.
    u30(stringIndexOf(root));
  }
  final int stringTableOffset = out.length;
  u30(strings.length);
  var end = 0;
  final ends = <int>[];
  for (final s in strings) {
    end += utf8.encode(s).length;
    ends.add(end);
  }
  ends.forEach(u30);
  for (final s in strings) {
    out.add(utf8.encode(s));
  }
  final libraryOffsets = <int>[];
  for (var i = 0; i < libraries.length; i++) {
    libraryOffsets.add(out.length);
    final (int source, String? canon) = libraries[i];
    out.addByte(4); // Flags.
    u30(3); // Major version.
    u30(0); // Minor version.
    // Canonical-name reference, biased by one; zero names no reference.
    u30(canon == null ? 0 : i + 1);
    u30(0); // Name string reference: the empty name.
    u30(source);
  }
  libraryOffsets.add(out.length);
  u32(sourceTableOffset);
  u32(constantTableOffset);
  u32(constantTableOffset);
  u32(linkTableOffset);
  u32(linkTableOffset);
  u32(linkTableOffset);
  u32(stringTableOffset);
  u32(stringTableOffset);
  u32(stringTableOffset);
  libraryOffsets.forEach(u32);
  u32(libraries.length);
  u32(out.length + 4);
  return out.toBytes();
}

/// A minimal kernel component whose one source holds [srcLen] bytes of source
/// text and whose metadata payload offsets follow it.
Uint8List buildMinimalDillWithSourceAndMetadata({required int srcLen}) {
  final out = BytesBuilder();
  void u30(int v) {
    assert(v >= 0 && v < 0x80, 'u30 value out of range: $v');
    out.addByte(v);
  }

  void u32(int v) {
    out.addByte((v >> 24) & 0xff);
    out.addByte((v >> 16) & 0xff);
    out.addByte((v >> 8) & 0xff);
    out.addByte(v & 0xff);
  }

  u32(Tag.ComponentFile);
  u32(Tag.BinaryFormatVersion);
  for (var i = 0; i < 10; i++) {
    out.addByte(0);
  }
  u30(0);

  final int libStart = out.length;
  out.addByte(0); // flags
  u30(3); // major
  u30(0); // minor
  u30(1); // canonicalName
  u30(1); // name
  u30(0); // fileUri
  u30(0); // problemsAsJson
  u30(0); // annotations
  u30(0); // depCount
  u30(0); // expCount
  u30(0); // partCount
  u30(0); // tdCount
  u30(0); // clsCount
  u30(0); // extCount
  u30(0); // extTypeCount
  u30(0); // fieldCount
  u30(0); // pCount
  final int sourceRefsOffset = out.length;
  u30(0); // usedCount
  u32(sourceRefsOffset);
  u32(libStart + 13); // clsOffsets[0]
  u32(0); // classCount
  u32(sourceRefsOffset); // procOffsets[0]
  u32(0); // procCount
  final int libEnd = out.length;

  final sourceTableOffset = libEnd;
  u32(1); // numSources = 1
  final int uriEntry0 = out.length;
  u30(5); // uriLen = 5 ("a.dart" prefix)
  out.add([97, 46, 100, 97, 114]);
  u30(srcLen);
  out.add(List<int>.filled(srcLen, 0x61));
  u30(2); // lineCount = 2
  u30(0);
  u30(1);
  u30(5); // importUri len = 5
  out.add([97, 46, 100, 97, 114]);
  u30(0); // constantCoverageConstructors
  u32(uriEntry0);

  final int constantTableOffset = out.length;
  u30(0);
  final int constantTableIndexOffset = out.length;
  u32(0);

  final int linkTableOffset = out.length;
  u30(1); // canonCount = 1
  u30(0);
  u30(1);

  final int metaPad = (8 - (out.length % 8)) % 8;
  if (metaPad > 0) out.add(Uint8List(metaPad));
  final int metadataPayloadsOffset = out.length;
  out.add([0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe]);
  final int metadataMappingsOffset = out.length;
  out.add([0x11, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00, 0x01]);

  final int stringTableOffset = out.length;
  u30(2);
  u30(0);
  u30(1);
  out.addByte(102); // "f"

  final int componentIndexOffset = out.length;
  const int idxBytes = 13 * 4;
  final int pad = (8 - ((out.length + idxBytes) % 8)) % 8;
  if (pad > 0) out.add(Uint8List(pad));

  u32(sourceTableOffset);
  u32(constantTableOffset);
  u32(constantTableIndexOffset);
  u32(linkTableOffset);
  u32(metadataPayloadsOffset);
  u32(metadataMappingsOffset);
  u32(stringTableOffset);
  u32(componentIndexOffset);
  u32(0); // mainMethodReference
  u32(libStart);
  u32(libEnd);
  u32(1); // libraryCount = 1
  u32(out.length + 4);
  return out.toBytes();
}
