// Tests the `kernel_link` persistent worker's top-level error handler: a
// request that fails before linking still gets an answered response, and the
// error is also written to stderr (Bazel keeps worker stderr in the worker
// log).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

late String _toolDillPath;
late String _dartBin;
late Directory _tmp;

void main(List<String> args) {
  final r = Runfiles.create();
  if (args.length >= 2) {
    _toolDillPath = r.rlocation(args[0]);
    _dartBin = r.rlocation(args[1]);
  } else {
    _toolDillPath = '';
    _dartBin = Platform.resolvedExecutable;
  }

  setUp(() {
    _tmp = Directory.systemTemp.createTempSync('kernel_link_test.');
  });

  tearDown(() {
    _tmp.deleteSync(recursive: true);
  });

  test(
    'persistent worker answers a failing request and logs to stderr',
    () async {
      if (_toolDillPath.isEmpty) return;
      final proc = await Process.start(_dartBin, [
        _toolDillPath,
        '--persistent_worker',
      ]);
      final stderrFuture = proc.stderr.transform(utf8.decoder).join();
      // A `@`-file that does not exist: param expansion throws before any
      // linking runs, exercising the worker's top-level handler.
      proc.stdin.add(
        _requestFrameForTest(['@${_tmp.path}/no-such-param-file.txt'], 5),
      );
      await proc.stdin.flush();
      final (code, output, requestId) = await _readResponseForTest(proc.stdout)
          .timeout(const Duration(minutes: 2));
      expect(requestId, 5);
      expect(code, 1);
      expect(output, contains('unhandled exception'));
      await proc.stdin.close();
      expect(await proc.exitCode, 0);
      expect(await stderrFuture, contains('unhandled exception'));
    },
  );
}

void _writeVarintForTest(BytesBuilder out, int value) {
  var rest = value;
  while (rest >= 0x80) {
    out.addByte((rest & 0x7f) | 0x80);
    rest >>= 7;
  }
  out.addByte(rest);
}

/// One framed `WorkRequest` carrying [arguments] as request [requestId].
Uint8List _requestFrameForTest(List<String> arguments, int requestId) {
  final message = BytesBuilder();
  for (final argument in arguments) {
    message.addByte(0x0a);
    final bytes = utf8.encode(argument);
    _writeVarintForTest(message, bytes.length);
    message.add(bytes);
  }
  message.addByte(0x18);
  _writeVarintForTest(message, requestId);
  final frame = BytesBuilder();
  final payload = message.toBytes();
  _writeVarintForTest(frame, payload.length);
  frame.add(payload);
  return frame.toBytes();
}

/// Reads one framed `WorkResponse` as (exit code, output, request id).
Future<(int, String, int)> _readResponseForTest(
  Stream<List<int>> source,
) async {
  final buf = <int>[];
  var pos = 0;
  final it = StreamIterator<List<int>>(source);
  Future<int> byte() async {
    while (pos >= buf.length) {
      if (!await it.moveNext()) {
        throw StateError('worker stdout ended mid-response');
      }
      buf.addAll(it.current);
    }
    return buf[pos++];
  }

  Future<int> varint() async {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = await byte();
      result |= (b & 0x7f) << shift;
      if (b < 0x80) return result;
      shift += 7;
    }
  }

  Future<Uint8List> bytes(int n) async {
    final out = <int>[];
    while (out.length < n) {
      out.add(await byte());
    }
    return Uint8List.fromList(out);
  }

  final payload = await bytes(await varint());
  var exitCode = 0;
  var output = '';
  var requestId = 0;
  var p = 0;
  int v() {
    var r = 0;
    var s = 0;
    while (true) {
      final b = payload[p++];
      r |= (b & 0x7f) << s;
      if (b < 0x80) return r;
      s += 7;
    }
  }

  while (p < payload.length) {
    switch (v()) {
      case 0x08:
        exitCode = v();
      case 0x12:
        final n = v();
        output = utf8.decode(payload.sublist(p, p + n));
        p += n;
      case 0x18:
        requestId = v();
      default:
        throw StateError('unexpected WorkResponse field');
    }
  }
  return (exitCode, output, requestId);
}
