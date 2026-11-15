/// Kernel consistency of the linked modular debug kernel.
///
/// `:app_debug_kernel` is the registrant app's `-c dbg` kernel. Two things
/// must hold for it:
///
/// 1. Its source table holds no two entries for one URI that disagree. An
///    entry with neither text nor line starts is a placeholder and is
///    ignored. #421 shipped a kernel where the module strip had emptied the
///    text of `org-dartlang-sdk:` entries while the link kept the platform
///    dill's copies.
/// 2. The pinned SDK `dart` VM (the one running this test) loads it past
///    `kernel_loader`. It may stop later, on `dart:ui` natives only a Flutter
///    engine provides; that is a pass.
///
/// A failure names the URI.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _magic = 0x90ABCDEF;

/// One source-table entry: its URI, text bytes and line-start count.
typedef _Entry = ({String uri, Uint8List text, List<int> lineStarts});

/// A bounds-checked reader of kernel `UInt30` values and byte runs.
class _Reader {
  _Reader(this.bytes, this.pos, this.limit);

  final Uint8List bytes;
  final int limit;
  int pos;

  int _next() {
    if (pos >= limit) throw const FormatException('truncated source table');
    return bytes[pos++];
  }

  int u30() {
    final b0 = _next();
    if (b0 & 0x80 == 0) return b0;
    if (b0 & 0x40 == 0) return ((b0 & 0x3f) << 8) | _next();
    final b1 = _next();
    final b2 = _next();
    return ((b0 & 0x3f) << 24) | (b1 << 16) | (b2 << 8) | _next();
  }

  Uint8List run() {
    final n = u30();
    if (pos + n > limit) throw const FormatException('truncated string');
    final out = Uint8List.sublistView(bytes, pos, pos + n);
    pos += n;
    return out;
  }

  void skipRun() {
    final n = u30();
    for (var i = 0; i < n; i++) {
      u30();
    }
  }
}

/// The source-table entries of the one component in [part].
List<_Entry> _entries(Uint8List part) {
  final bd = ByteData.sublistView(part);
  final libraries = bd.getUint32(part.length - 8);
  final index = part.length - (libraries + 12) * 4;
  final sources = bd.getUint32(index);
  final constants = bd.getUint32(index + 4);
  final reader = _Reader(part, sources + 4, constants);
  final out = <_Entry>[];
  for (var i = 0; i < bd.getUint32(sources); i++) {
    final uri = utf8.decode(reader.run());
    final text = reader.run();
    final count = reader.u30();
    final lineStarts = <int>[for (var j = 0; j < count; j++) reader.u30()];
    reader
      ..run() // importUri
      ..skipRun(); // constantCoverageConstructors
    out.add((uri: uri, text: text, lineStarts: lineStarts));
  }
  return out;
}

/// The components of [data]: one, or several concatenated.
List<Uint8List> _components(Uint8List data) {
  final bd = ByteData.sublistView(data);
  final parts = <Uint8List>[];
  var end = data.length;
  while (end >= 48) {
    final size = bd.getUint32(end - 4);
    if (size < 48 || size > end || bd.getUint32(end - size) != _magic) {
      throw FormatException('not a kernel component ending at byte $end');
    }
    parts.add(Uint8List.sublistView(data, end - size, end));
    end -= size;
  }
  if (end != 0 || parts.isEmpty) {
    throw const FormatException('not a kernel file');
  }
  return parts.reversed.toList();
}

bool _sameBytes(List<int> a, List<int> b) =>
    a.length == b.length &&
    Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

/// The URIs that have two non-placeholder entries disagreeing in text.
List<String> disagreeingUris(Uint8List data) {
  final seen = <String, _Entry>{};
  final bad = <String>{};
  for (final part in _components(data)) {
    for (final e in _entries(part)) {
      if (e.text.isEmpty && e.lineStarts.isEmpty) continue;
      final first = seen[e.uri];
      if (first == null) {
        seen[e.uri] = e;
      } else if (!_sameBytes(first.text, e.text) ||
          !_sameBytes(first.lineStarts, e.lineStarts)) {
        bad.add(e.uri);
      }
    }
  }
  return bad.toList()..sort();
}

String _runfile(String variable) {
  final rel = Platform.environment[variable];
  final root = Platform.environment['TEST_SRCDIR'];
  if (rel == null || root == null) {
    stderr.writeln('FAIL: $variable or TEST_SRCDIR is unset');
    exit(1);
  }
  return '$root/$rel';
}

Future<void> main() async {
  final dill = _runfile('APP_DILL');
  var failed = false;

  final bad = disagreeingUris(File(dill).readAsBytesSync());
  for (final uri in bad) {
    stderr.writeln('FAIL: two source entries disagree for URI $uri');
    failed = true;
  }

  final vm = await Process.run(Platform.resolvedExecutable, [
    dill,
  ]).timeout(const Duration(minutes: 3));
  final output = '${vm.stdout}\n${vm.stderr}';
  if (output.contains('kernel_loader') ||
      output.contains('Invalid kernel binary')) {
    stderr
      ..writeln('FAIL: the dart VM refused the kernel at kernel_loader:')
      ..writeln(output);
    failed = true;
  }
  if (failed) exit(1);
  stdout.writeln('kernel consistent: ${vm.exitCode} from the VM, no error');
}
