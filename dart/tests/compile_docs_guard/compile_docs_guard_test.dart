import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Locks the compile docs to what `exe` and `aot-snapshot` do today.
///
/// Both modes compile whole-program from sources, so no doc sentence may say
/// they take linked modules, and `import_check.bzl` keeps its doc extract.
/// Runs unsandboxed over the live tree, found through the test's own file.
void main(List<String> args) {
  final String root = _repoRoot(args.first);
  _checkCompileMode(root);
  _checkModularKernel(root);
  _checkImportCheckExtract(root);
}

final RegExp _sentenceEnd = RegExp(r'(?<=[.:;])\s+|\n\s*\n');
final RegExp _sourceModes = RegExp('`(exe|aot-snapshot)`');

/// Sentences of [text] that name `exe` or `aot-snapshot` and say "linked".
List<String> _linkedClaims(String text) => <String>[
  for (final String sentence in text.split(_sentenceEnd))
    if (_sourceModes.hasMatch(sentence) && sentence.contains('linked'))
      sentence.trim(),
];

/// Checks the `compile_mode` doc in `dart_binary.bzl`.
void _checkCompileMode(String root) {
  test('compile_mode doc keeps exe and aot-snapshot on sources', () {
    final String text = File('$root/dart/private/dart_binary.bzl')
        .readAsStringSync();
    final int start = text.indexOf('The `dart compile` mode. Determines');
    expect(start, greaterThanOrEqualTo(0), reason: 'compile_mode doc moved');
    final String doc = text.substring(start, text.indexOf('""",', start));
    expect(_linkedClaims(doc), isEmpty);
    expect(doc, contains('from sources'));
  });
}

/// Checks the `modular_kernel` and `_kernel_module` docs in `dart_kernel.bzl`.
void _checkModularKernel(String root) {
  test('modular_kernel doc names only the kernel mode', () {
    final String text = File('$root/dart/private/dart_kernel.bzl')
        .readAsStringSync();
    final int start = text.indexOf('"modular_kernel": attr.bool(');
    expect(start, greaterThanOrEqualTo(0), reason: 'modular_kernel moved');
    final String attrs = text.substring(start, text.indexOf('\n    ),', start));
    expect(_linkedClaims(attrs), isEmpty);
    final int tool = text.indexOf('"_kernel_module": attr.label(', start);
    final String toolDoc = text.substring(tool, text.indexOf('default', tool));
    expect(toolDoc, isNot(contains('`exe`')));
    expect(toolDoc, isNot(contains('`aot-snapshot`')));
  });
}

/// Checks `docs/BUILD.bazel` extracts `//dart:import_check.bzl`.
void _checkImportCheckExtract(String root) {
  test('docs/BUILD.bazel extracts import_check.bzl', () {
    final String text = File('$root/docs/BUILD.bazel').readAsStringSync();
    final extract = RegExp(
      r'starlark_doc_extract\(([^)]*src\s*=\s*"//dart:import_check\.bzl"[^)]*)\)',
    );
    expect(extract.hasMatch(text), isTrue);
    expect(text, contains('//dart:import_check_bzl'));
  });
}

/// The workspace root, found from [rlocationPath] through its symlinks.
String _repoRoot(String rlocationPath) {
  final String located = Runfiles.create().rlocation(rlocationPath);
  String dir = File(located).resolveSymbolicLinksSync();
  while (true) {
    final Directory parent = File(dir).parent;
    if (parent.path == dir) {
      throw StateError('cannot locate the workspace root from $located');
    }
    dir = parent.path;
    if (File('$dir/MODULE.bazel').existsSync() &&
        Directory('$dir/dart').existsSync()) {
      return dir;
    }
  }
}
