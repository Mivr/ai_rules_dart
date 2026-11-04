// Synthetic kernel-component builders for `app_jit_snapshot_test.dart`.
import 'dart:convert';
import 'dart:typed_data';

import 'dill_test_writer.dart';

/// A structurally valid kernel component for read-set unit tests: [sources]
/// are (`fileUri`, `importUri`) source-table entries, [libraries] are
/// (source index, canonical root or null) library nodes, and [extraRoots]
/// are canonical roots no node mentions. It shares its builder with
/// `kernel_module_test.dart`, and the parser-agreement test there pins both
/// readers to identical verdicts on its bytes.
Uint8List verifyDill({
  required List<(String, String)> sources,
  required List<(int, String?)> libraries,
  List<String> extraRoots = const [],
}) => buildLibraryTableDill(
  formatVersion: 138,
  sources: sources,
  libraries: libraries,
  extraRoots: extraRoots,
);

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
