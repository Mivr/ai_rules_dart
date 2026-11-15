// Kernel byte builders for `kernel_module_test`: synthetic `.dill` components
// the planner and the source-stripping tests read.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'dill_outline.dart';
import 'dill_test_writer.dart';

/// A minimal kernel component holding one class with one field, written with
/// the given [formatVersion] and [languageMajor]; [hasConstConstructor] adds
/// a const constructor.
Uint8List buildMinimalFieldDill({
  int formatVersion = Tag.BinaryFormatVersion,
  int languageMajor = 3,
  bool hasConstConstructor = true,
}) {
  final w = DillWriter();
  writeDillHeader(w, formatVersion);
  final int libStart = w.length;
  writeLibraryPrefix(w, languageMajor);
  w.u30(1); // clsCount = 1
  final int clsStart = w.length;
  _writeFieldClass(w, hasConstConstructor);
  final int clsEnd = w.length;

  w.u30s([0, 0, 0, 2]); // extCount, extTypeCount, fieldCount, pCount = 2
  final List<int> procOffsets = _writeLibraryProcedures(w);
  procOffsets.add(w.length);
  final int sourceRefsOffset = w.length;
  w.u30(0); // usedCount = 0
  w.u32s([sourceRefsOffset, clsStart, clsEnd, 1, ...procOffsets, 2]);
  final int libEnd = w.length;

  final sourceTableOffset = libEnd;
  w.u32(1); // uriCount = 1
  final int uriEntry0 = w.length;
  // uriLen, srcLen, lineCount, impLen, covCount
  w.u30s([0, 0, 0, 0, 0]);
  w.u32(uriEntry0);
  final ({int index, int table}) constants = writeEmptyConstantTable(w);
  final int linkTableOffset = writeSingleLinkTable(w);
  final int metaOffset = w.length;
  w.u32(0);
  final int stringTableOffset = writeFStringTable(w);
  writeComponentIndex(w, (
    sourceTable: sourceTableOffset,
    constantTable: constants.table,
    constantIndex: constants.index,
    linkTable: linkTableOffset,
    metaPayloads: metaOffset,
    metaMappings: metaOffset,
    stringTable: stringTableOffset,
    componentIndex: w.length,
    libStart: libStart,
    libEnd: libEnd,
  ));
  return w.toBytes();
}

/// Writes the class node with three fields and the optional const
/// constructor, through its procedure-offset trailer.
void _writeFieldClass(DillWriter w, bool hasConstConstructor) {
  w.byte(Tag.Class);
  // canonicalName, fileUri, 3 offsets, flags (not a mixin), name,
  // annotations, typeParameters
  w.u30s([1, 0, 0, 0, 0, 0, 1, 0, 0]);
  w.byte(Tag.Nothing); // supertype
  w.byte(Tag.Nothing); // mixedInType
  w.u30(0); // implementedTypes

  // 3 fields: (flags=1 final instance, val=42), (flags=5 static final,
  // val=99), (flags=0 mutable, val=77)
  w.u30(3);
  for (final (flags, val) in [(1, 42), (5, 99), (0, 77)]) {
    w.byte(Tag.Field);
    // 3 canonRefs, uriRef, 2 offsets, flags, name ("f"), scopeSize,
    // annotations
    w.u30s([1, 1, 0, 0, 0, 0, flags, 1, 0, 0]);
    w.byte(Tag.DynamicType);
    w.byte(Tag.Nothing); // option variable
    w.byte(Tag.Something); // option expression
    w.byte(Tag.PositiveIntLiteral);
    w.u30s([0, val]); // fileOffset, value
    w.byte(Tag.Nothing); // option scope
  }
  if (hasConstConstructor) {
    w.u30(1); // ctorCount = 1
    w.byte(Tag.Constructor);
    w.u30s([1, 0, 0, 0, 0]); // canonicalName, fileUri, 3 offsets
    w.byte(1); // flags = 1 (isConst)
    w.u30s([1, 0]); // name ("f"), annotations
    _writeFunctionNode(w);
    w.u30(0); // initCount
  } else {
    w.u30(0); // ctorCount = 0
  }
  w.u30(0); // pCount = 0
  final int clsProcEnd = w.length;
  w.u32(clsProcEnd);
  w.u32(0); // procCount = 0
}

