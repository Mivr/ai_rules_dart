/// The one layout both builders write and the comparison reads.
///
///     <work>/<side>/<project>/<kind>/
///       status.json      what was run, whether it built, and why not
///       log.txt          every command's output
///       tests.json       `tests`: [{suite, name, result}]
///       diagnostics.json `analysis`: {files: [...], diagnostics: [...]}
///       runs.json        `exe`: [{args, stdout, stderr, exit}]
///       tree/            `web`, `linux`: the output directory
///       app.apk          `apk`: the debug APK
///
/// Nothing in it says how it was made: the comparison reads only these
/// files.
library;

import 'dart:convert';
import 'dart:io';

/// A kind of output, compared on its own.
enum Kind {
  tests,
  analysis,
  exe,
  web,
  apk,
  linux;

  /// The kind named [name], or a [FormatException].
  static Kind parse(String name) => Kind.values.firstWhere(
    (k) => k.name == name,
    orElse: () => throw FormatException('unknown kind: $name'),
  );
}

/// The two builders.
enum Side { stock, rules }

/// Whether one side produced one kind of output, and why not.
class Status {
  Status({
    required this.built,
    this.reason,
    this.commands = const [],
    this.seconds = 0,
    this.notes = const [],
  });

  /// Reads a `status.json`.
  factory Status.fromJson(Map<String, Object?> json) => Status(
    built: json['built'] as bool,
    reason: json['reason'] as String?,
    commands: [
      for (final c in json['commands'] as List? ?? const []) c as String,
    ],
    seconds: (json['seconds'] as num? ?? 0).toDouble(),
    notes: [for (final n in json['notes'] as List? ?? const []) n as String],
  );

  /// Whether the output exists.
  final bool built;

  /// One line saying why not, when [built] is false; or a partial failure.
  final String? reason;

  /// The commands run, in order, as display strings.
  final List<String> commands;

  /// Wall time of the commands.
  final double seconds;

  /// Facts worth showing next to the score (a target that did not build).
  final List<String> notes;

  Map<String, Object?> toJson() => {
    'built': built,
    if (reason != null) 'reason': reason,
    'commands': commands,
    'seconds': double.parse(seconds.toStringAsFixed(1)),
    if (notes.isNotEmpty) 'notes': notes,
  };
}

/// The directory of one side, project and kind.
class KindDir {
  KindDir(String work, Side side, String project, Kind kind)
    : dir = Directory('$work/${side.name}/$project/${kind.name}');

  /// Wraps an existing directory (tests).
  KindDir.at(this.dir);

  final Directory dir;

  File get statusFile => File('${dir.path}/status.json');
  File get log => File('${dir.path}/log.txt');
  File get tests => File('${dir.path}/tests.json');
  File get diagnostics => File('${dir.path}/diagnostics.json');
  File get runs => File('${dir.path}/runs.json');
  Directory get tree => Directory('${dir.path}/tree');
  File get apk => File('${dir.path}/app.apk');

  /// Empties the directory for a new build.
  void reset() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
  }

  /// The status, or null when this side never ran for this kind.
  Status? readStatus() => statusFile.existsSync()
      ? Status.fromJson(
          jsonDecode(statusFile.readAsStringSync()) as Map<String, Object?>,
        )
      : null;

  void writeStatus(Status status) => writeJson(statusFile, status.toJson());
}

/// Writes [value] as indented JSON, so a layout can be read by eye.
void writeJson(File file, Object? value) {
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(value)}\n',
  );
}

/// Reads a JSON file.
Object? readJson(File file) => jsonDecode(file.readAsStringSync());
