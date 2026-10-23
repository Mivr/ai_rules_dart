// Shared persistent-worker protocol and path plumbing for the build-action
// runners under `dart/private/tools`.
//
// `analyzer_summary`, `format_runner`, and `kernel_link` each ran Bazel's
// `--persistent_worker` binary protobuf protocol over stdin/stdout with their
// own copy of the framing, request/response codec, and `@param_file`
// expansion; `web_compile_runner` shared the expansion too, and
// `kernel_module` shared the path normalization and SHA-256. This library
// holds the single copy. `kernel_module` compiles it through `srcs` (it takes
// no `dart_library` dependency on purpose), `web_compile_runner` depends on
// the `worker_protocol` target below, and `analyzer_summary` and
// `format_runner` depend on it alongside the `worker_tool_fs` target.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Expands `@param_file` arguments (multiline format, one argument per line).
///
/// When [skipEmptyLines] is set, blank lines in the file are dropped;
/// otherwise every line becomes an argument. When [keepMissingArg] is set, a
/// `@path` naming a file that does not exist is kept as-is (and a bare `@`
/// is never treated as a reference); otherwise the file is read
/// unconditionally, so a missing file throws a [FileSystemException].
List<String> expandParamFiles(
  List<String> args, {
  bool skipEmptyLines = false,
  bool keepMissingArg = false,
}) {
  final expanded = <String>[];
  for (final arg in args) {
    if (arg.startsWith('@') && (!keepMissingArg || arg.length > 1)) {
      final file = File(arg.substring(1));
      if (keepMissingArg && !file.existsSync()) {
        expanded.add(arg);
        continue;
      }
      for (final line in file.readAsLinesSync()) {
        if (!skipEmptyLines || line.isNotEmpty) {
          expanded.add(line);
        }
      }
      continue;
    }
    expanded.add(arg);
  }
  return expanded;
}

/// Whether [path] is already a normalized relative path: nonempty, without a
/// Windows drive letter, a backslash, an empty segment, or a `.`/`..`
/// segment.
bool _isNormalizedRelative(String path) {
  final len = path.length;
  if (len == 0) return false;
  if (_isWindowsDrivePath(path)) return false;
  var segStart = 0;
  for (var i = 0; i <= len; i++) {
    final c = i < len ? path.codeUnitAt(i) : 0x2f;
    if (c == 0x5c) return false;
    if (c == 0x2f) {
      final segLen = i - segStart;
      if (segLen == 0) return false;
      if (segLen == 1 && path.codeUnitAt(segStart) == 0x2e) return false;
      if (segLen == 2 &&
          path.codeUnitAt(segStart) == 0x2e &&
          path.codeUnitAt(segStart + 1) == 0x2e) {
        return false;
      }
      segStart = i + 1;
    }
  }
  return true;
}

bool _isAsciiAlpha(int c) =>
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);

bool _isWindowsDrivePath(String s) =>
    s.length >= 2 &&
    _isAsciiAlpha(s.codeUnitAt(0)) &&
    s.codeUnitAt(1) == 0x3a &&
    (s.length == 2 || s.codeUnitAt(2) == 0x2f || s.codeUnitAt(2) == 0x5c);

/// Normalizes [path] to `/`-separated form, resolving `.`/`..` segments and
/// keeping a Windows drive prefix (`C:/...`) when present.
String normalizePath(String path) {
  if (_isNormalizedRelative(path)) return path;
  if (path.isEmpty) return '.';
  final slashPath = path.contains(r'\') ? path.replaceAll(r'\', '/') : path;
  String? drivePrefix;
  var rest = slashPath;
  if (_isWindowsDrivePath(slashPath)) {
    drivePrefix = '${slashPath.substring(0, 2)}/';
    rest = slashPath.substring(2);
  }
  final isAbs = drivePrefix != null || rest.startsWith('/');
  final parts = rest.split('/');
  final stack = <String>[];
  for (final part in parts) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (stack.isNotEmpty && stack.last != '..') {
        stack.removeLast();
      } else if (!isAbs) {
        stack.add('..');
      }
    } else {
      stack.add(part);
    }
  }
  if (stack.isEmpty) return drivePrefix ?? (isAbs ? '/' : '.');
  final joined = stack.join('/');
  if (drivePrefix != null) return '$drivePrefix$joined';
  return isAbs ? '/$joined' : joined;
}

