// Generates a `package_config.json` for one kernel module from its closure's
// package records, either through this binary or, as `kernel_module` does for
// every library module, through `materializePackageConfig` on a worker request.
//
// A chain of N `dart_library` targets used to format N package records into a
// JSON string in Starlark once per target, then to run one process per target
// to write it. The rule now passes the transitive records as `--record`
// arguments of the module request (`args.add_all` with `map_each`, expanded at
// execution) and the module worker writes the file it compiles against, so
// analysis holds only a depset reference and no extra action runs.
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

/// The record argument, once per package record in closure order. A worker
/// request names its records with it too; `kernel_module` writes the file its
/// `--packages-file` names from them.
const _recordFlag = '--record';

/// The worker request's package config path.
const _packagesFlag = '--packages-file';

/// The worker request's multi-root URI scheme.
const _schemeFlag = '--multi-root-scheme';

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

/// Removes the `--record` arguments from [args] and, when there were
/// any, writes the `--packages-file` they describe, under the
/// `--multi-root-scheme` the same request names.
///
/// Returns the remaining arguments, or null with a message in [log] when
/// records came without either flag. A request without records is returned
/// untouched and no file is written.
List<String>? materializePackageConfig(List<String> args, StringBuffer log) {
  final rest = <String>[];
  final records = <PackageRecord>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == _recordFlag && i + 1 < args.length) {
      records.add(parsePackageRecord(args[++i]));
    } else {
      rest.add(args[i]);
    }
  }
  if (records.isEmpty) return args;
  final int file = rest.indexOf(_packagesFlag);
  final int scheme = rest.indexOf(_schemeFlag);
  if (file < 0 ||
      scheme < 0 ||
      file + 1 >= rest.length ||
      scheme + 1 >= rest.length) {
    log.writeln(
      'kernel_module: $_recordFlag needs $_packagesFlag and $_schemeFlag.',
    );
    return null;
  }
  File(rest[file + 1])
      .writeAsStringSync(buildPackageConfig(records, rest[scheme + 1]));
  return rest;
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

/// Writes the config a request of `--record`, `--packages-file` and
/// `--multi-root-scheme` arguments describes, as `kernel_module` does.
void main(List<String> argv) {
  final List<String> args = expandParamFiles(argv);
  final log = StringBuffer();
  final List<String>? rest = materializePackageConfig(args, log);
  if (rest == null || identical(rest, args)) {
    stderr.write(
      log.isEmpty
          ? 'package_config: pass $_recordFlag, $_packagesFlag and '
                '$_schemeFlag.\n'
          : log,
    );
    exitCode = 64;
  }
}
