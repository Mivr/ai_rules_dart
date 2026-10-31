// Shared protobuf encoders for persistent-worker request framing in unit tests.
import 'dart:convert';
import 'dart:typed_data';

/// Encodes a non-negative integer as a protobuf varint.
Uint8List encodeVarintForTest(int value) {
  final out = BytesBuilder();
  var remaining = value;
  while (remaining >= 0x80) {
    out.addByte((remaining & 0x7f) | 0x80);
    remaining >>= 7;
  }
  out.addByte(remaining);
  return out.toBytes();
}

/// Encodes one `blaze.worker.Input` submessage (`path` and optional `digest`).
Uint8List encodeInputForTest(String path, Uint8List digest) {
  final out = BytesBuilder();
  final pathBytes = utf8.encode(path);
  out.add(encodeVarintForTest((1 << 3) | 2));
  out.add(encodeVarintForTest(pathBytes.length));
  out.add(pathBytes);
  if (digest.isNotEmpty) {
    out.add(encodeVarintForTest((2 << 3) | 2));
    out.add(encodeVarintForTest(digest.length));
    out.add(digest);
  }
  return out.toBytes();
}

/// Encodes a `blaze.worker.WorkRequest` protobuf payload for worker tests.
Uint8List encodeWorkRequestForTest({
  required List<String> arguments,
  required Map<String, Uint8List> inputs,
}) {
  final out = BytesBuilder();
  for (final arg in arguments) {
    final argBytes = utf8.encode(arg);
    out.add(encodeVarintForTest((1 << 3) | 2));
    out.add(encodeVarintForTest(argBytes.length));
    out.add(argBytes);
  }
  for (final entry in inputs.entries) {
    final inputBytes = encodeInputForTest(entry.key, entry.value);
    out.add(encodeVarintForTest((2 << 3) | 2));
    out.add(encodeVarintForTest(inputBytes.length));
    out.add(inputBytes);
  }
  return out.toBytes();
}
