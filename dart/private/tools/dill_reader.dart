// The kernel (`.dill`) byte readers shared by the build-action tools: the
// component splitter, the source-table and library-reference readers, and the
// multi-root prefix stripper. `kernel_module.dart` compiles this file through
// `srcs`; `app_jit_snapshot.dart` runs it from source beside the staged tool
// (see the `jit_tool_srcs` bundle in `dart/private/tools/BUILD.bazel`). One home for the table
// layouts, so every read-set check parses the same bytes.

import 'dart:convert';
import 'dart:typed_data';

import '../../guard/lib/directive_guard.dart';

/// The kernel component-file magic tag every reader below matches: one
/// component, or concatenated ones each tagged. (This is the component-file
/// tag of the kernel format; `dill_outline.dart` names the same value
/// `Tag.ComponentFile` for the strippers.)
const dillComponentMagic = 0x90ABCDEF;

/// The path after `multiRootPrefix`, or null for any other URI.
String? stripMultiRootPrefix(String uri, String multiRootPrefix) {
  if (uri.startsWith(multiRootPrefix)) {
    return uri.substring(multiRootPrefix.length);
  }
  return null;
}

/// The declared-input key the recorded kernel URI [uri] names, or null when it
/// names no workspace file (`dart:`, `data:`, the SDK, an untranslatable URI,
/// or the empty entry). The empty string marks a file no root names — outside
/// every root, or an unknown scheme — which is never a declared input, so such
/// reads fail closed. Recorded multi-root URIs decode once, undoing the
/// encoding the recording adds: a literal `%` in a file name round-trips
/// through `%25`. [keyOfFileUri] keys the `file:` URIs the way the caller
/// stages them: under the multi-roots for the modular planner, under the
/// working directory and filesystem roots for the whole-program wrapper.
String? keyOfDillSourceUri(
  String uri,
  String multiRootPrefix,
  String Function(String uri) keyOfFileUri,
) {
  // An empty source-table entry names no file, so there is no read to verify.
  if (uri.isEmpty) return null;
  final stripped = stripMultiRootPrefix(uri, multiRootPrefix);
  if (stripped != null) {
    return stripped.contains('%')
        ? stripped.split('/').map(decodeUriSegment).join('/')
        : stripped;
  }
  if (uri.startsWith('dart:') ||
      uri.startsWith('data:') ||
      uri.startsWith('org-dartlang-sdk:') ||
      uri.startsWith('org-dartlang-untranslatable-uri:')) {
    return null;
  }
  if (uri.startsWith('file:')) {
    return keyOfFileUri(uri);
  }
  return '';
}

/// The byte ranges of the kernel components in [data] (a single component, or
/// concatenated ones), or null when [data] is structurally not a kernel file.
List<(int, int)>? _componentRanges(Uint8List data) {
  if (data.length < 48) return null;
  final bd = ByteData.sublistView(data);
  if (bd.getUint32(0) != dillComponentMagic) return null;
  final lastSize = bd.getUint32(data.length - 4);
  if (lastSize == data.length) return [(0, data.length)];
  final ranges = <(int, int)>[];
  var end = data.length;
  while (end >= 48) {
    final compSize = bd.getUint32(end - 4);
    if (compSize < 48 || compSize > end) return null;
    final start = end - compSize;
    if (bd.getUint32(start) != dillComponentMagic) return null;
    ranges.add((start, end));
    end = start;
  }
  if (end != 0 || ranges.isEmpty) return null;
  return ranges.reversed.toList();
}

/// A bounds-checked cursor over one kernel component's table bytes. Reads stop
/// at [limit], so malformed bytes fail instead of misreading.
class _TableCursor {
  _TableCursor(this._part, this._limit, int pos) : _pos = pos;

  final Uint8List _part;
  final int _limit;
  int _pos;

  /// The cursor's offset in [_part].
  int get position => _pos;

  /// The next UInt30, or null at the limit.
  int? readU30() {
    if (_pos >= _limit) return null;
    final b0 = _part[_pos++];
    if ((b0 & 0x80) == 0) return b0;
    if ((b0 & 0x40) == 0) {
      if (_pos >= _limit) return null;
      return ((b0 & 0x3f) << 8) | _part[_pos++];
    }
    if (_pos + 3 > _limit) return null;
    final value =
        ((b0 & 0x3f) << 24) |
        (_part[_pos] << 16) |
        (_part[_pos + 1] << 8) |
        _part[_pos + 2];
    _pos += 3;
    return value;
  }

