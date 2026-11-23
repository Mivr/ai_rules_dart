/// Command-line plumbing shared by the two commands.
library;

import 'dart:io';

/// The flags of one command line: `--name=value` and bare `--name`.
class Flags {
  /// Parses [args], rejecting any flag not in [known] and any positional.
  factory parse(List<String> args, Set<String> known) {
    final values = <String, String>{};
    for (final arg in args) {
      final RegExpMatch? m = RegExp(r'^--([a-z-]+)(?:=(.*))?$').firstMatch(arg);
      if (m == null || !known.contains(m.group(1))) {
        throw FormatException('unknown argument: $arg');
      }
      values[m.group(1)!] = m.group(2) ?? '';
    }
    return Flags._(values);
  }

  new _(this._values);

  final Map<String, String> _values;

  /// Whether `--[name]` was given.
  bool has(String name) => _values.containsKey(name);

  /// The value of `--[name]=value`, or null.
  String? value(String name) => _values[name];
}

/// The repository root: `--root`, else the nearest ancestor of the directory
/// `bazel run` was started in (or the current one) that holds both modules.
String repositoryRoot(Flags flags) {
  final String? given = flags.value('root');
  if (given != null && given.isNotEmpty) return given;
  Directory dir = Directory(
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ?? Directory.current.path,
  ).absolute;
  while (true) {
    if (Directory('${dir.path}/rules_dart').existsSync() &&
        Directory('${dir.path}/rules_flutter').existsSync()) {
      return dir.path;
    }
    if (dir.parent.path == dir.path) {
      throw const FormatException(
        'no directory above here holds rules_dart and rules_flutter; pass --root=DIR',
      );
    }
    dir = dir.parent;
  }
}

/// Where the checked-in data files live, below the repository root.
const String dataDir = 'rules_dart/tools/inventory';
