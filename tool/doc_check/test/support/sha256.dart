/// SHA-256 in plain Dart, so the proto pin needs no external package.
library;

import 'dart:typed_data';

const _k = <int>[
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];

const _mask = 0xffffffff;

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask;

/// The lowercase hex SHA-256 digest of [data].
String sha256Hex(List<int> data) {
  final Uint8List padded = _pad(data);
  final h = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  for (var offset = 0; offset < padded.length; offset += 64) {
    _compress(h, ByteData.sublistView(padded, offset, offset + 64));
  }
  return h.map((word) => word.toRadixString(16).padLeft(8, '0')).join();
}

Uint8List _pad(List<int> data) {
  final int bitLength = data.length * 8;
  final int total = ((data.length + 9 + 63) ~/ 64) * 64;
  final padded = Uint8List(total)
    ..setRange(0, data.length, data)
    ..[data.length] = 0x80;
  ByteData.sublistView(padded)
    ..setUint32(total - 8, bitLength ~/ 0x100000000)
    ..setUint32(total - 4, bitLength & _mask);
  return padded;
}

void _compress(List<int> h, ByteData block) {
  final w = List<int>.filled(64, 0);
  for (var i = 0; i < 16; i++) {
    w[i] = block.getUint32(i * 4);
  }
  for (var i = 16; i < 64; i++) {
    final int s0 =
        _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
    final int s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _mask;
  }
  var v = List<int>.from(h);
  for (var i = 0; i < 64; i++) {
    v = _round(v, _k[i] + w[i]);
  }
  for (var i = 0; i < 8; i++) {
    h[i] = (h[i] + v[i]) & _mask;
  }
}

List<int> _round(List<int> v, int kw) {
  final int s1 = _rotr(v[4], 6) ^ _rotr(v[4], 11) ^ _rotr(v[4], 25);
  final int ch = (v[4] & v[5]) ^ (~v[4] & _mask & v[6]);
  final int t1 = (v[7] + s1 + ch + kw) & _mask;
  final int s0 = _rotr(v[0], 2) ^ _rotr(v[0], 13) ^ _rotr(v[0], 22);
  final int maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
  final int t2 = (s0 + maj) & _mask;
  return [
    (t1 + t2) & _mask,
    v[0],
    v[1],
    v[2],
    (v[3] + t1) & _mask,
    v[4],
    v[5],
    v[6],
  ];
}
