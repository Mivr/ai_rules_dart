/// Guard for the Android persistent-worker decision in
/// `docs/perf-android-workers.md`.
///
/// The recorded decision is "no flag": the consumer preset and
/// `e2e/android_example/.bazelrc` must not enable Android persistent workers
/// until a measurement replaces that doc. The preset file itself is checked
/// against its generator by `//tools:preset.update_test`.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Flag fragments that switch Android tools to persistent workers.
const List<String> _workerFlags = [
  'persistent_android',
  'worker_multiplex',
  'strategy=Aapt2',
  'strategy=Desugar',
  'strategy=Dex',
];

/// Whether [root] is the rules_flutter workspace root.
bool _looksLikeRoot(String root) =>
    Directory('$root/flutter').existsSync() &&
    File('$root/MODULE.bazel').existsSync();

/// Resolves the workspace root from the environment or the current directory.
String _root() {
  final String? env = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (env != null && env.isNotEmpty && _looksLikeRoot(env)) return env;
  final String? anchor = Platform.environment['GUARD_ROOT_ANCHOR'];
  final String? srcdir = Platform.environment['TEST_SRCDIR'];
  Directory dir = Directory.current;
  if (anchor != null && srcdir != null) {
    try {
      dir = File(File('$srcdir/$anchor').resolveSymbolicLinksSync()).parent;
    } on FileSystemException {
      // Keep the current directory when the anchor does not resolve.
    }
  }
  for (var i = 0; i < 8; i++) {
    if (_looksLikeRoot(dir.path)) return dir.path;
    dir = dir.parent;
  }
  fail('rules_flutter root not found');
}

/// The non-comment lines of the file at [path] under the root.
List<String> _rcLines(String path) =>
    File('${_root()}/$path')
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('#'))
        .toList();

void main() {
  final String doc = File(
    '${_root()}/docs/perf-android-workers.md',
  ).readAsStringSync();
  final bool enabled = doc.contains('Decision: enabled');

  test('the decision doc states a decision', () {
    expect(doc.contains('Decision: no flag') || enabled, isTrue);
  });

  for (final path in ['tools/preset.bazelrc', 'e2e/android_example/.bazelrc']) {
    test('$path matches the recorded decision', () {
      final bool has = _rcLines(
        path,
      ).any((l) => _workerFlags.any((f) => l.contains(f)));
      expect(has, enabled);
    });
  }
}
