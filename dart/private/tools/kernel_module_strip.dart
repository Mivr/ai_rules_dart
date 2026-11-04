// Strips the embedded source text from a compiled Kernel `.dill` (see
// [stripSourceCodeFromDill]). Split out of `kernel_module.dart`, which
// re-exports it, so the module planner stays smaller.

import 'dart:io';
import 'dart:typed_data';

import 'dill_outline.dart';

/// Strips `Source.sourceCode` UTF-8 bytes from a compiled Kernel `.dill` while
/// preserving `uri`, `lineStarts`, `importUri`, and `constantCoverageConstructors`.
///
/// `kernel_worker` has no `--no-embed-sources` flag, so it embeds the full source
/// text of every `.dart` file in each module `.dill`'s `SourceTable` (~55% of all
/// `.dill` bytes). The VM uses `lineStarts` (not `sourceCode`) for stack traces and
/// `SourceReport` coverage, and downstream `--input-linked` compiles read only
/// library outlines.
///
/// Format guard: reads the 32-bit kernel format version at byte offset 4 of the
/// header and accepts only [supportedKernelFormatVersions] (version 138, Dart
/// 3.13.x). On any other format version, writes a diagnostic to [errSink]
/// (defaulting to [stderr]) and falls back to returning [data] unstripped,
/// never emitting a malformed `.dill`.
Uint8List stripSourceCodeFromDill(Uint8List data, {StringSink? errSink}) {
  final StringSink sink = errSink ?? stderr;
  if (data.length < 8) return data;
  final bd = ByteData.sublistView(data);
  if (bd.getUint32(0) != Tag.ComponentFile) return data;
  final int version = bd.getUint32(4);
  if (!supportedKernelFormatVersions.contains(version)) {
    sink.writeln(
      'kernel_module: unsupported kernel format version $version '
      '(supported: $supportedKernelFormatVersions); '
      'falling back to unstripped dill.',
    );
    return data;
  }
  if (data.length < 48) return data;
  final int lastSize = bd.getUint32(data.length - 4);
  if (lastSize == data.length) {
    return _stripSingleComponentSourceCode(data, sink);
  }
  final ranges = <(int, int)>[];
  int end = data.length;
  while (end >= 48) {
    final int compSize = bd.getUint32(end - 4);
    if (compSize < 48 || compSize > end) return data;
    final int start = end - compSize;
    if (bd.getUint32(start) != Tag.ComponentFile) return data;
    final int compVersion = bd.getUint32(start + 4);
    if (!supportedKernelFormatVersions.contains(compVersion)) {
      sink.writeln(
        'kernel_module: unsupported kernel format version $compVersion '
        '(supported: $supportedKernelFormatVersions); '
        'falling back to unstripped dill.',
      );
      return data;
    }
    ranges.add((start, end));
    end = start;
  }
  if (end != 0 || ranges.isEmpty) return data;
  final out = BytesBuilder(copy: false);
  for (int i = ranges.length - 1; i >= 0; i--) {
    final (int s, int e) = ranges[i];
    out.add(
      _stripSingleComponentSourceCode(Uint8List.sublistView(data, s, e), sink),
    );
  }
  return out.takeBytes();
}

Uint8List _stripSingleComponentSourceCode(Uint8List data, StringSink sink) {
  final _StripIndex? index = _parseStripIndex(data);
  if (index == null) return data;
  final int numSources = ByteData.sublistView(data)
      .getUint32(index.offSourceTable);
  if (numSources == 0) return data;
  final ({Uint8List bytes, int replacedLength}) rebuilt = _rebuildSourceTable(
    data,
    index.offSourceTable,
    index.offConstantTable,
    numSources,
  );
  final int delta = rebuilt.bytes.length - rebuilt.replacedLength;
  if (delta == 0) return data;
  final int linkTableEnd = _linkTableEnd(
    data,
    index.offLinkTable,
    index.offMetadataPayloads,
  );
  return _reassembleStripped(data, index, rebuilt.bytes, delta, linkTableEnd);
}

/// A single component's table layout for source stripping.
typedef _StripIndex = ({
  List<int> fields,
  int idxCount,
  int idxBytes,
  int offSourceTable,
  int offConstantTable,
  int offLinkTable,
  int offMetadataPayloads,
  int offComponentIndex,
});

/// Reads and validates the component index, or null when it is inconsistent.
_StripIndex? _parseStripIndex(Uint8List data) {
  final bd = ByteData.sublistView(data);
  final int libCount = bd.getUint32(data.length - 8);
  final int idxCount = libCount + 12;
  final int idxBytes = idxCount * 4;
  if (idxBytes > data.length) return null;
  final int rawIdxStart = data.length - idxBytes;

  final fields = List<int>.generate(
    idxCount,
    (i) => bd.getUint32(rawIdxStart + i * 4),
  );
  final int offSourceTable = fields[0];
  final int offConstantTable = fields[1];
  final int offLinkTable = fields[3];
  final int offMetadataPayloads = fields[4];
  final int offMetadataMappings = fields[5];
  final int offStringTable = fields[6];
  final int offComponentIndex = fields[7];
  if (offSourceTable + 4 > offConstantTable ||
      offConstantTable > offLinkTable ||
      offLinkTable > offMetadataPayloads ||
      offMetadataPayloads > offMetadataMappings ||
      offMetadataMappings > offStringTable ||
      offStringTable > offComponentIndex ||
      offComponentIndex > rawIdxStart) {
    return null;
  }
  return (
    fields: fields,
    idxCount: idxCount,
    idxBytes: idxBytes,
    offSourceTable: offSourceTable,
    offConstantTable: offConstantTable,
    offLinkTable: offLinkTable,
    offMetadataPayloads: offMetadataPayloads,
    offComponentIndex: offComponentIndex,
  );
}

