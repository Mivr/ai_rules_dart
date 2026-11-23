/// Items for an output directory: the web build, the Linux bundle.
library;

import 'dart:convert';
import 'dart:io';

import 'package:conformance/compare.dart';
import 'package:conformance/normalise.dart';
import 'package:crypto/crypto.dart';

/// Every file under [root] (symbolic links followed), as sorted relative
/// paths.
List<String> listFiles(Directory root) {
  if (!root.existsSync()) return const [];
  final int skip = root.absolute.path.length + 1;
  return [
    for (final e in root.absolute.listSync(recursive: true, followLinks: true))
      if (e is File) e.path.substring(skip),
  ]..sort();
}

/// The category of a web output file.
String webCategory(String path) {
  if (RegExp(r'^main\.dart\.(js|wasm|mjs)$').hasMatch(path)) return 'compiled';
  if (const {
    'index.html',
    'flutter.js',
    'flutter_bootstrap.js',
    'flutter_service_worker.js',
    'manifest.json',
    'version.json',
  }.contains(path)) {
    return 'bootstrap';
  }
  if (path.startsWith('assets/')) return 'asset';
  if (path.startsWith('canvaskit/')) return 'engine';
  return 'web';
}

/// One item per file of a web build: `<category>:<path>`, valued by the
/// digest of its normalised content and noted with its size.
Items webItems(Directory root, Applied applied) {
  final items = <String, Value>{};
  for (final path in listFiles(root)) {
    if (path == '.last_build_id') {
      applied.hit(lastBuildId);
      continue;
    }
    final List<int> bytes = File('${root.path}/$path').readAsBytesSync();
    items['${webCategory(path)}:$path'] = Value(
      _digest(_normaliseText(path, bytes, applied)),
      '${bytes.length} B',
    );
  }
  return items;
}

/// [bytes], with the normalisers that apply to [path] applied.
List<int> _normaliseText(String path, List<int> bytes, Applied applied) {
  if (path.endsWith('.json')) {
    final String? canonical = canonicalJson(
      utf8.decode(bytes, allowMalformed: true),
    );
    if (canonical != null) {
      final List<int> out = utf8.encode(canonical);
      if (!_same(out, bytes)) applied.hit(jsonFormat);
      return out;
    }
  }
  if (path.endsWith('.js') || path.endsWith('.html')) {
    if (path.startsWith('main.dart.')) return bytes;
    final String text = utf8.decode(bytes, allowMalformed: true);
    final String out = withoutServiceWorkerVersion(text, applied);
    return out == text ? bytes : utf8.encode(out);
  }
  return bytes;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _digest(List<int> bytes) => sha256.convert(bytes).toString();

/// The digest of a file's bytes.
String fileDigest(File f) => _digest(f.readAsBytesSync());

/// One item per file of a Linux bundle: `elf:` for shared libraries and the
/// executable (valued by exported symbols when [exports] can read them),
/// `asset:` under `data/flutter_assets/`, `bundle:` for the rest.
Items linuxItems(
  Directory root,
  Applied applied, {
  required List<String>? Function(File) exports,
}) {
  final items = <String, Value>{};
  for (final path in listFiles(root)) {
    final file = File('${root.path}/$path');
    final List<int> head = _head(file);
    if (_isElf(head)) {
      final List<String>? symbols = exports(file);
      items['elf:$path'] = symbols == null
          ? Value(fileDigest(file), '${file.lengthSync()} B')
          : Value(
              _digest(utf8.encode(symbols.join('\n'))),
              '${symbols.length} exported symbols',
            );
      continue;
    }
    final String category = path.startsWith('data/flutter_assets/')
        ? 'asset'
        : 'bundle';
    final List<int> bytes = file.readAsBytesSync();
    items['$category:$path'] = Value(
      _digest(_normaliseText(path, bytes, applied)),
      '${bytes.length} B',
    );
  }
  return items;
}

List<int> _head(File f) {
  final RandomAccessFile raf = f.openSync();
  try {
    return raf.readSync(4);
  } finally {
    raf.closeSync();
  }
}

bool _isElf(List<int> head) =>
    head.length == 4 &&
    head[0] == 0x7f &&
    head[1] == 0x45 &&
    head[2] == 0x4c &&
    head[3] == 0x46;
