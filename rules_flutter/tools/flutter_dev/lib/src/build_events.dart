/// Reads the JSON build event file Bazel writes with `--build_event_json_file`.
library;

import 'dart:convert';
import 'dart:io';

/// What a build produced, by top-level target and output group.
class BuildOutputs {
  /// The outputs in [_groups], relative to [execRoot].
  new(this.execRoot, this._groups);

  /// Reads [file]. Throws a [FormatException] for a file that is not a build event file.
  factory read(File file) => BuildOutputs.parse(file.readAsLinesSync());

  /// Reads the lines of a build event file.
  factory parse(Iterable<String> lines) {
    String? execRoot;
    final sets = <String, ({List<String> files, List<String> children})>{};
    final completions =
        <(String, String, String)>[]; // (label, group, file set id)
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final event = jsonDecode(line) as Map<String, Object?>;
      final Map<String, Object?> id =
          (event['id'] as Map<String, Object?>?) ?? const <String, Object?>{};
      final workspace = event['workspaceInfo'] as Map<String, Object?>?;
      if (workspace != null) execRoot = workspace['localExecRoot'] as String?;
      final set = event['namedSetOfFiles'] as Map<String, Object?>?;
      if (set != null) {
        final setId =
            (id['namedSet']! as Map<String, Object?>)['id']! as String;
        sets[setId] = (
          files: <String>[
            for (final f
                in (set['files'] as List<Object?>?) ?? const <Object?>[])
              _path(f! as Map<String, Object?>),
          ],
          children: <String>[
            for (final s
                in (set['fileSets'] as List<Object?>?) ?? const <Object?>[])
              (s! as Map<String, Object?>)['id']! as String,
          ],
        );
      }
      final completed = event['completed'] as Map<String, Object?>?;
      final target = id['targetCompleted'] as Map<String, Object?>?;
      if (completed != null && target != null) {
        final String label = normalizeLabel(target['label']! as String);
        for (final Object? g
            in (completed['outputGroup'] as List<Object?>?) ??
                const <Object?>[]) {
          final group = g! as Map<String, Object?>;
          for (final Object? s
              in (group['fileSets'] as List<Object?>?) ?? const <Object?>[]) {
            completions.add((
              label,
              group['name']! as String,
              (s! as Map<String, Object?>)['id']! as String,
            ));
          }
        }
      }
    }
    if (execRoot == null) {
      throw const FormatException(
        'the build event file names no execution root (workspaceInfo)',
      );
    }
    final groups = <String, Map<String, List<String>>>{};
    for (final (label, group, setId) in completions) {
      final seen = <String>{};
      void expand(String id, List<String> into) {
        if (!seen.add(id)) return;
        final ({List<String> children, List<String> files})? set = sets[id];
        if (set == null) return;
        into.addAll(set.files);
        for (final String c in set.children) {
          expand(c, into);
        }
      }

      expand(
        setId,
        groups
            .putIfAbsent(label, () => <String, List<String>>{})
            .putIfAbsent(group, () => <String>[]),
      );
    }
    return BuildOutputs(execRoot, groups);
  }

  /// The execution root of the workspace: output paths are relative to it.
  final String execRoot;

  final Map<String, Map<String, List<String>>> _groups;

  /// The output base, which holds `external/` with every external repository.
  String get outputBase => File(execRoot).parent.parent.path;

  /// The files of [group] of [label], relative to [execRoot], in build event order and without
  /// repeats. An aspect's groups are reported under the target it ran on.
  List<String> files(String label, String group) =>
      <String>{...?_groups[normalizeLabel(label)]?[group]}.toList();

  /// The files of [group] of every top-level target.
  List<String> allFiles(String group) => <String>{
    for (final g in _groups.values) ...?g[group],
  }.toList();

  /// The absolute path of an output path.
  String absolute(String path) => '$execRoot/$path';

  static String _path(Map<String, Object?> file) => <Object?>[
    ...((file['pathPrefix'] as List<Object?>?) ?? const <Object?>[]),
    file['name'],
  ].join('/');
}

/// A main-repository label without its `@@` or `@` prefix, so that `@@//:a`, `@//:a` and `//:a`
/// compare equal.
String normalizeLabel(String label) {
  if (label.startsWith('@@//')) return label.substring(2);
  if (label.startsWith('@//')) return label.substring(1);
  return label;
}