  /// Whether [n] bytes from here stay within the limit.
  bool hasBytes(int n) => n >= 0 && _pos + n <= _limit;

  /// Advances past [n] bytes, or false when they leave the limit.
  bool skipBytes(int n) {
    if (!hasBytes(n)) return false;
    _pos += n;
    return true;
  }

  /// Advances past [n] bytes without checking; call only after [hasBytes].
  void advance(int n) {
    _pos += n;
  }

  /// The next [n] bytes decoded as UTF-8, or null when they are malformed.
  String? readUtf8(int n) {
    final start = _pos;
    _pos += n;
    // Callers bounds-check with `hasBytes` first, so the slice is in range
    // and only malformed UTF-8 fails.
    try {
      return utf8.decode(_part.sublist(start, start + n));
    } on FormatException {
      return null;
    }
  }
}

/// The bounds of one kernel component's source table: the constant-table
/// limit, the first entry's offset, and the entry count. Null when the header
/// does not parse; every offset is bounds-checked.
({int limit, int pos, int numSources})? _sourceTableHeader(Uint8List part) {
  if (part.length < 12) return null;
  final bd = ByteData.sublistView(part);
  if (bd.getUint32(0) != dillComponentMagic) return null;
  final libCount = bd.getUint32(part.length - 8);
  final idxBytes = (libCount + 12) * 4;
  if (idxBytes > part.length) return null;
  final rawIdxStart = part.length - idxBytes;
  final offSourceTable = bd.getUint32(rawIdxStart);
  final offConstantTable = bd.getUint32(rawIdxStart + 4);
  if (offSourceTable + 4 > offConstantTable || offConstantTable > rawIdxStart) {
    return null;
  }
  return (
    limit: offConstantTable,
    pos: offSourceTable + 4,
    numSources: bd.getUint32(offSourceTable),
  );
}

/// Skips one UInt30 count and the values it counts. False at the limit.
bool _skipU30Run(_TableCursor cursor) {
  final count = cursor.readU30();
  if (count == null) return false;
  for (var j = 0; j < count; j++) {
    if (cursor.readU30() == null) return false;
  }
  return true;
}

/// Reads one source-table entry into [uris] (and [importUris], when given).
/// False, leaving them short, when the entry does not parse.
bool _readSourceEntry(
  _TableCursor cursor,
  List<String> uris,
  List<String>? importUris,
) {
  // 1. uri: UInt30 byteLength + UTF-8 bytes.
  final uriLen = cursor.readU30();
  if (uriLen == null || uriLen < 0 || !cursor.hasBytes(uriLen)) {
    return false;
  }
  final uri = cursor.readUtf8(uriLen);
  if (uri == null) return false;
  uris.add(uri);
  // 2. sourceCode: UInt30 byteLength + UTF-8 bytes.
  final srcLen = cursor.readU30();
  if (srcLen == null || !cursor.skipBytes(srcLen)) return false;
  // 3. lineStarts: UInt30 count + count * UInt30 delta.
  if (!_skipU30Run(cursor)) return false;
  // 4. importUri: UInt30 byteLength + UTF-8 bytes.
  final impLen = cursor.readU30();
  if (impLen == null || impLen < 0 || !cursor.hasBytes(impLen)) {
    return false;
  }
  if (importUris != null) {
    final importUri = cursor.readUtf8(impLen);
    if (importUri == null) return false;
    importUris.add(importUri);
  } else {
    cursor.advance(impLen);
  }
  // 5. constantCoverageConstructors: UInt30 count + count * UInt30.
  return _skipU30Run(cursor);
}