/// The SHA-256 digest of `message`, as 32 bytes.
Uint8List sha256Of(Uint8List message) {
  final h = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  final paddedLength = ((message.length + 9 + 63) ~/ 64) * 64;
  final padded = Uint8List(paddedLength)..setRange(0, message.length, message);
  padded[message.length] = 0x80;
  final bits = message.length * 8;
  final view = ByteData.sublistView(padded);
  view.setUint32(paddedLength - 8, bits ~/ 0x100000000);
  view.setUint32(paddedLength - 4, bits & 0xffffffff);

  final w = List<int>.filled(64, 0);
  for (var block = 0; block < paddedLength; block += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = view.getUint32(block + i * 4);
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e) & g);
      final t1 = (hh + s1 + ch + _sha256K[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    h[0] = (h[0] + a) & 0xffffffff;
    h[1] = (h[1] + b) & 0xffffffff;
    h[2] = (h[2] + c) & 0xffffffff;
    h[3] = (h[3] + d) & 0xffffffff;
    h[4] = (h[4] + e) & 0xffffffff;
    h[5] = (h[5] + f) & 0xffffffff;
    h[6] = (h[6] + g) & 0xffffffff;
    h[7] = (h[7] + hh) & 0xffffffff;
  }
  final out = ByteData(32);
  for (var i = 0; i < 8; i++) {
    out.setUint32(i * 4, h[i]);
  }
  return out.buffer.asUint8List();
}

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

const _sha256K = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

// ---------------------------------------------------------------------------
// Bazel worker protocol (`blaze.worker.WorkRequest` / `WorkResponse`)
// ---------------------------------------------------------------------------

/// One Bazel persistent-worker request: the command-line arguments, the
/// input digests Bazel sent, the request id to answer, and whether Bazel
/// cancelled the request (cancelled requests get no response).
final class WorkerRequest {
  const WorkerRequest({
    required this.arguments,
    required this.inputs,
    required this.requestId,
    required this.cancel,
  });

  /// Decodes a raw `WorkRequest` protobuf payload. When [copyDigests] is set
  /// (the default), each input digest is copied out of [bytes] so the decoded
  /// request does not pin the request buffer; otherwise digests view it.
  factory WorkerRequest.read(Uint8List bytes, {bool copyDigests = true}) {
    final arguments = <String>[];
    final inputs = <String, Uint8List>{};
    var requestId = 0;
    var cancel = false;
    final r = WorkerReader(bytes);
    while (!r.isDone) {
      final tag = r.varint();
      switch (tag >> 3) {
        case 1:
          arguments.add(r.string());
        case 2:
          final nested = r.submessage();
          var path = '';
          var digest = Uint8List(0);
          while (!nested.isDone) {
            final inputTag = nested.varint();
            switch (inputTag >> 3) {
              case 1:
                path = nested.string();
              case 2:
                final raw = nested.bytes();
                digest = copyDigests ? Uint8List.fromList(raw) : raw;
              default:
                nested.skip(inputTag & 7);
            }
          }
          if (path.isNotEmpty) {
            inputs[path] = digest;
          }
        case 3:
          requestId = r.varint();
        case 4:
          cancel = r.varint() != 0;
        default:
          r.skip(tag & 7);
      }
    }
    return WorkerRequest(
      arguments: arguments,
      inputs: inputs,
      requestId: requestId,
      cancel: cancel,
    );
  }

