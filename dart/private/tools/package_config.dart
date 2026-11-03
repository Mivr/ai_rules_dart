// Generates a `package_config.json` for one kernel module from its closure's
// package records, as `kernel_module_action` in `dart/private/dart_kernel.bzl`
// invokes it.
//
// A chain of N `dart_library` targets used to format N package records into a
// JSON string in Starlark once per target, so analysis did O(N^2) Starlark work
// and string building. The rule now passes the transitive records as action
// arguments (`args.add_all` with `map_each`, expanded at execution) and this
// tool writes the file, so analysis holds only a depset reference.
//
// The bytes match `generate_stable_package_config` in `dart/private/common.bzl`
// called with every package kept (as `kernel_package_config` calls it): one
// entry per package name (first record wins), each root named by the stable
// multi-root scheme, `languageVersion` only when the record states one, and the
// same header, indentation and trailing newline. A record is one `--record`
// argument, `name|lib_root|language_version` (empty fields stay empty), in
// closure order; the tool keeps the first of each name.
//
// This binary takes no `dart_library` dependency on purpose (like
// `kernel_module`): every `dart_library` names it as an implicit exec tool, so
// a dependency would be a cycle. It imports only `dart:` libraries.

import 'dart:io';

/// The scheme argument: the multi-root URI scheme the roots resolve under.
const _schemeFlag = '--scheme';

/// The output argument: the `package_config.json` file to write.
const _outputFlag = '--output';

/// The record argument, once per package record in closure order.
const _recordFlag = '--record';

/// Splits a `--record` argument into its fields.
List<String> splitRecord(String raw) {
  final List<String> parts = raw.split('|');
  final String name = parts.isNotEmpty ? parts[0] : '';
  final String libRoot = parts.length > 1 ? parts[1] : '';
  final String languageVersion = parts.length > 2
      ? parts.sublist(2).join('|')
      : '';
  return <String>[name, libRoot, languageVersion];
}

/// The stable path a URI names, as `stable_path` in `dart/private/common.bzl`.
///
/// A file from another repository has the short path `../repo/x` and lives at
/// `external/repo/x` under the exec root, where the scheme's roots look.
String stablePath(String path) {
  if (path.startsWith('../')) return 'external/${path.substring(3)}';
  return path;
}

/// One package record the config names.
typedef PackageRecord = ({String name, String libRoot, String languageVersion});

/// Parses a `--record` argument.
PackageRecord parsePackageRecord(String raw) {
  final List<String> parts = splitRecord(raw);
  return (name: parts[0], libRoot: parts[1], languageVersion: parts[2]);
}

/// Builds the `package_config.json` content for [records] under [scheme].
///
/// Keeps the first record of each package name, in order, and names every kept
/// package (the caller passes the closure with every package kept, as
/// `kernel_package_config` does). Byte-identical to
/// `generate_stable_package_config` for that input.
String buildPackageConfig(List<PackageRecord> records, String scheme) {
  if (records.isEmpty) return '{"configVersion": 2, "packages": []}\n';
  final seen = <String>{};
  final entries = <String>[];
  for (final record in records) {
    if (!seen.add(record.name)) continue;
    var languageVersion = '';
    if (record.languageVersion.isNotEmpty) {
      languageVersion = ', "languageVersion": "${record.languageVersion}"';
    }
    entries.add(
      '    {"name": "${record.name}", '
      '"rootUri": "$scheme:///${stablePath(record.libRoot)}", '
      '"packageUri": "lib/"$languageVersion}',
    );
  }
  return '{\n  "configVersion": 2,\n  "packages": [\n'
      '${entries.join(',\n')}\n  ]\n}\n';
}

/// Expands `@file` arguments, one record per line, as Bazel writes them.
List<String> expandParamFiles(List<String> args) {
  final expanded = <String>[];
  for (final arg in args) {
    if (arg.startsWith('@')) {
      final file = File(arg.substring(1));
      if (file.existsSync()) {
        expanded.addAll(file.readAsLinesSync());
        continue;
      }
    }
    expanded.add(arg);
  }
  return expanded;
}

void main(List<String> argv) {
  var scheme = '';
  var output = '';
  final records = <PackageRecord>[];
  final List<String> args = expandParamFiles(argv);
  for (var i = 0; i < args.length; i++) {
    final String arg = args[i];
    if (arg == _schemeFlag && i + 1 < args.length) {
      scheme = args[++i];
    } else if (arg == _outputFlag && i + 1 < args.length) {
      output = args[++i];
    } else if (arg == _recordFlag && i + 1 < args.length) {
      records.add(parsePackageRecord(args[++i]));
    } else {
      stderr.writeln('package_config: unexpected argument $arg.');
      exitCode = 64;
      return;
    }
  }
  if (scheme.isEmpty || output.isEmpty) {
    stderr.writeln(
      'package_config: $_schemeFlag and $_outputFlag are required.',
    );
    exitCode = 64;
    return;
  }
  File(output).writeAsStringSync(buildPackageConfig(records, scheme));
}