/// Writes the library's two static procedures and returns their offsets.
List<int> _writeLibraryProcedures(DillWriter w) {
  final procOffsets = <int>[];
  for (final (flags, val) in [(9, 88), (1, 66)]) {
    procOffsets.add(w.length);
    w.byte(Tag.Procedure);
    w.u30s([1, 0, 0, 0, 0]); // canonicalName, fileUri, 3 offsets
    w.byte(0); // kind
    w.byte(0); // stubKind
    // flags (9 = FlagStatic | FlagConst, 1 = FlagStatic), name ("f"),
    // annotations, stubTarget
    w.u30s([flags, 1, 0, 0]);
    w.byte(Tag.Nothing); // signatureType
    _writeFunctionNode(w, returnValue: val);
  }
  return procOffsets;
}

/// Writes a parameterless function node returning dynamic; a non-null
/// [returnValue] gives it a `return <int literal>;` body, otherwise it has
/// none.
void _writeFunctionNode(DillWriter w, {int? returnValue}) {
  w.byte(Tag.FunctionNode);
  w.u30s([0, 0]); // 2 offsets
  w.byte(0); // asyncMarker
  w.byte(0); // dartAsyncMarker
  w.u30s([0, 0]); // scopeSize, typeParameters
  w.byte(Tag.Nothing); // thisVariable
  // totalParameterCount, requiredParameterCount, posCount, namedCount
  w.u30s([0, 0, 0, 0]);
  w.byte(Tag.DynamicType); // returnType
  w.byte(Tag.Nothing); // futureValueType
  w.byte(0); // rftTag
  if (returnValue == null) {
    w.byte(Tag.Nothing); // body Option<Statement>
  } else {
    w.byte(Tag.Something); // body Option<Statement>
    w.byte(Tag.ReturnStatement);
    w.u30(0); // fileOffset
    w.byte(Tag.Something); // expression
    w.byte(Tag.PositiveIntLiteral);
    w.u30s([0, returnValue]); // fileOffset, value
  }
  w.byte(Tag.Nothing); // option scope
  w.byte(Tag.Nothing); // option captured contexts
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
  final w = DillWriter();
  w.u32(dillComponentMagic);
  w.u32(formatVersion);
  w.bytes(List<int>.filled(64, 0));
  final int sourceTableOffset = writeSourceTable(w, [
    for (final uri in uris) (uri, ''),
  ]);
  final int constantTableOffset = w.length;
  w.u30(0);
  w.u32(sourceTableOffset);
  w.u32(constantTableOffset);
  for (var i = 0; i < 8; i++) {
    w.u32(constantTableOffset);
  }
  w.u32(0); // libraryCount = 0
  w.u32(w.length + 4);
  return w.toBytes();
}

/// A structurally valid kernel component whose source table holds [sources]
/// as (`fileUri`, `sourceCode`) pairs, with the text written out.
Uint8List buildDillWithSourceText(List<(String, String)> sources) {
  final w = DillWriter();
  w.u32(dillComponentMagic);
  w.u32(Tag.BinaryFormatVersion);
  w.bytes(List<int>.filled(64, 0));
  final int sourceTableOffset = writeTextSourceTable(w, sources);
  final int constantTableOffset = w.length;
  w.u30(0);
  w.u32(sourceTableOffset);
  w.u32(constantTableOffset);
  for (var i = 0; i < 8; i++) {
    w.u32(constantTableOffset);
  }
  w.u32(0); // libraryCount = 0
  w.u32(w.length + 4);
  return w.toBytes();
}

/// The (`uri`, `sourceCode`) entries of each component of [dill], last
/// component first, for components [buildDillWithSourceText] wrote (no
/// library nodes, so the source table offset is the 12th word from the end).
List<List<(String, String)>> readSourceTexts(Uint8List dill) {
  final bd = ByteData.sublistView(dill);
  final tables = <List<(String, String)>>[];
  int end = dill.length;
  while (end > 0) {
    final int start = end - bd.getUint32(end - 4);
    tables.add(_readTextEntries(dill, start + bd.getUint32(end - 48)));
    end = start;
  }
  return tables;
}

List<(String, String)> _readTextEntries(Uint8List d, int offset) {
  int pos = offset + 4;
  int u30() {
    final int b0 = d[pos++];
    if ((b0 & 0x80) == 0) return b0;
    if ((b0 & 0x40) == 0) return ((b0 & 0x3f) << 8) | d[pos++];
    final int b1 = d[pos++];
    final int b2 = d[pos++];
    final int b3 = d[pos++];
    return ((b0 & 0x3f) << 24) | (b1 << 16) | (b2 << 8) | b3;
  }

  String str() {
    final int n = u30();
    final String s = utf8.decode(d.sublist(pos, pos + n));
    pos += n;
    return s;
  }

  final int count = ByteData.sublistView(d).getUint32(offset);
  final entries = <(String, String)>[];
  for (var i = 0; i < count; i++) {
    final String uri = str();
    entries.add((uri, str()));
    for (int j = u30(); j > 0; j--) {
      u30();
    }
    str();
    for (int j = u30(); j > 0; j--) {
      u30();
    }
  }
  return entries;
}