/// Adds the `fileUri` of every source in the one kernel component [part] to
/// [uris]. Returns false (leaving [uris] short) when [part] is not a
/// well-formed component: every offset and length is bounds-checked against
/// its source table, so malformed bytes fail instead of misreading.
///
/// The source-table entry layout (`uri`, `sourceCode`, `lineStarts`,
/// `importUri`, `constantCoverageConstructors`) is stable across every Dart
/// SDK this rule set supports, while the 32-bit kernel format version in the
/// header moves with the SDK (127 under 3.11.0, 130 under 3.12.2, 138 under
/// 3.13.5), so the table is parsed structurally with no version gate: gating
/// here failed every read-set verification on older SDKs, failing legitimate
/// compiles. Byte-rewriting stays version-gated in the strippers.
/// Adds the `fileUri` of every source in the one kernel component [part] to
/// [uris] — and, when [importUris] is given, the `importUri` recorded
/// alongside it (the spelling the importer named the library by, which the
/// library-reference check verifies independently of the file read).
bool _collectComponentSourceUris(
  Uint8List part,
  List<String> uris, [
  List<String>? importUris,
]) {
  final header = _sourceTableHeader(part);
  if (header == null) return false;
  final cursor = _TableCursor(part, header.limit, header.pos);
  for (var i = 0; i < header.numSources; i++) {
    if (!_readSourceEntry(cursor, uris, importUris)) return false;
  }
  return true;
}

/// The `fileUri` of every source recorded in the kernel component(s) in [data]
/// — the files the compile actually read — or null when [data] is not a
/// well-formed kernel file. Any format version parses: the source-table layout
/// is stable across SDKs, and every offset is bounds-checked.
List<String>? dillSourceUris(Uint8List data) {
  final ranges = _componentRanges(data);
  if (ranges == null) return null;
  final uris = <String>[];
  for (final (start, end) in ranges) {
    if (!_collectComponentSourceUris(
      Uint8List.sublistView(data, start, end),
      uris,
    )) {
      return null;
    }
  }
  return uris;
}

/// One library node of a kernel component: the source-table entry it was read
/// from, and the names it is linked under. A `null` [fileUri] or [importUri]
/// means the node's source index names no table entry (a corrupt or
/// truncated component, which carries no reference to check); an empty
/// [canonicalName] means the node has no canonical-name reference.
typedef DillLibraryReference = ({
  int fileUriIndex,
  String? fileUri,
  String? importUri,
  String canonicalName,
});

/// The library references of the kernel component(s) in [data] — one record
/// per library node, holding its source-table index with that entry's
/// `fileUri`/`importUri` spellings, and its canonical name's root string
/// (libraries link under their import URI, so the root names the library the
/// same way the source table's `importUri` does).
///
/// Null when [data] is not a well-formed kernel file, or when its
/// string, link, or library tables do not parse: the caller then keeps the
/// source-table verdict, which never depends on these tables. Per-library
/// reference failures (a dangling source index, an unresolvable canonical
/// name) degrade to a missing reference in that record, never to a refusal:
/// only a present reference the inputs do not define fails the check, so a
/// future SDK that reshapes an unread table cannot fail a legitimate compile
/// here — the source table still verifies every file read.
///
/// The node header prefix (`flags`, version, canonical-name, name, file-URI
/// references) is position-stable across SDKs; only that prefix is read, so
/// appended fields never disturb the parse. Every offset and length is
/// bounds-checked against its table.
List<DillLibraryReference>? dillLibraryReferences(Uint8List data) {
  final ranges = _componentRanges(data);
  if (ranges == null) return null;
  final refs = <DillLibraryReference>[];
  for (final (start, end) in ranges) {
    if (!_collectComponentLibraries(
      Uint8List.sublistView(data, start, end),
      refs,
    )) {
      return null;
    }
  }
  return refs;
}

/// The name tables of one kernel component: its source-table URIs plus the
/// string table and canonical-name table its library references link through.
/// Null when the component's tables do not parse; every offset and length is
/// bounds-checked.
typedef _NameTables = ({
  List<String> fileUris,
  List<String> importUris,
  String? Function(int) stringAt,
  List<int> canonParents,
  List<int> canonStrings,
});

