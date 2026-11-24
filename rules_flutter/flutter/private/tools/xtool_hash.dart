/// SHA digest helpers for the Apple bundling tools.
///
/// Pure-Dart SHA-1 (RFC 3174) and the SHA-256 wrapper over `sha256.dart`,
/// used for `_CodeSignature/CodeResources` hashing and bundle file digests.

import 'dart:typed_data';

import 'sha256.dart' as sha256lib;

// ---------------------------------------------------------------------------
// Pure-Dart SHA-1 (RFC 3174); SHA-256 lives in sha256.dart.
// ---------------------------------------------------------------------------

int _rotl32(int val, int shift) =>
    ((val << shift) & 0xFFFFFFFF) | ((val & 0xFFFFFFFF) >>> (32 - shift));

/// Computes the 20-byte SHA-1 digest of [data] per RFC 3174.
Uint8List sha1Bytes(List<int> data) {
  final int msgLen = data.length;
  final int bitLen = msgLen * 8;
  // Pad to 64-byte boundary with 0x80 followed by zeros and 64-bit big-endian length.
  final int padLen = ((56 - (msgLen + 1) % 64) + 64) % 64;
  final int totalLen = msgLen + 1 + padLen + 8;
  final padded = Uint8List(totalLen);
  padded.setRange(0, msgLen, data);
  padded[msgLen] = 0x80;
  final bd = ByteData.sublistView(padded);
  bd.setUint32(totalLen - 8, (bitLen ~/ 0x100000000) & 0xFFFFFFFF, Endian.big);
  bd.setUint32(totalLen - 4, bitLen & 0xFFFFFFFF, Endian.big);

  var h0 = 0x67452301;
  var h1 = 0xEFCDAB89;
  var h2 = 0x98BADCFE;
  var h3 = 0x10325476;
  var h4 = 0xC3D2E1F0;

  final w = Uint32List(80);

  for (var offset = 0; offset < totalLen; offset += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = bd.getUint32(offset + i * 4, Endian.big);
    }
    for (var i = 16; i < 80; i++) {
      w[i] = _rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }

    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;

    for (var i = 0; i < 80; i++) {
      final int f;
      final int k;
      if (i < 20) {
        f = (b & c) | ((~b & 0xFFFFFFFF) & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      final int temp = (_rotl32(a, 5) + f + e + k + w[i]) & 0xFFFFFFFF;
      e = d;
      d = c;
      c = _rotl32(b, 30);
      b = a;
      a = temp;
    }

    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
  }

  final out = Uint8List(20);
  final outBd = ByteData.sublistView(out);
  outBd.setUint32(0, h0, Endian.big);
  outBd.setUint32(4, h1, Endian.big);
  outBd.setUint32(8, h2, Endian.big);
  outBd.setUint32(12, h3, Endian.big);
  outBd.setUint32(16, h4, Endian.big);
  return out;
}

/// Computes the 32-byte SHA-256 digest of [data] per FIPS 180-4.
Uint8List sha256Bytes(List<int> data) =>
    Uint8List.fromList(sha256lib.sha256(data));