/// A structurally valid kernel component whose source table holds [sources]
/// as (`fileUri`, `importUri`) pairs and whose library table holds one node
/// per entry of [libraries]; see [buildLibraryTableDill].
Uint8List buildDillWithLibraries({
  required List<(String, String)> sources,
  required List<(int, String?)> libraries,
  int formatVersion = Tag.BinaryFormatVersion,
  List<String> extraRoots = const [],
}) => buildLibraryTableDill(
  formatVersion: formatVersion,
  sources: sources,
  libraries: libraries,
  extraRoots: extraRoots,
);

/// A minimal kernel component whose one source holds [srcLen] bytes of source
/// text and whose metadata payload offsets follow it.
Uint8List buildMinimalDillWithSourceAndMetadata({required int srcLen}) {
  final w = DillWriter();
  writeDillHeader(w, Tag.BinaryFormatVersion);
  final int libStart = w.length;
  writeLibraryPrefix(w, 3);
  // clsCount, extCount, extTypeCount, fieldCount, pCount
  w.u30s([0, 0, 0, 0, 0]);
  final int sourceRefsOffset = w.length;
  w.u30(0); // usedCount
  // clsOffsets[0], classCount, procOffsets[0], procCount
  w.u32s([sourceRefsOffset, libStart + 13, 0, sourceRefsOffset, 0]);
  final int libEnd = w.length;

  final sourceTableOffset = libEnd;
  _writeOneSourceTable(w, srcLen);
  final ({int index, int table}) constants = writeEmptyConstantTable(w);
  final int linkTableOffset = writeSingleLinkTable(w);

  final int metaPad = (8 - (w.length % 8)) % 8;
  if (metaPad > 0) w.bytes(Uint8List(metaPad));
  final int metadataPayloadsOffset = w.length;
  w.bytes([0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe]);
  final int metadataMappingsOffset = w.length;
  w.bytes([0x11, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00, 0x01]);

  final int stringTableOffset = writeFStringTable(w);
  final int componentIndexOffset = w.length;
  const int idxBytes = 13 * 4;
  final int pad = (8 - ((w.length + idxBytes) % 8)) % 8;
  if (pad > 0) w.bytes(Uint8List(pad));
  writeComponentIndex(w, (
    sourceTable: sourceTableOffset,
    constantTable: constants.table,
    constantIndex: constants.index,
    linkTable: linkTableOffset,
    metaPayloads: metadataPayloadsOffset,
    metaMappings: metadataMappingsOffset,
    stringTable: stringTableOffset,
    componentIndex: componentIndexOffset,
    libStart: libStart,
    libEnd: libEnd,
  ));
  return w.toBytes();
}

/// Writes a source table with one source of [srcLen] bytes of text.
void _writeOneSourceTable(DillWriter w, int srcLen) {
  w.u32(1); // numSources = 1
  final int uriEntry0 = w.length;
  w.u30(5); // uriLen = 5 ("a.dart" prefix)
  w.bytes([97, 46, 100, 97, 114]);
  w.u30(srcLen);
  w.bytes(List<int>.filled(srcLen, 0x61));
  w.u30s([2, 0, 1]); // lineCount = 2, line starts
  w.u30(5); // importUri len = 5
  w.bytes([97, 46, 100, 97, 114]);
  w.u30(0); // constantCoverageConstructors
  w.u32(uriEntry0);
}

