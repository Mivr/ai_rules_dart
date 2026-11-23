/// SHA-256 in pure Dart, so the proto pin needs no package and no `sha256sum`.
library;

import 'dart:typed_data';

const _k = <int>[
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

const _mask = 0xffffffff;

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask;

/// The message padded to a multiple of 64 bytes, length appended big-endian.
Uint8List _pad(List<int> message) {
  final int padded = (message.length + 9 + 63) ~/ 64 * 64;
  final out = Uint8List(padded)..setAll(0, message);
  out[message.length] = 0x80;
  final int bits = message.length * 8;
  ByteData.sublistView(out).setUint64(padded - 8, bits);
  return out;
}

/// Expands one 64-byte block into the 64-word message schedule.
List<int> _schedule(Uint8List padded, int offset) {
  final w = List<int>.filled(64, 0);
  final view = ByteData.sublistView(padded);
  for (var i = 0; i < 16; i++) {
    w[i] = view.getUint32(offset + i * 4);
  }
  for (var i = 16; i < 64; i++) {
    final int s0 =
        _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
    final int s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _mask;
  }
  return w;
}

/// Runs the 64 compression rounds over [w], updating [h] in place.
void _compress(List<int> h, List<int> w) {
  var [a, b, c, d, e, f, g, k] = h;
  for (var t = 0; t < 64; t++) {
    final int s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
    final int ch = (e & f) ^ (~e & _mask & g);
    final int t1 = (k + s1 + ch + _k[t] + w[t]) & _mask;
    final int s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
    final int maj = (a & b) ^ (a & c) ^ (b & c);
    final int t2 = (s0 + maj) & _mask;
    k = g;
    g = f;
    f = e;
    e = (d + t1) & _mask;
    d = c;
    c = b;
    b = a;
    a = (t1 + t2) & _mask;
  }
  final next = [a, b, c, d, e, f, g, k];
  for (var n = 0; n < 8; n++) {
    h[n] = (h[n] + next[n]) & _mask;
  }
}

/// The lower-case hex SHA-256 digest of [message].
String sha256Hex(List<int> message) {
  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  final Uint8List padded = _pad(message);
  for (var offset = 0; offset < padded.length; offset += 64) {
    _compress(h, _schedule(padded, offset));
  }
  return h.map((x) => x.toRadixString(16).padLeft(8, '0')).join();
}
