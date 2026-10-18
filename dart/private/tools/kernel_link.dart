// Links an executable's kernel from the kernels its entry reaches, or a shared
// base kernel from `--seed-module` directories. Run by `kernel_link_action` in
// `dart/private/dart_kernel.bzl`.
//
// The arguments are a params file holding optional flags (`--write-keys <path>`,
// `--base-keys <path>`, repeatable `--seed-module <dir>`), `<output>`, the entry
// module's directory (when `--seed-module` is not used), and then each dependency
// module's directory, one per line. Each directory holds an `index.json` that
// lists its kernels: the file of each, the keys of the libraries it defines, and
// the keys it imports. The entry's index names the entry kernel and what the
// entry imports.
//
// The link walks the imports from the entry (or seed modules), and writes only
// the kernels it reaches. The entry kernel comes first, then each dependency
// kernel after every kernel it imports. When `--base-keys <path>` is passed, any
// dependency kernel whose `<dir>:<dill>` key is already in the base kernel is
// skipped from the output (while still traversed during reachability so
// transitive imports through base modules are discovered).
//
// The entry comes first because the VM runs the `main` of the first component that
// has one, and a dependency's component can have a `main` of its own: a library that
// defines `main` for its CLI, say. Linking the entry last ran that library's `main`
// instead of the test's, and the test hung. With the entry first the test's `main` runs.
//
// The VM loads a file of concatenated kernels as one program. This is a compiled
// `dart_binary` of the exec platform, so the link runs without the SDK as an input,
// and a `dart_test` can name it as an executable attribute.
//
// Supports both one-shot execution (with `@flagfile` expansion) and Bazel's
// `--persistent_worker` binary protobuf protocol over stdin/stdout, caching
// parsed `index.json` manifests, `--base-keys` sets, and `.dill` bytes across
// requests.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A kernel an index lists: its file, its `<dir>:<dill>` key, and what it defines and imports.
class _Kernel {
  _Kernel(this.path, this.key, this.defines, this.imports);

  final String path;
  final String key;
  final List<String> defines;
  final List<String> imports;
}

class _CachedEntry<T> {
  _CachedEntry({
    required this.value,
    required this.inputDigest,
    required this.contentSha256,
    required this.byteSize,
    required this.tick,
  });

  final T value;
  final Uint8List? inputDigest;
  final Uint8List? contentSha256;
  final int byteSize;
  int tick;
}

bool _isAsciiAlpha(int c) =>
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);

bool _isWindowsDrivePath(String s) =>
    s.length >= 2 &&
    _isAsciiAlpha(s.codeUnitAt(0)) &&
    s.codeUnitAt(1) == 0x3a &&
    (s.length == 2 || s.codeUnitAt(2) == 0x2f || s.codeUnitAt(2) == 0x5c);

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