/// A fake persistent `kernel_worker` (a Dart source run by the SDK `dart`): it
/// answers every request with exit code 1 and the output `boom` when
/// `FAKE_WORKER_FAIL=1`, and otherwise copies the file `FAKE_WORKER_DILL`
/// names to the request's `--output` and succeeds.
const fakeKernelWorkerSource = r"""
import 'dart:convert';
import 'dart:io';

/// The varint at [pos] of [bytes] and the position after it, or null when
/// the bytes end inside it.
(int, int)? varintAt(List<int> bytes, int pos) {
  var value = 0;
  var shift = 0;
  while (pos < bytes.length) {
    final int b = bytes[pos++];
    value |= (b & 0x7f) << shift;
    shift += 7;
    if (b < 0x80) return (value, pos);
  }
  return null;
}

/// The `arguments` (field 1) of a `WorkRequest` payload.
List<String> argumentsOf(List<int> payload) {
  final args = <String>[];
  var pos = 0;
  while (pos < payload.length) {
    final (int tag, int afterTag) = varintAt(payload, pos)!;
    pos = afterTag;
    if (tag & 7 == 2) {
      final (int len, int start) = varintAt(payload, pos)!;
      if (tag >> 3 == 1) {
        args.add(utf8.decode(payload.sublist(start, start + len)));
      }
      pos = start + len;
    } else {
      pos = varintAt(payload, pos)!.$2;
    }
  }
  return args;
}

Future<void> main() async {
  final fail = Platform.environment['FAKE_WORKER_FAIL'] == '1';
  final buf = <int>[];
  await for (final List<int> chunk in stdin) {
    buf.addAll(chunk);
    while (true) {
      final (int, int)? head = varintAt(buf, 0);
      if (head == null || buf.length < head.$2 + head.$1) break;
      final List<String> args = argumentsOf(
        buf.sublist(head.$2, head.$2 + head.$1),
      );
      buf.removeRange(0, head.$2 + head.$1);
      final List<int> reply;
      if (fail) {
        reply = [0x08, 1, 0x12, 4, ...utf8.encode('boom')];
      } else {
        final String out = args[args.indexOf('--output') + 1];
        File(out).parent.createSync(recursive: true);
        File(Platform.environment['FAKE_WORKER_DILL']!).copySync(out);
        reply = const [];
      }
      stdout.add([reply.length, ...reply]);
      await stdout.flush();
    }
  }
}
""";

/// The tool's `kernel_module` AOT snapshot running as a persistent worker over
/// the fake `kernel_worker`, driven one framed request at a time.
class FakeWorkerTool {
  late final Process _process;
  late final StreamIterator<List<int>> _stdout;
  final _buffer = <int>[];
  final _stderr = StringBuffer();
  Future<void>? _stderrDone;

  /// The tool's process id, the `worker_pid` of its log lines.
  int get pid => _process.pid;

  /// Starts [snapshot] with `--persistent_worker`, the fake worker source at
  /// [fakeWorker] run by [dart], and [extraFlags] as startup flags.
  static Future<FakeWorkerTool> start({
    required String snapshot,
    required String dart,
    required String fakeWorker,
    required Map<String, String> environment,
    List<String> extraFlags = const [],
  }) async {
    final Process process = await Process.start(
      '${File(dart).parent.path}/dartaotruntime'
      '${Platform.isWindows ? '.exe' : ''}',
      [
        snapshot,
        '--persistent_worker',
        '--kernel-worker',
        fakeWorker,
        '--dartaotruntime',
        dart,
        ...extraFlags,
      ],
      environment: environment,
      includeParentEnvironment: false,
    );
    final tool = FakeWorkerTool()
      .._process = process
      .._stdout = StreamIterator<List<int>>(process.stdout);
    tool._stderrDone = process.stderr
        .transform(const SystemEncoding().decoder)
        .forEach(tool._stderr.write);
    return tool;
  }

  /// Sends one request with [arguments] and returns the `WorkResponse` bytes.
  Future<Uint8List> request(List<String> arguments) async {
    final payload = <int>[];
    for (final argument in arguments) {
      final List<int> bytes = utf8.encode(argument);
      payload.addAll([0x0a, ..._varint(bytes.length), ...bytes]);
    }
    _process.stdin.add([..._varint(payload.length), ...payload]);
    await _process.stdin.flush();
    while (true) {
      var length = 0;
      var shift = 0;
      var pos = 0;
      while (pos < _buffer.length) {
        final int b = _buffer[pos++];
        length |= (b & 0x7f) << shift;
        shift += 7;
        if (b < 0x80) break;
      }
      if (pos > 0 &&
          pos <= _buffer.length &&
          _buffer[pos - 1] < 0x80 &&
          _buffer.length >= pos + length) {
        final response = Uint8List.fromList(_buffer.sublist(pos, pos + length));
        _buffer.removeRange(0, pos + length);
        return response;
      }
      if (!await _stdout.moveNext()) {
        throw StateError('worker stdout ended before a response');
      }
      _buffer.addAll(_stdout.current);
    }
  }

  /// The protobuf varint of the non-negative [value].
  static List<int> _varint(int value) {
    final out = <int>[];
    var rest = value;
    while (rest >= 0x80) {
      out.add((rest & 0x7f) | 0x80);
      rest >>= 7;
    }
    return [...out, rest];
  }

  /// Closes the tool's stdin, waits for it to exit, and returns its stderr.
  Future<String> finish() async {
    await _process.stdin.close();
    final int code = await _process.exitCode;
    await _stderrDone;
    if (code != 0) throw StateError('kernel_module exited with $code');
    return _stderr.toString();
  }
}