  final List<String> arguments;
  final Map<String, Uint8List> inputs;
  final int requestId;
  final bool cancel;
}

/// One Bazel persistent-worker response: the exit code, the combined output,
/// and the id of the request it answers.
final class WorkerResponse {
  const WorkerResponse({
    required this.exitCode,
    required this.output,
    required this.requestId,
  });

  final int exitCode;
  final String output;
  final int requestId;

  /// Encodes the response as a length-prefixed `WorkResponse` protobuf frame.
  Uint8List write() {
    final body = WorkerWriter();
    if (exitCode != 0) {
      body
        ..varint((1 << 3) | 0)
        ..varint(exitCode);
    }
    if (output.isNotEmpty) {
      final utf8Bytes = utf8.encode(output);
      body
        ..varint((2 << 3) | 2)
        ..varint(utf8Bytes.length)
        ..raw(utf8Bytes);
    }
    if (requestId != 0) {
      body
        ..varint((3 << 3) | 0)
        ..varint(requestId);
    }
    final payload = body.takeBytes();
    final frame = WorkerWriter()
      ..varint(payload.length)
      ..raw(payload);
    return frame.takeBytes();
  }
}

/// The length-prefixed protobuf frames arriving on the worker's stdin as a
/// byte stream: each emitted item is one complete frame.
final class WorkerFrames extends Stream<Uint8List> {
  WorkerFrames(this._source);

  final Stream<List<int>> _source;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final controller = StreamController<Uint8List>();
    var buf = Uint8List(0);
    late final StreamSubscription<List<int>> sub;
    sub = _source.listen(
      (chunk) {
        final merged = Uint8List(buf.length + chunk.length);
        merged.setRange(0, buf.length, buf);
        merged.setRange(buf.length, merged.length, chunk);
        buf = merged;
        while (true) {
          var len = 0;
          var shift = 0;
          var pos = 0;
          while (true) {
            if (pos >= buf.length) return;
            final b = buf[pos++];
            len |= (b & 0x7f) << shift;
            if ((b & 0x80) == 0) break;
            shift += 7;
          }
          if (buf.length < pos + len) return;
          final frame = Uint8List.fromList(
            Uint8List.sublistView(buf, pos, pos + len),
          );
          final nextStart = pos + len;
          buf = nextStart == buf.length
              ? Uint8List(0)
              : Uint8List.fromList(Uint8List.sublistView(buf, nextStart));
          controller.add(frame);
        }
      },
      onError: controller.addError,
      onDone: controller.close,
      cancelOnError: cancelOnError,
    );
    controller
      ..onPause = sub.pause
      ..onResume = sub.resume
      ..onCancel = sub.cancel;
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

/// A protobuf reader over a byte buffer.
final class WorkerReader {
  WorkerReader(this._buf);

  final Uint8List _buf;
  int _pos = 0;

  bool get isDone => _pos >= _buf.length;

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = _buf[_pos++];
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
    }
  }

  Uint8List bytes() {
    final len = varint();
    final slice = Uint8List.sublistView(_buf, _pos, _pos + len);
    _pos += len;
    return slice;
  }

  String string() => utf8.decode(bytes());

  WorkerReader submessage() => WorkerReader(bytes());

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        varint();
      case 1:
        _pos += 8;
      case 2:
        final length = varint();
        _pos += length;
      case 5:
        _pos += 4;
      default:
        throw FormatException('unsupported wire type: $wireType');
    }
  }
}

/// A protobuf writer accumulating a byte buffer.
final class WorkerWriter {
  final _buf = BytesBuilder(copy: false);

  void varint(int value) {
    var v = value;
    while (v < 0 || v >= 0x80) {
      _buf.addByte((v & 0x7f) | 0x80);
      v = v >>> 7;
    }
    _buf.addByte(v);
  }

  void raw(List<int> bytes) => _buf.add(bytes);

  Uint8List takeBytes() => _buf.takeBytes();
}