String _normalizePath(String path) {
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

/// Caches parsed `index.json` manifests, `--base-keys` sets, and `.dill` bytes
/// across persistent-worker requests within a single byte budget.
///
/// Bazel 9.3.0 expands tree artifacts (`declare_directory`, such as `.kmod` and
/// `.koutline`) in `WorkRequest.inputs` into individual file entries, each with
/// its own SHA-256 digest, and never sends an entry for the tree-artifact
/// directory itself. Cache lookups therefore match exact or normalized file
/// paths in `WorkRequest.inputs` and fall back to reading from disk when no
/// per-file digest is present.
class KernelLinkCache {
  KernelLinkCache({
    this.maxCacheBytes = defaultMaxCacheBytes,
    int? maxIndexCacheBytes,
    int? maxBaseKeysCacheBytes,
    int? maxSingleDillBytes,
  }) : maxIndexCacheBytes =
           maxIndexCacheBytes ??
           (maxCacheBytes < defaultMaxIndexCacheBytes
               ? maxCacheBytes
               : defaultMaxIndexCacheBytes),
       maxBaseKeysCacheBytes =
           maxBaseKeysCacheBytes ??
           (maxCacheBytes < defaultMaxBaseKeysCacheBytes
               ? maxCacheBytes
               : defaultMaxBaseKeysCacheBytes),
       maxSingleDillBytes =
           maxSingleDillBytes ??
           (maxCacheBytes < defaultMaxSingleDillBytes
               ? maxCacheBytes
               : defaultMaxSingleDillBytes);

  static const int defaultMaxCacheBytes = 128 * 1024 * 1024;
  static const int defaultMaxIndexCacheBytes = 8 * 1024 * 1024;
  static const int defaultMaxBaseKeysCacheBytes = 8 * 1024 * 1024;
  static const int defaultMaxSingleDillBytes = 16 * 1024 * 1024;

  final int maxCacheBytes;
  final int maxIndexCacheBytes;
  final int maxBaseKeysCacheBytes;
  final int maxSingleDillBytes;

  final _indexCache = <String, _CachedEntry<List<_Kernel>>>{};
  final _baseKeysCache = <String, _CachedEntry<Set<String>>>{};
  final _dillCache = <String, _CachedEntry<Uint8List>>{};
  int _indexBytesTotal = 0;
  int _baseKeysBytesTotal = 0;
  int _dillBytesTotal = 0;
  int _clock = 0;

  int get indexBytes => _indexBytesTotal;
  int get baseKeysBytes => _baseKeysBytesTotal;
  int get dillBytes => _dillBytesTotal;
  int get totalBytes =>
      _indexBytesTotal + _baseKeysBytesTotal + _dillBytesTotal;

  int get indexEntryCount => _indexCache.length;
  int get baseKeysEntryCount => _baseKeysCache.length;
  int get dillEntryCount => _dillCache.length;

  /// Returns an unpinned copy of [bytes] when it views a larger [ByteBuffer].
  static Uint8List _unpin(Uint8List bytes) =>
      bytes.buffer.lengthInBytes == bytes.lengthInBytes
      ? bytes
      : Uint8List.fromList(bytes);

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Uint8List? _lookupDigest(String path, Map<String, Uint8List>? inputs) {
    if (inputs == null) return null;
    final direct = inputs[path];
    if (direct != null && direct.isNotEmpty) return direct;
    final norm = _normalizePath(path);
    if (norm != path) {
      final normHit = inputs[norm];
      if (normHit != null && normHit.isNotEmpty) return normHit;
    }
    if (!norm.startsWith('/')) {
      final dotHit = inputs['./$norm'];
      if (dotHit != null && dotHit.isNotEmpty) return dotHit;
    }
    return null;
  }

  void _evictForTotalBudget(int incomingBytes) {
    while (totalBytes + incomingBytes > maxCacheBytes) {
      String? oldestIndexKey;
      int? oldestIndexTick;
      if (_indexCache.isNotEmpty) {
        final first = _indexCache.entries.first;
        oldestIndexKey = first.key;
        oldestIndexTick = first.value.tick;
      }

      String? oldestBaseKey;
      int? oldestBaseTick;
      if (_baseKeysCache.isNotEmpty) {
        final first = _baseKeysCache.entries.first;
        oldestBaseKey = first.key;
        oldestBaseTick = first.value.tick;
      }

      String? oldestDillKey;
      int? oldestDillTick;
      if (_dillCache.isNotEmpty) {
        final first = _dillCache.entries.first;
        oldestDillKey = first.key;
        oldestDillTick = first.value.tick;
      }

      if (oldestIndexTick == null &&
          oldestBaseTick == null &&
          oldestDillTick == null) {
        break;
      }

      // Evict the globally least-recently-used entry across all three maps.
      var minTick = oldestDillTick ?? oldestIndexTick ?? oldestBaseTick!;
      if (oldestIndexTick != null && oldestIndexTick < minTick) {
        minTick = oldestIndexTick;
      }
      if (oldestBaseTick != null && oldestBaseTick < minTick) {
        minTick = oldestBaseTick;
      }

      if (oldestDillTick != null && oldestDillTick == minTick) {
        final removed = _dillCache.remove(oldestDillKey!)!;
        _dillBytesTotal -= removed.byteSize;
      } else if (oldestIndexTick != null && oldestIndexTick == minTick) {
        final removed = _indexCache.remove(oldestIndexKey!)!;
        _indexBytesTotal -= removed.byteSize;
      } else if (oldestBaseTick != null) {
        final removed = _baseKeysCache.remove(oldestBaseKey!)!;
        _baseKeysBytesTotal -= removed.byteSize;
      }
    }
  }

  List<_Kernel> kernelsOf(String dir, Map<String, Uint8List>? inputs) {
    final normDir = _normalizePath(dir);
    final indexPath = '$dir/index.json';
    final digest = _lookupDigest(indexPath, inputs);
    final hasDigest = digest != null && digest.isNotEmpty;
    final cached = _indexCache.remove(normDir);
    if (cached != null) {
      if (hasDigest &&
          cached.inputDigest != null &&
          _sameBytes(digest, cached.inputDigest!)) {
        cached.tick = ++_clock;
        _indexCache[normDir] = cached;
        return cached.value;
      }
      _indexBytesTotal -= cached.byteSize;
    }

    final bytes = File(indexPath).readAsBytesSync();
    final entryBytes = bytes.length;
    final contentSha256 = hasDigest ? null : _sha256Of(bytes);
    if (!hasDigest &&
        cached != null &&
        cached.byteSize == entryBytes &&
        cached.contentSha256 != null &&
        _sameBytes(contentSha256!, cached.contentSha256!)) {
      if (entryBytes <= maxIndexCacheBytes && entryBytes <= maxCacheBytes) {
        while (_indexBytesTotal + entryBytes > maxIndexCacheBytes &&
            _indexCache.isNotEmpty) {
          final removed = _indexCache.remove(_indexCache.keys.first)!;
          _indexBytesTotal -= removed.byteSize;
        }
        _evictForTotalBudget(entryBytes);
        cached.tick = ++_clock;
        _indexCache[normDir] = cached;
        _indexBytesTotal += entryBytes;
      }
      return cached.value;
    }

    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final kernels = [
      for (final scc in (json['sccs'] as List).cast<Map<String, dynamic>>())
        _Kernel(
          '$dir/${scc['dill']}',
          '$dir:${scc['dill']}',
          (scc['defines'] as List).cast<String>(),
          (scc['imports'] as List).cast<String>()..sort(),
        ),
    ];
    if (entryBytes <= maxIndexCacheBytes && entryBytes <= maxCacheBytes) {
      while (_indexBytesTotal + entryBytes > maxIndexCacheBytes &&
          _indexCache.isNotEmpty) {
        final removed = _indexCache.remove(_indexCache.keys.first)!;
        _indexBytesTotal -= removed.byteSize;
      }
      _evictForTotalBudget(entryBytes);
      _indexCache[normDir] = _CachedEntry(
        value: kernels,
        inputDigest: hasDigest ? _unpin(digest) : null,
        contentSha256: contentSha256,
        byteSize: entryBytes,
        tick: ++_clock,
      );
      _indexBytesTotal += entryBytes;
    }
    return kernels;
  }

  Set<String> baseKeysOf(String path, Map<String, Uint8List>? inputs) {
    final key = _normalizePath(path);
    final digest = _lookupDigest(path, inputs);
    final hasDigest = digest != null && digest.isNotEmpty;
    final cached = _baseKeysCache.remove(key);
    if (cached != null) {
      if (hasDigest &&
          cached.inputDigest != null &&
          _sameBytes(digest, cached.inputDigest!)) {
        cached.tick = ++_clock;
        _baseKeysCache[key] = cached;
        return cached.value;
      }
      _baseKeysBytesTotal -= cached.byteSize;
    }

    final bytes = File(path).readAsBytesSync();
    final entryBytes = bytes.length;
    final contentSha256 = hasDigest ? null : _sha256Of(bytes);
    if (!hasDigest &&
        cached != null &&
        cached.byteSize == entryBytes &&
        cached.contentSha256 != null &&
        _sameBytes(contentSha256!, cached.contentSha256!)) {
      if (entryBytes <= maxBaseKeysCacheBytes && entryBytes <= maxCacheBytes) {
        while (_baseKeysBytesTotal + entryBytes > maxBaseKeysCacheBytes &&
            _baseKeysCache.isNotEmpty) {
          final removed = _baseKeysCache.remove(_baseKeysCache.keys.first)!;
          _baseKeysBytesTotal -= removed.byteSize;
        }
        _evictForTotalBudget(entryBytes);
        cached.tick = ++_clock;
        _baseKeysCache[key] = cached;
        _baseKeysBytesTotal += entryBytes;
      }
      return cached.value;
    }

    final keys = <String>{};
    for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) keys.add(trimmed);
    }
    if (entryBytes <= maxBaseKeysCacheBytes && entryBytes <= maxCacheBytes) {
      while (_baseKeysBytesTotal + entryBytes > maxBaseKeysCacheBytes &&
          _baseKeysCache.isNotEmpty) {
        final removed = _baseKeysCache.remove(_baseKeysCache.keys.first)!;
        _baseKeysBytesTotal -= removed.byteSize;
      }
      _evictForTotalBudget(entryBytes);
      _baseKeysCache[key] = _CachedEntry(
        value: keys,
        inputDigest: hasDigest ? _unpin(digest) : null,
        contentSha256: contentSha256,
        byteSize: entryBytes,
        tick: ++_clock,
      );
      _baseKeysBytesTotal += entryBytes;
    }
    return keys;
  }

  Uint8List dillBytesOf(String path, Map<String, Uint8List>? inputs) {
    final key = _normalizePath(path);
    final digest = _lookupDigest(path, inputs);
    final hasDigest = digest != null && digest.isNotEmpty;
    final cached = _dillCache.remove(key);
    if (cached != null) {
      if (hasDigest &&
          cached.inputDigest != null &&
          _sameBytes(digest, cached.inputDigest!)) {
        cached.tick = ++_clock;
        _dillCache[key] = cached;
        return cached.value;
      }
      _dillBytesTotal -= cached.byteSize;
    }

    final bytes = _unpin(File(path).readAsBytesSync());
    final entryBytes = bytes.length;
    if (entryBytes <= maxSingleDillBytes && entryBytes <= maxCacheBytes) {
      while (_dillBytesTotal + entryBytes > maxCacheBytes &&
          _dillCache.isNotEmpty) {
        final oldestKey = _dillCache.keys.first;
        final removed = _dillCache.remove(oldestKey)!;
        _dillBytesTotal -= removed.byteSize;
      }
      _evictForTotalBudget(entryBytes);
      _dillCache[key] = _CachedEntry(
        value: bytes,
        inputDigest: hasDigest ? _unpin(digest) : null,
        contentSha256: null,
        byteSize: entryBytes,
        tick: ++_clock,
      );
      _dillBytesTotal += entryBytes;
    }
    return bytes;
  }
}

