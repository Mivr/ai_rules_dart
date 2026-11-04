// Synthetic kernel-component builders for `app_jit_snapshot_test.dart`.
import 'dart:convert';
import 'dart:typed_data';

/// A structurally valid kernel component for read-set unit tests: [sources]
/// are (`fileUri`, `importUri`) source-table entries, [libraries] are
/// (source index, canonical root or null) library nodes, and [extraRoots]
/// are canonical roots no node mentions. It mirrors the builder in
/// `kernel_module_test.dart`, and the parser-agreement test there pins both
/// readers to identical verdicts on its bytes.
Uint8List verifyDill({
  required List<(String, String)> sources,
  required List<(int, String?)> libraries,
  List<String> extraRoots = const [],
}) {
  final out = BytesBuilder();
  void u30(int v) {
    if (v < 0x80) {
      out.addByte(v);
    } else if (v < 0x4000) {
      out.addByte(0x80 | (v >> 8));
      out.addByte(v & 0xff);
    } else {
      out.addByte(0xc0 | ((v >> 24) & 0x3f));
      out.addByte((v >> 16) & 0xff);
      out.addByte((v >> 8) & 0xff);
      out.addByte(v & 0xff);
    }
  }

  void u32(int v) {
    out.addByte((v >> 24) & 0xff);
    out.addByte((v >> 16) & 0xff);
    out.addByte((v >> 8) & 0xff);
    out.addByte(v & 0xff);
  }

  void str(String s) {
    final Uint8List bytes = utf8.encode(s);
    u30(bytes.length);
    out.add(bytes);
  }

  final strings = <String>[''];
  int stringIndexOf(String s) {
    int index = strings.indexOf(s);
    if (index < 0) {
      index = strings.length;
      strings.add(s);
    }
    return index;
  }

  u32(0x90ABCDEF);
  u32(138);
  out.add(List.filled(64, 0));
  final int sourceTableOffset = out.length;
  u32(sources.length);
  for (final (fileUri, importUri) in sources) {
    str(fileUri);
    str('');
    u30(0);
    str(importUri);
    u30(0);
  }
  final int constantTableOffset = out.length;
  u30(0);
  final int linkTableOffset = out.length;
  u30(libraries.length + extraRoots.length);
  for (final (_, canon) in libraries) {
    u30(0); // Parent: the nameless root.
    u30(canon == null ? 0 : stringIndexOf(canon));
  }
  for (final root in extraRoots) {
    u30(0); // Parent: the nameless root no node references.
    u30(stringIndexOf(root));
  }
  final int stringTableOffset = out.length;
  u30(strings.length);
  var end = 0;
  final ends = <int>[];
  for (final s in strings) {
    end += utf8.encode(s).length;
    ends.add(end);
  }
  ends.forEach(u30);
  for (final s in strings) {
    out.add(utf8.encode(s));
  }
  final libraryOffsets = <int>[];
  for (var i = 0; i < libraries.length; i++) {
    libraryOffsets.add(out.length);
    final (int source, String? canon) = libraries[i];
    out.addByte(4); // Flags.
    u30(3); // Major version.
    u30(0); // Minor version.
    // Canonical-name reference, biased by one; zero names no reference.
    u30(canon == null ? 0 : i + 1);
    u30(0); // Name string reference: the empty name.
    u30(source);
  }
  libraryOffsets.add(out.length);
  u32(sourceTableOffset);
  u32(constantTableOffset);
  u32(constantTableOffset);
  u32(linkTableOffset);
  u32(linkTableOffset);
  u32(linkTableOffset);
  u32(stringTableOffset);
  u32(stringTableOffset);
  u32(stringTableOffset);
  libraryOffsets.forEach(u32);
  u32(libraries.length);
  u32(out.length + 4);
  return out.toBytes();
}

/// A copy of [clean] with the [occurrence]-th (zero-based) recording of
/// [uri]'s bytes replaced by invalid UTF-8: every length prefix still bounds
/// its entry, but decoding that recording fails.
Uint8List corruptRecordedUri(Uint8List clean, String uri, int occurrence) {
  final patched = Uint8List.fromList(clean);
  final Uint8List needle = utf8.encode(uri);
  var seen = 0;
  for (var i = 0; i + needle.length <= patched.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (patched[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (!match) continue;
    if (seen == occurrence) {
      patched[i] = 0xff;
      return patched;
    }
    seen++;
  }
  throw StateError('recorded URI $uri occurrence $occurrence not found');
}