_NameTables? _componentNameTables(Uint8List part) {
  if (part.length < 12) return null;
  final bd = ByteData.sublistView(part);
  if (bd.getUint32(0) != dillComponentMagic) return null;
  final libCount = bd.getUint32(part.length - 8);
  // No library nodes means no library references: the source-table verdict
  // stands alone, and the remaining tables (whose offsets test fixtures may
  // leave unset) are never touched.
  if (libCount == 0) {
    return (
      fileUris: <String>[],
      importUris: <String>[],
      stringAt: (int index) => null,
      canonParents: <int>[],
      canonStrings: <int>[],
    );
  }
  final idxBytes = (libCount + 12) * 4;
  if (idxBytes > part.length) return null;
  final rawIdxStart = part.length - idxBytes;
  final offSourceTable = bd.getUint32(rawIdxStart);
  final offLinkTable = bd.getUint32(rawIdxStart + 12);
  final offStringTable = bd.getUint32(rawIdxStart + 24);
  if (offSourceTable + 4 > part.length ||
      offLinkTable > rawIdxStart ||
      offStringTable > rawIdxStart ||
      offLinkTable > offStringTable) {
    return null;
  }
  final fileUris = <String>[];
  final importUris = <String>[];
  if (!_collectComponentSourceUris(part, fileUris, importUris)) return null;

  final stringAt = _readComponentStrings(part, offStringTable, rawIdxStart);
  if (stringAt == null) return null;
  // The canonical-name table: a count of (parent, name-string) pairs, with
  // the parent biased by one (zero names the nameless root).
  final canon = _readCanonTable(part, offLinkTable, offStringTable);
  if (canon == null) return null;
  final (canonParents, canonStrings) = canon;
  return (
    fileUris: fileUris,
    importUris: importUris,
    stringAt: stringAt,
    canonParents: canonParents,
    canonStrings: canonStrings,
  );
}