Uint8List _sha256Of(Uint8List message) {
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

List<String> _expandParamFiles(List<String> args) {
  final out = <String>[];
  for (final arg in args) {
    if (arg.startsWith('@')) {
      out.addAll(File(arg.substring(1)).readAsLinesSync());
    } else {
      out.add(arg);
    }
  }
  return out;
}

Future<void> main(List<String> args) async {
  final expanded = _expandParamFiles(args);
  if (expanded.contains('--persistent_worker')) {
    await _runPersistentWorker();
    return;
  }
  final cache = KernelLinkCache();
  final code = linkOne(expanded, cache: cache, errSink: stderr);
  if (code != 0) exit(code);
}

Future<void> _runPersistentWorker() async {
  final cache = KernelLinkCache();
  await for (final bytes in _Frames(stdin)) {
    final request = _WorkRequest.read(bytes);
    if (request.cancel) continue;
    final output = StringBuffer();
    var code = 1;
    try {
      final expanded = _expandParamFiles(request.arguments);
      code = linkOne(
        expanded,
        cache: cache,
        inputs: request.inputs,
        errSink: output,
      );
    } on Object catch (e, st) {
      output
        ..writeln('kernel_link: unhandled exception: $e')
        ..writeln(st);
      code = 1;
    }
    stdout.add(
      _WorkResponse(
        exitCode: code,
        output: output.toString(),
        requestId: request.requestId,
      ).write(),
    );
    await stdout.flush();
  }
}

int linkOne(
  List<String> rawArgs, {
  required KernelLinkCache cache,
  Map<String, Uint8List>? inputs,
  required StringSink errSink,
}) {
  String? writeKeysPath;
  String? baseKeysPath;
  String? platform;
  final seedModules = <String>[];
  final paths = <String>[];
  for (var i = 0; i < rawArgs.length; i++) {
    final arg = rawArgs[i];
    if (arg.isEmpty) continue;
    if (arg == '--write-keys') {
      writeKeysPath = rawArgs[++i];
    } else if (arg == '--base-keys') {
      baseKeysPath = rawArgs[++i];
    } else if (arg == '--seed-module') {
      seedModules.add(rawArgs[++i]);
    } else if (arg == '--platform' && i + 1 < rawArgs.length) {
      platform = rawArgs[++i];
    } else if (arg.startsWith('--platform=')) {
      platform = arg.substring('--platform='.length);
    } else {
      paths.add(arg);
    }
  }
  final output = paths[0];
  final _Kernel? entry;
  final Iterable<String> depDirs;
  if (seedModules.isEmpty) {
    entry = cache.kernelsOf(paths[1], inputs).single;
    depDirs = paths.skip(2);
  } else {
    entry = null;
    depDirs = paths.skip(1);
  }

  final owner = <String, _Kernel>{};
  final kernelsByDir = <String, List<_Kernel>>{};
  for (final dir in <String>{...seedModules, ...depDirs}) {
    final kernels = cache.kernelsOf(dir, inputs);
    kernelsByDir[dir] = kernels;
    for (final kernel in kernels) {
      for (final key in kernel.defines) {
        owner.putIfAbsent(key, () => kernel);
      }
    }
  }

  final baseKeys = baseKeysPath != null
      ? cache.baseKeysOf(baseKeysPath, inputs)
      : const <String>{};

  final order = <_Kernel>[];
  final visited = <_Kernel>{};
  var missingModule = false;
  void visit(_Kernel kernel) {
    if (baseKeys.contains(kernel.key) || !visited.add(kernel)) return;
    for (final key in kernel.imports) {
      if (baseKeys.contains(key)) continue;
      final dependency = owner[key];
      if (dependency != null) {
        visit(dependency);
      } else if (!key.startsWith('dart:')) {
        errSink.writeln(
          'kernel_link: missing module for imported library $key (imported by ${kernel.path})',
        );
        missingModule = true;
      }
    }
    order.add(kernel);
  }

  if (entry != null) {
    for (final key in entry.imports) {
      if (baseKeys.contains(key)) continue;
      final dependency = owner[key];
      if (dependency != null) {
        visit(dependency);
      } else if (!key.startsWith('dart:')) {
        errSink.writeln(
          'kernel_link: missing module for imported library $key (imported by ${entry.path})',
        );
        missingModule = true;
      }
    }
  } else {
    for (final seedDir in seedModules) {
      final kernels = kernelsByDir[seedDir]!;
      final isPackageTest = kernels.any(
        (k) => k.defines.any((d) => d.endsWith('/lib/bootstrap/vm.dart')),
      );
      for (final kernel in kernels) {
        if (isPackageTest) {
          final isTestApi = kernel.defines.any(
            (d) =>
                d.endsWith('/lib/test.dart') ||
                d.endsWith('/lib/scaffolding.dart') ||
                d.endsWith('/lib/expect.dart') ||
                d.endsWith('/lib/bootstrap/vm.dart') ||
                d.endsWith('/lib/fake.dart'),
          );
          if (!isTestApi) continue;
        }
        visit(kernel);
      }
    }
  }
  if (missingModule) return 1;

  final linked = [if (entry != null) entry, ...order];
  final definedBy = <String, _Kernel>{};
  for (final kernel in linked) {
    for (final key in kernel.defines) {
      final other = definedBy[key];
      if (other != null) {
        errSink.writeln(
          'kernel_link: $key is defined by ${other.path} and ${kernel.path}.',
        );
        return 1;
      }
      definedBy[key] = kernel;
    }
  }

  final emitted = [
    if (entry != null) entry,
    for (final kernel in order)
      if (!baseKeys.contains(kernel.key)) kernel,
  ];

  final outBuilder = BytesBuilder(copy: false);
  if (platform != null) {
    outBuilder.add(cache.dillBytesOf(platform, inputs));
  }
  for (final kernel in emitted) {
    outBuilder.add(cache.dillBytesOf(kernel.path, inputs));
  }
  File(output).writeAsBytesSync(outBuilder.takeBytes());

  if (writeKeysPath != null) {
    final keysOut = StringBuffer();
    for (final k in emitted) {
      keysOut.writeln(k.key);
      for (final def in k.defines) {
        keysOut.writeln(def);
      }
    }
    File(writeKeysPath).writeAsStringSync(keysOut.toString());
  }
  return 0;
}

/// Decodes the `inputs` map from a raw `WorkRequest` protobuf payload,
/// copying each digest out of [bytes] so the request buffer is not pinned.
Map<String, Uint8List> decodeKernelLinkWorkRequestInputs(Uint8List bytes) =>
    _WorkRequest.read(bytes, copyDigests: true).inputs;

final Uint8List _emptyBytes = Uint8List(0);

final class _WorkRequest {
  _WorkRequest({
    required this.arguments,
    required this.inputs,
    required this.requestId,
    required this.cancel,
  });

  factory _WorkRequest.read(Uint8List bytes, {bool copyDigests = false}) {
    final arguments = <String>[];
    final inputs = <String, Uint8List>{};
    var requestId = 0;
    var cancel = false;
    final r = _Reader(bytes);
    while (!r.isDone) {
      final tag = r.varint();
      switch (tag >> 3) {
        case 1:
          arguments.add(r.string());
        case 2:
          final nested = r.submessage();
          var path = '';
          var digest = _emptyBytes;
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
    return _WorkRequest(
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

final class _WorkResponse {
  const _WorkResponse({
    required this.exitCode,
    required this.output,
    required this.requestId,
  });

  final int exitCode;
  final String output;
  final int requestId;

  Uint8List write() {
    final body = _Writer();
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
    final frame = _Writer()
      ..varint(payload.length)
      ..raw(payload);
    return frame.takeBytes();
  }
}

final class _Frames extends Stream<Uint8List> {
  _Frames(this._source);

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

final class _Reader {
  _Reader(this._buf);

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

  _Reader submessage() => _Reader(bytes());

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        varint();
      case 1:
        _pos += 8;
      case 2:
        _pos += varint();
      case 5:
        _pos += 4;
      default:
        throw FormatException('unsupported wire type: $wireType');
    }
  }
}

final class _Writer {
  final _buf = BytesBuilder();

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
