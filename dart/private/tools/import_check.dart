// The strict-layering check: a target's sources may import only the packages
// its own `deps` provide (and its own package, and `dart:`).
//
// The action reads each source's `import` and `export` directives through the
// shared guard scanner and writes an empty stamp when every `package:` URI
// names an allowed package. It compiles nothing and changes no compile
// action's inputs or outputs; the stamp only exists so a validation action can
// fail the build. See `dart/private/dart_import_check.bzl`.
//
// Usage:
//   import_check --label <label> [--own-package <name>]...
//       [--direct-package <name>]... [--refused-library dart:<name>]...
//       [--src <file-or-dir>]... --output <stamp>
//
// A `--refused-library` is a `dart:` library no `import` or `export` may name,
// exactly; it comes from the `//dart:refused_dart_libraries` build setting.
//
// A `--src` that is a directory stands for every `.dart` file under it (a
// `dart_source_set` or an opaque library keeps its sources in a directory).
//
// The tool reads the shared guard through `srcs`, so the relative import
// reaches it with no package edge: a dependency would make every `dart_library`
// depend on the tool that checks it, which is a cycle.

import 'dart:convert';
import 'dart:io';

// ignore: avoid_relative_lib_imports, reason: compiled in place through `srcs`.
import '../../guard/lib/directive_guard.dart';
import 'kernel_module_import_check.dart';

export 'kernel_module_import_check.dart';

const _tool = 'import_check';

final RegExp _refusableLibrary = RegExp(r'^dart:[a-z_]+$');

/// The violation line for [path] naming the refused library [uri] in a
/// [kind] (`import` or `export`) directive of [label].
String refusedLine(String label, String path, String kind, String uri) =>
    "$label: $path ${kind}s '$uri', which //dart:refused_dart_libraries "
    'refuses. Remove the $kind, or take the library out of that setting.';

/// The lines for `import` and `export` directives in [request] whose URI is
/// exactly one of [refused], in path then source order, each once. A source
/// that does not scan is left to `checkImports`, which reports it.
List<String> checkRefusedLibraries(
  ImportCheckRequest request,
  Set<String> refused,
) {
  final lines = <String>[];
  if (refused.isEmpty) return lines;
  final List<String> paths = request.sources.keys.toList()..sort();
  for (final path in paths) {
    final ({List<ScanRef> refs, bool unparsable}) checked =
        scanAllDirectiveUrisChecked(request.sources[path]!);
    if (checked.unparsable) continue;
    for (final ScanRef ref in checked.refs) {
      if (ref.kind != 'import' && ref.kind != 'export') continue;
      if (!refused.contains(ref.uri)) continue;
      final String line = refusedLine(request.label, path, ref.kind, ref.uri);
      if (!lines.contains(line)) lines.add(line);
    }
  }
  return lines;
}

/// The Dart files [src] names: itself, or every `.dart` file under it.
List<String> expandSource(String src) {
  if (!Directory(src).existsSync()) return [src];
  final List<String> files =
      Directory(src)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .map((f) => f.path)
          .where((p) => p.endsWith('.dart'))
          .toList()
        ..sort();
  return files;
}

/// The parsed command line.
typedef ImportCheckArgs = ({
  String label,
  String output,
  Set<String> packages,
  Set<String> refused,
  List<String> srcs,
});

/// Parses [argv]; throws a [FormatException] naming what is wrong.
ImportCheckArgs parseArgs(List<String> argv) {
  String? label;
  String? output;
  final Set<String> packages = {};
  final Set<String> refused = {};
  final List<String> srcs = [];
  for (var i = 0; i < argv.length; i++) {
    final String flag = argv[i];
    if (i + 1 >= argv.length) throw FormatException('$flag needs a value');
    final String value = argv[++i];
    switch (flag) {
      case '--label':
        label = value;
      case '--own-package' || '--direct-package':
        packages.add(value);
      case '--refused-library':
        if (!_refusableLibrary.hasMatch(value)) {
          throw FormatException(
            '--refused-library needs a value of the form dart:<name>, '
            'got "$value"',
          );
        }
        refused.add(value);
      case '--src':
        srcs.add(value);
      case '--output':
        output = value;
      default:
        throw FormatException('unknown flag $flag');
    }
  }
  if (label == null || output == null) {
    throw const FormatException('--label and --output are required');
  }
  return (
    label: label,
    output: output,
    packages: packages,
    refused: refused,
    srcs: srcs,
  );
}

ImportCheckRequest _request(ImportCheckArgs args) {
  final sources = <String, String>{};
  for (final String src in args.srcs) {
    for (final String file in expandSource(src)) {
      sources[file] = utf8.decode(
        File(file).readAsBytesSync(),
        allowMalformed: true,
      );
    }
  }
  return (label: args.label, allowedPackages: args.packages, sources: sources);
}

int run(List<String> argv) {
  final ImportCheckArgs args;
  try {
    args = parseArgs(argv);
  } on FormatException catch (e) {
    stderr.writeln('$_tool: ${e.message}');
    return 64;
  }
  final ImportCheckRequest request = _request(args);
  final List<String> lines = [
    ...checkImports(request),
    ...checkRefusedLibraries(request, args.refused),
  ];
  if (lines.isNotEmpty) {
    stderr.writeln(lines.join('\n'));
    return 1;
  }
  final out = File(args.output);
  out.parent.createSync(recursive: true);
  out.writeAsStringSync('');
  return 0;
}

void main(List<String> argv) {
  exitCode = run(argv);
}
