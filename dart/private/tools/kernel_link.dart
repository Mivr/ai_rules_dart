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

// Shared through `srcs`, like `kernel_module`'s guard import: this binary is
// an implicit exec tool of every `dart_library`, so it takes no
// `dart_library` dependency (that would be a cycle).
import 'lib/worker_protocol.dart';

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
    final norm = normalizePath(path);
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
    final normDir = normalizePath(dir);
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
    final contentSha256 = hasDigest ? null : sha256Of(bytes);
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
    final key = normalizePath(path);
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
    final contentSha256 = hasDigest ? null : sha256Of(bytes);
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
    final key = normalizePath(path);
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

Future<void> main(List<String> args) async {
  final expanded = expandParamFiles(args);
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
  await for (final bytes in WorkerFrames(stdin)) {
    final request = WorkerRequest.read(bytes, copyDigests: false);
    if (request.cancel) continue;
    final output = StringBuffer();
    var code = 1;
    try {
      final expanded = expandParamFiles(request.arguments);
      code = linkOne(
        expanded,
        cache: cache,
        inputs: request.inputs,
        errSink: output,
      );
    } on Object catch (e, st) {
      // A worker must answer every request, so this stays broad; the error
      // goes to the work response and to stderr (Bazel keeps worker stderr
      // in the worker log).
      stderr.writeln('kernel_link: unhandled exception: $e');
      stderr.writeln(st);
      output
        ..writeln('kernel_link: unhandled exception: $e')
        ..writeln(st);
      code = 1;
    }
    stdout.add(
      WorkerResponse(
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
  final parsed = _parseLinkArgs(rawArgs);
  final output = parsed.paths[0];
  final _Kernel? entry;
  final Iterable<String> depDirs;
  if (parsed.seedModules.isEmpty) {
    entry = cache.kernelsOf(parsed.paths[1], inputs).single;
    depDirs = parsed.paths.skip(2);
  } else {
    entry = null;
    depDirs = parsed.paths.skip(1);
  }

  final indexed = _indexKernels(
    cache,
    seedModules: parsed.seedModules,
    depDirs: depDirs,
    inputs: inputs,
  );
  final baseKeys = parsed.baseKeysPath != null
      ? cache.baseKeysOf(parsed.baseKeysPath!, inputs)
      : const <String>{};

  final walker = _LinkWalker(
    owner: indexed.owner,
    baseKeys: baseKeys,
    errSink: errSink,
  );
  if (entry != null) {
    walker.visitImports(entry.imports, importerPath: entry.path);
  } else {
    walker.visitSeeds(indexed.kernelsByDir, parsed.seedModules);
  }
  if (walker.missingModule) return 1;

  final linked = [if (entry != null) entry, ...walker.order];
  if (!_checkDuplicateDefines(linked, errSink)) return 1;

  _emitLinked((
    output: output,
    platform: parsed.platform,
    entry: entry,
    order: walker.order,
    baseKeys: baseKeys,
    writeKeysPath: parsed.writeKeysPath,
    cache: cache,
    inputs: inputs,
  ));
  return 0;
}

/// Parsed `linkOne` command line.
typedef _LinkArgs = ({
  String? writeKeysPath,
  String? baseKeysPath,
  String? platform,
  List<String> seedModules,
  List<String> paths,
});

/// Splits the runner flags from the output, entry, and dependency paths.
_LinkArgs _parseLinkArgs(List<String> rawArgs) {
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
  return (
    writeKeysPath: writeKeysPath,
    baseKeysPath: baseKeysPath,
    platform: platform,
    seedModules: seedModules,
    paths: paths,
  );
}

/// The kernels each seed and dependency directory provides, and which kernel
/// owns each defined library.
({Map<String, _Kernel> owner, Map<String, List<_Kernel>> kernelsByDir})
_indexKernels(
  KernelLinkCache cache, {
  required List<String> seedModules,
  required Iterable<String> depDirs,
  required Map<String, Uint8List>? inputs,
}) {
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
  return (owner: owner, kernelsByDir: kernelsByDir);
}

/// Walks kernel imports in dependency order, reporting missing modules.
class _LinkWalker {
  _LinkWalker({
    required this.owner,
    required this.baseKeys,
    required this.errSink,
  });

  final Map<String, _Kernel> owner;
  final Set<String> baseKeys;
  final StringSink errSink;
  final List<_Kernel> order = [];
  final Set<_Kernel> visited = {};
  var missingModule = false;

  void visit(_Kernel kernel) {
    if (baseKeys.contains(kernel.key) || !visited.add(kernel)) return;
    visitImports(kernel.imports, importerPath: kernel.path);
    order.add(kernel);
  }

  /// Visits each import's owning kernel, refusing unowned libraries.
  void visitImports(Iterable<String> imports, {required String importerPath}) {
    for (final key in imports) {
      if (baseKeys.contains(key)) continue;
      final dependency = owner[key];
      if (dependency != null) {
        visit(dependency);
      } else if (!key.startsWith('dart:')) {
        errSink.writeln(
          'kernel_link: missing module for imported library $key (imported by $importerPath)',
        );
        missingModule = true;
      }
    }
  }

  /// Visits every seed kernel, keeping only the test API for test seeds.
  void visitSeeds(
    Map<String, List<_Kernel>> kernelsByDir,
    List<String> seedModules,
  ) {
    for (final seedDir in seedModules) {
      final kernels = kernelsByDir[seedDir]!;
      final isPackageTest = kernels.any(
        (k) => k.defines.any((d) => d.endsWith('/lib/bootstrap/vm.dart')),
      );
      for (final kernel in kernels) {
        if (isPackageTest && !_isTestApiKernel(kernel)) continue;
        visit(kernel);
      }
    }
  }

  /// Whether [kernel] is part of `package:test`'s own API.
  bool _isTestApiKernel(_Kernel kernel) => kernel.defines.any(
    (d) =>
        d.endsWith('/lib/test.dart') ||
        d.endsWith('/lib/scaffolding.dart') ||
        d.endsWith('/lib/expect.dart') ||
        d.endsWith('/lib/bootstrap/vm.dart') ||
        d.endsWith('/lib/fake.dart'),
  );
}

/// Refuses linked kernels that define the same library twice.
bool _checkDuplicateDefines(List<_Kernel> linked, StringSink errSink) {
  final definedBy = <String, _Kernel>{};
  for (final kernel in linked) {
    for (final key in kernel.defines) {
      final other = definedBy[key];
      if (other != null) {
        errSink.writeln(
          'kernel_link: $key is defined by ${other.path} and ${kernel.path}.',
        );
        return false;
      }
      definedBy[key] = kernel;
    }
  }
  return true;
}

/// Concatenates the platform and linked kernels into [output], and records
/// the emitted keys when asked.
typedef _LinkedOutput = ({
  String output,
  String? platform,
  _Kernel? entry,
  List<_Kernel> order,
  Set<String> baseKeys,
  String? writeKeysPath,
  KernelLinkCache cache,
  Map<String, Uint8List>? inputs,
});

/// Concatenates the platform and linked kernels into [output], and records
/// the emitted keys when asked.
void _emitLinked(_LinkedOutput linked) {
  final entry = linked.entry;
  final platform = linked.platform;
  final writeKeysPath = linked.writeKeysPath;
  final emitted = [
    if (entry != null) entry,
    for (final kernel in linked.order)
      if (!linked.baseKeys.contains(kernel.key)) kernel,
  ];

  final outBuilder = BytesBuilder(copy: false);
  if (platform != null) {
    outBuilder.add(linked.cache.dillBytesOf(platform, linked.inputs));
  }
  for (final kernel in emitted) {
    outBuilder.add(linked.cache.dillBytesOf(kernel.path, linked.inputs));
  }
  File(linked.output).writeAsBytesSync(outBuilder.takeBytes());

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
}

/// Decodes the `inputs` map from a raw `WorkRequest` protobuf payload,
/// copying each digest out of [bytes] so the request buffer is not pinned.
Map<String, Uint8List> decodeKernelLinkWorkRequestInputs(Uint8List bytes) =>
    WorkerRequest.read(bytes).inputs;
