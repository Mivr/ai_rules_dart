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
//       [--direct-package <name>]... [--src <file-or-dir>]... --output <stamp>
//
// A `--src` that is a directory stands for every `.dart` file under it (a
// `dart_source_set` or an opaque library keeps its sources in a directory).
//
// The tool reads the shared guard through `srcs`, so the relative import
// reaches it with no package edge: a dependency would make every `dart_library`
// depend on the tool that checks it, which is a cycle.

import 'dart:convert';
import 'dart:io';

// ignore: avoid_relative_lib_imports, compiled in place through `srcs`.
import '../../guard/lib/directive_guard.dart';

const _tool = 'import_check';

/// What one target states: its label, the packages its sources may import
/// (its own package names plus the packages of its direct deps), and its source
/// text by display path.
typedef ImportCheckRequest = ({
  String label,
  Set<String> allowedPackages,
  Map<String, String> sources,
});

/// The package a `package:` URI names, or null for any other URI.
String? packageOfUri(String uri) {
  const prefix = 'package:';
  if (!uri.startsWith(prefix)) return null;
  final String rest = uri.substring(prefix.length);
  final int slash = rest.indexOf('/');
  return slash < 0 ? rest : rest.substring(0, slash);
}

/// The violation line for [path] importing [uri] from package [name].
String violationLine(String label, String path, String uri, String name) =>
    "$label: $path imports '$uri', but package '$name' is not a direct "
    'dependency of $label, only of something it depends on. '
    "Add the target that provides package '$name' to $label's deps.";

/// The lines to print for [request], in path then source order. A source that
/// does not scan is refused, never treated as clean.
List<String> checkImports(ImportCheckRequest request) {
  final lines = <String>[];
  final List<String> paths = request.sources.keys.toList()..sort();
  for (final path in paths) {
    final ({List<ScanRef> refs, bool unparsable}) checked =
        scanAllDirectiveUrisChecked(request.sources[path]!);
    if (checked.unparsable) {
      lines.add(unparsableDirectiveDiagnostic(_tool, path));
      continue;
    }
    for (final ScanRef ref in checked.refs) {
      if (ref.kind != 'import' && ref.kind != 'export') continue;
      final String? name = packageOfUri(ref.uri);
      if (name == null || request.allowedPackages.contains(name)) continue;
      final String line = violationLine(request.label, path, ref.uri, name);
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
  List<String> srcs,
});

/// Parses [argv]; throws a [FormatException] naming what is wrong.
ImportCheckArgs parseArgs(List<String> argv) {
  String? label;
  String? output;
  final Set<String> packages = {};
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
  return (label: label, output: output, packages: packages, srcs: srcs);
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
  final List<String> lines = checkImports(_request(args));
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