/// Reads kernel UInt30 values from a component's bytes, tracking the offset.
/// The source-table rewriter and the link-table scanner read the same
/// encoding over trusted offsets (both fail closed before reading), so one
/// cursor serves both.
final class _U30Reader {
  new(this._data, int position) : _pos = position;

  final Uint8List _data;
  int _pos;

  /// The current offset in [_data].
  int get position => _pos;

  /// Advances past [count] bytes.
  void skip(int count) {
    _pos += count;
  }

  /// The next UInt30 value.
  int read() {
    final int b0 = _data[_pos++];
    if ((b0 & 0x80) == 0) return b0;
    if ((b0 & 0x40) == 0) {
      return ((b0 & 0x3f) << 8) | _data[_pos++];
    }
    final int b1 = _data[_pos++];
    final int b2 = _data[_pos++];
    final int b3 = _data[_pos++];
    return ((b0 & 0x3f) << 24) | (b1 << 16) | (b2 << 8) | b3;
  }
}

/// Rewrites the source table with every source body emptied, returning the new
/// table and the length of the table it replaces.
({Uint8List bytes, int replacedLength}) _rebuildSourceTable(
  Uint8List data,
  int offSourceTable,
  int offConstantTable,
  int numSources,
) {
  final u30 = _U30Reader(data, offSourceTable + 4);

  final newSt = BytesBuilder(copy: false);
  final header4 = ByteData(4)..setUint32(0, numSources);
  newSt.add(header4.buffer.asUint8List());
  final newSourceOffsets = List<int>.filled(numSources, 0);

  for (var i = 0; i < numSources; i++) {
    newSourceOffsets[i] = offSourceTable + newSt.length;

    // 1. uri: UInt30 byteLength + UTF-8 bytes
    final int uStart = u30.position;
    final int uLen = u30.read();
    u30.skip(uLen);
    newSt.add(Uint8List.sublistView(data, uStart, u30.position));

    // 2. sourceCode: UInt30 byteLength + UTF-8 bytes -> replace with empty (0x00)
    final int sLen = u30.read();
    u30.skip(sLen);
    newSt.addByte(0);

    // 3. lineStarts: UInt30 count + count * UInt30 delta
    final int lsStart = u30.position;
    final int lineCount = u30.read();
    for (var j = 0; j < lineCount; j++) {
      u30.read();
    }
    // 4. importUri: UInt30 byteLength + UTF-8 bytes
    final int iuLen = u30.read();
    u30.skip(iuLen);
    // 5. constantCoverageConstructors: UInt30 count + count * UInt30
    final int ccCount = u30.read();
    for (var j = 0; j < ccCount; j++) {
      u30.read();
    }
    newSt.add(Uint8List.sublistView(data, lsStart, u30.position));
  }

  final offsetsBuf = ByteData(numSources * 4);
  for (var i = 0; i < numSources; i++) {
    offsetsBuf.setUint32(i * 4, newSourceOffsets[i]);
  }
  newSt.add(offsetsBuf.buffer.asUint8List());

  return (
    bytes: newSt.takeBytes(),
    replacedLength: offConstantTable - offSourceTable,
  );
}

/// The end of the link table's canonical entries, clamped to the metadata.
int _linkTableEnd(Uint8List data, int offLinkTable, int offMetadataPayloads) {
  final u30 = _U30Reader(data, offLinkTable);

  final int canonCount = u30.read();
  for (var i = 0; i < canonCount; i++) {
    u30.read();
    u30.read();
  }
  return u30.position <= offMetadataPayloads
      ? u30.position
      : offMetadataPayloads;
}

/// Splices the rewritten source table back into the component, realigning the
/// metadata payloads and rewriting the component index.
Uint8List _reassembleStripped(
  Uint8List data,
  _StripIndex index,
  Uint8List newStBytes,
  int delta,
  int linkTableEnd,
) {
  final List<int> fields = index.fields;
  final out = BytesBuilder(copy: false);
  out.add(Uint8List.sublistView(data, 0, index.offSourceTable));
  out.add(newStBytes);
  out.add(Uint8List.sublistView(data, index.offConstantTable, linkTableEnd));

  // Kernel requires binaryOffsetForMetadataPayloads (fields[4]) to be 8-byte
  // aligned (ComponentFile.metadataPayloadsAlignment = 8).
  final int metaPad = (8 - (out.length % 8)) % 8;
  if (metaPad > 0) {
    out.add(Uint8List(metaPad));
  }
  final int newOffMetadataPayloads = out.length;
  final int metaDelta = newOffMetadataPayloads - index.offMetadataPayloads;

  out.add(
    Uint8List.sublistView(
      data,
      index.offMetadataPayloads,
      index.offComponentIndex,
    ),
  );

  final int newOffComponentIndex = out.length;
  final int totalUnpadded = out.length + index.idxBytes;
  final int pad = (8 - (totalUnpadded % 8)) % 8;
  if (pad > 0) {
    out.add(Uint8List(pad));
  }

  for (var i = 1; i <= 3; i++) {
    fields[i] += delta;
  }
  for (var i = 4; i <= 6; i++) {
    fields[i] += metaDelta;
  }
  fields[7] = newOffComponentIndex;
  fields[index.idxCount - 1] = out.length + index.idxBytes;

  final idxBuf = ByteData(index.idxBytes);
  for (var i = 0; i < index.idxCount; i++) {
    idxBuf.setUint32(i * 4, fields[i]);
  }
  out.add(idxBuf.buffer.asUint8List());
  return out.takeBytes();
}