/// The string-table reader of one kernel component: resolves a string index,
/// or null when the table does not parse. Every offset is bounds-checked.
String? Function(int)? _readComponentStrings(
  Uint8List part,
  int offStringTable,
  int rawIdxStart,
) {
  // The string table: a count, cumulative end offsets, then the bytes.
  final cursor = _TableCursor(part, rawIdxStart, offStringTable);
  final strCount = cursor.readU30();
  if (strCount == null || strCount < 0) return null;
  final strEnds = <int>[];
  var prevEnd = 0;
  for (var i = 0; i < strCount; i++) {
    final end = cursor.readU30();
    if (end == null || end < prevEnd) return null;
    strEnds.add(end);
    prevEnd = end;
  }
  final strBase = cursor.position;
  if (strEnds.isNotEmpty && strBase + strEnds.last > rawIdxStart) return null;
  String? stringAt(int index) {
    if (index < 0 || index >= strEnds.length) return null;
    final start = index == 0 ? 0 : strEnds[index - 1];
    // The header enforces monotonic ends within the part, so the slice is in
    // range and only malformed UTF-8 fails. A corrupt ends table running past
    // the component bytes names no entry either.
    try {
      return utf8.decode(
        part.sublist(strBase + start, strBase + strEnds[index]),
      );
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  return stringAt;
}

/// The canonical-name table of one component as (parents, name strings), or
/// null when it does not parse.
(List<int>, List<int>)? _readCanonTable(
  Uint8List part,
  int offLinkTable,
  int offStringTable,
) {
  final cursor = _TableCursor(part, offStringTable, offLinkTable);
  final canonCount = cursor.readU30();
  if (canonCount == null || canonCount < 0) return null;
  final canonParents = <int>[];
  final canonStrings = <int>[];
  for (var i = 0; i < canonCount; i++) {
    final parent = cursor.readU30();
    final name = cursor.readU30();
    if (parent == null || name == null) return null;
    canonParents.add(parent);
    canonStrings.add(name);
  }
  return (canonParents, canonStrings);
}

/// Adds one [DillLibraryReference] per library node of the one kernel
/// component [part] to [refs]. Returns false (leaving [refs] short) when the
/// component's tables do not parse; every offset and length is bounds-checked.
bool _collectComponentLibraries(
  Uint8List part,
  List<DillLibraryReference> refs,
) {
  final tables = _componentNameTables(part);
  if (tables == null) return false;
  final nodeCount = _libraryNodeCount(part);
  if (nodeCount == null) return false;
  // No library nodes means no library references: the source-table verdict
  // stands alone, and the remaining tables are never touched.
  for (var i = 0; i < nodeCount; i++) {
    final ref = _readLibraryNode(part, nodeCount, i, tables);
    if (ref == null) return false;
    refs.add(ref);
  }
  return true;
}

/// The library-node count of one kernel component, or null when its index
/// does not parse.
int? _libraryNodeCount(Uint8List part) {
  if (part.length < 12) return null;
  final bd = ByteData.sublistView(part);
  final libCount = bd.getUint32(part.length - 8);
  if (libCount == 0) return 0;
  final idxBytes = (libCount + 12) * 4;
  if (idxBytes > part.length) return null;
  return libCount;
}

/// The canonical-name root of one biased reference: the topmost ancestor's
/// string, or empty when the chain dangles. Only a present root the inputs do
/// not define fails the check, so an unresolvable one degrades to empty.
String _canonicalRoot(int biased, _NameTables tables) {
  final canonParents = tables.canonParents;
  final canonCount = canonParents.length;
  var index = biased - 1;
  if (biased <= 0 || index >= canonCount) return '';
  var guard = canonCount + 1;
  while (canonParents[index] != 0) {
    if (guard-- <= 0) return '';
    index = canonParents[index] - 1;
    if (index < 0 || index >= canonCount) return '';
  }
  return tables.stringAt(tables.canonStrings[index]) ?? '';
}

/// One library node's reference: its source-table index with that entry's
/// `fileUri`/`importUri` spellings, and its canonical name's root string.
/// Null when the node header does not parse.
///
/// The node header prefix (`flags`, version, canonical-name, name, file-URI
/// references) is position-stable across SDKs; only that prefix is read, so
/// appended fields never disturb the parse. Every offset is bounds-checked.
DillLibraryReference? _readLibraryNode(
  Uint8List part,
  int libCount,
  int i,
  _NameTables tables,
) {
  final bd = ByteData.sublistView(part);
  final rawIdxStart = part.length - (libCount + 12) * 4;
  final libStart = bd.getUint32(rawIdxStart + 36 + i * 4);
  final libEnd = bd.getUint32(rawIdxStart + 36 + (i + 1) * 4);
  if (libEnd < libStart || libStart > part.length || libEnd > part.length) {
    return null;
  }
  // Each node header opens with a flags byte, the version, and three
  // references — canonical name (biased), name string, source-table file URI
  // — after which only that prefix has been consumed.
  final cursor = _TableCursor(part, libEnd, libStart);
  if (!cursor.skipBytes(1)) return null; // Flags.
  if (cursor.readU30() == null) return null; // Major version.
  if (cursor.readU30() == null) return null; // Minor version.
  final canon = cursor.readU30();
  if (canon == null) return null;
  if (cursor.readU30() == null) return null; // Name string reference.
  final fileUriIndex = cursor.readU30();
  if (fileUriIndex == null) return null;
  final fileUris = tables.fileUris;
  final importUris = tables.importUris;
  final importUri = fileUriIndex >= 0 && fileUriIndex < importUris.length
      ? importUris[fileUriIndex]
      : null;
  return (
    fileUriIndex: fileUriIndex,
    fileUri: fileUriIndex >= 0 && fileUriIndex < fileUris.length
        ? fileUris[fileUriIndex]
        : null,
    importUri: importUri == null || importUri.isEmpty ? null : importUri,
    canonicalName: _canonicalRoot(canon, tables),
  );
}

/// Every top-level canonical-name string (parent index zero) recorded in the
/// `.dill` [bytes] across all components, or `null` when the tables do not
/// parse. A held component can smuggle a root the library nodes never mention —
/// a `file:` canonical root with no corresponding library node, for example —
/// so the read-set backstop checks these roots too, not just the library nodes.
/// Returns an empty list (never `null`) for a component file with no
/// libraries, mirroring [dillLibraryReferences].
List<String>? dillCanonicalRoots(Uint8List bytes) {
  final ranges = _componentRanges(bytes);
  if (ranges == null) return null;
  final roots = <String>[];
  for (final (start, end) in ranges) {
    final tables = _componentNameTables(
      Uint8List.sublistView(bytes, start, end),
    );
    if (tables == null) return null;
    for (var i = 0; i < tables.canonParents.length; i++) {
      // An unresolvable root string degrades to empty (accepted, like the
      // per-library walk's `canonicalRoot`): only a present root the inputs do
      // not define fails the check.
      if (tables.canonParents[i] == 0) {
        roots.add(tables.stringAt(tables.canonStrings[i]) ?? '');
      }
    }
  }
  return roots;
}
