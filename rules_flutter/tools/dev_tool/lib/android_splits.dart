/// What a split install of a debug `flutter_android_app` needs besides adb.
///
/// A debug build can emit its Dart payload as a split APK of its own (the
/// `payload_apk` output group) next to the base APK (`base_apk`). A Dart edit
/// changes only the payload split, so the run installs only that one. Which
/// split changed is decided by [SplitInstallLedger]: it keeps the SHA-256 of
/// every split at its last successful install in this session and compares
/// the digests of the splits it is given now.
library;

import 'dart:io';
import 'dart:typed_data';

/// The bazel flag that builds just the two split APKs of a debug app, not the
/// single APK.
const splitOutputGroupsFlag = '--output_groups=base_apk,payload_apk';

/// [args] without [splitOutputGroupsFlag].
///
/// The split output groups belong to the `flutter_android_app` launch build. A
/// `flutter_application` has neither group, and `cquery --output=files` lists
/// only the files of the requested output groups, so a dev build that carried
/// the flag would list no `_dev_config.json` and hot reload could not be
/// assembled. Any other `--output_groups` value is left alone.
List<String> withoutSplitOutputGroups(List<String> args) => [
  for (final String arg in args)
    if (arg != splitOutputGroupsFlag) arg,
];

/// The file-name suffixes `flutter_android_app` gives the files of its
/// `base_apk` and `payload_apk` output groups.
const _baseSuffix = '_base.apk';
const _payloadSuffix = '_payload.apk';

/// The base split and then the payload split among [outputs], or null when the
/// outputs hold no such pair (a target that does not emit split APKs).
List<String>? splitApksFrom(List<String> outputs) {
  final List<String> bases = [
    for (final f in outputs)
      if (f.endsWith(_baseSuffix)) f,
  ];
  final List<String> payloads = [
    for (final f in outputs)
      if (f.endsWith(_payloadSuffix)) f,
  ];
  if (bases.length != 1 || payloads.length != 1) return null;
  return [bases.single, payloads.single];
}

/// What to hand `adb install-multiple` for a set of splits.
typedef SplitInstallPlan = ({List<String> apks, bool partial});

/// A [SplitInstallPlan] and the digests of the splits it was made from.
typedef SplitInstallDecision = ({
  SplitInstallPlan plan,
  Map<String, String> digests,
});

/// The SHA-256 digests of the splits at the last successful install.
class SplitInstallLedger {
  final Map<String, String> _installed = {};

  /// Which of [apkPaths] to install now: all of them the first time or when
  /// the base (the first path) changed, only the changed payload splits
  /// otherwise, and nothing (an empty list) when nothing changed.
  Future<SplitInstallDecision> plan(List<String> apkPaths) async {
    final digests = <String, String>{
      for (final path in apkPaths) path: await sha256Hex(path),
    };
    final String base = apkPaths.first;
    final bool whole =
        _installed.isEmpty ||
        !_installed.keys.toSet().containsAll(apkPaths) ||
        _installed[base] != digests[base];
    final List<String> changed = [
      for (final path in apkPaths)
        if (whole || _installed[path] != digests[path]) path,
    ];
    return (plan: (apks: changed, partial: !whole), digests: digests);
  }

  /// Records [digests] as installed. Called only after adb succeeded.
  void recordInstalled(Map<String, String> digests) =>
      _installed.addAll(digests);
}

/// The lowercase hex SHA-256 of the file at [path].
Future<String> sha256Hex(String path) async {
  final hash = _Sha256();
  await File(path).openRead().forEach(hash.add);
  return hash.finish();
}

/// The integer [k]-th root of [n], rounded down.
BigInt _integerRoot(BigInt n, int k) {
  BigInt x = BigInt.one << ((n.bitLength + k - 1) ~/ k);
  while (true) {
    final BigInt y =
        (x * BigInt.from(k - 1) + n ~/ x.pow(k - 1)) ~/ BigInt.from(k);
    if (y >= x) return x;
    x = y;
  }
}

final BigInt _word = BigInt.from(0xFFFFFFFF);

/// The first [count] primes.
List<int> _primes(int count) {
  final primes = <int>[];
  for (var n = 2; primes.length < count; n++) {
    if (primes.every((p) => n % p != 0)) primes.add(n);
  }
  return primes;
}

// FIPS 180-4: the round constants are the first 32 fractional bits of the cube
// roots of the first 64 primes, the initial state those of the square roots of
// the first 8.
final List<int> _roundConstants = [
  for (final p in _primes(64))
    (_integerRoot(BigInt.from(p) << 96, 3) & _word).toInt(),
];
final List<int> _initialState = [
  for (final p in _primes(8))
    (_integerRoot(BigInt.from(p) << 64, 2) & _word).toInt(),
];

/// An incremental SHA-256.
class _Sha256 {
  final List<int> _h = List.of(_initialState);
  final Uint32List _w = Uint32List(64);
  final BytesBuilder _pending = BytesBuilder(copy: false);
  int _length = 0;

  void add(List<int> data) {
    _length += data.length;
    _pending.add(data);
    final Uint8List bytes = _pending.takeBytes();
    final int whole = bytes.length - bytes.length % 64;
    for (var i = 0; i < whole; i += 64) {
      _block(bytes, i);
    }
    _pending.add(Uint8List.sublistView(bytes, whole));
  }

  String finish() {
    final int bits = _length * 8;
    final tail = BytesBuilder()
      ..addByte(0x80)
      ..add(Uint8List((119 - _length % 64) % 64));
    final length = ByteData(8)
      ..setUint32(0, bits >> 32)
      ..setUint32(4, bits & 0xFFFFFFFF);
    tail.add(length.buffer.asUint8List());
    add(tail.takeBytes());
    return [
      for (final int v in _h) v.toRadixString(16).padLeft(8, '0'),
    ].join();
  }

  static int _rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xFFFFFFFF;

  void _block(Uint8List data, int offset) {
    final Uint32List w = _w;
    final view = ByteData.sublistView(data, offset, offset + 64);
    for (var i = 0; i < 16; i++) {
      w[i] = view.getUint32(i * 4);
    }
    for (var i = 16; i < 64; i++) {
      final int a = w[i - 15];
      final int b = w[i - 2];
      final int s0 = _rotr(a, 7) ^ _rotr(a, 18) ^ (a >>> 3);
      final int s1 = _rotr(b, 17) ^ _rotr(b, 19) ^ (b >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }
    int a = _h[0];
    int b = _h[1];
    int c = _h[2];
    int d = _h[3];
    int e = _h[4];
    int f = _h[5];
    int g = _h[6];
    int h = _h[7];
    for (var i = 0; i < 64; i++) {
      final int s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final int ch = (e & f) ^ (~e & 0xFFFFFFFF & g);
      final int t1 = h + s1 + ch + _roundConstants[i] + w[i];
      final int s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final int maj = (a & b) ^ (a & c) ^ (b & c);
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + s0 + maj) & 0xFFFFFFFF;
    }
    final v = [a, b, c, d, e, f, g, h];
    for (var i = 0; i < 8; i++) {
      _h[i] = (_h[i] + v[i]) & 0xFFFFFFFF;
    }
  }
}
