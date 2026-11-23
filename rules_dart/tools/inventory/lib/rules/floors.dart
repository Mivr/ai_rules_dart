/// `bazel-dep-floor`: a `bazel_dep` that declares a release instead of the
/// minimum the repository supports.
library;

import 'dart:convert';

import 'package:inventory/finding.dart';
import 'package:inventory/source_tree.dart';
import 'package:inventory/starlark.dart';

/// The rule's name in debt files and allow comments.
const String bazelDepFloorRule = 'bazel-dep-floor';

/// Where one module's floors are recorded.
typedef FloorScope = ({String module, String table});

typedef _Dep = ({String name, String version, bool dev, int offset});

/// The table's entry for one dependency.
typedef _Floor = ({
  String floor,
  String current,
  String resolved,
  List<String> liftedBy,
});

/// Checks the module's `MODULE.bazel` against its checked-in floor table.
///
/// Bzlmod resolves a module to the highest version anywhere in the graph, so
/// a declaration is a floor every consumer inherits. The table records the
/// minimum each regular `bazel_dep` may declare, the release this checkout
/// builds, and who lifts it. A declaration above its floor, a dependency
/// missing from the table (or the reverse), a current release without a
/// root-only `single_version_override`, and a table row that resolves
/// neither at its floor nor through a named lifting module are violations.
List<Finding> checkBazelDepFloors(SourceTree tree, FloorScope scope) {
  final modulePath = '${scope.module}/MODULE.bazel';
  final tablePath = '${scope.module}/${scope.table}';
  final String text = tree.read(modulePath);
  final String code = blank(text, blankStrings: false);
  final lines = Lines(text);
  final Map<String, _Floor> floors = _parseTable(tree.read(tablePath));
  final List<_Dep> deps = _dependencies(code);
  final Map<String, String> overrides = _overrides(code);
  final findings = <Finding>[];
  void add(int offset, String message) {
    final int line = lines.of(offset);
    if (isAllowed(lines, bazelDepFloorRule, line)) return;
    findings.add(
      Finding(
        rule: bazelDepFloorRule,
        file: modulePath,
        line: line,
        message: message,
        key: message,
      ),
    );
  }

  final Map<String, _Dep> regular = {
    for (final _Dep d in deps)
      if (!d.dev) d.name: d,
  };
  for (final MapEntry<String, _Dep> dep in regular.entries) {
    final _Floor? floor = floors[dep.key];
    if (floor == null) {
      add(dep.value.offset, '${dep.key} has no entry in ${scope.table}');
      continue;
    }
    if (dep.value.version != floor.floor) {
      add(
        dep.value.offset,
        '${dep.key} declares ${dep.value.version} but the supported floor is '
        '${floor.floor}; a consumer would be force-upgraded',
      );
    }
    final String? pinned = overrides[dep.key];
    if (floor.current == floor.floor
        ? pinned != null
        : pinned != floor.current) {
      add(
        dep.value.offset,
        floor.current == floor.floor
            ? '${dep.key} is already current at its floor; a root override '
                  'would hide the declared floor'
            : '${dep.key} needs a root-only single_version_override to '
                  '${floor.current}',
      );
    }
  }
  for (final String name in floors.keys) {
    if (!regular.containsKey(name)) {
      add(0, '${scope.table} has an entry for $name, which is no bazel_dep');
    }
  }
  for (final MapEntry<String, _Floor> floor in floors.entries) {
    if (floor.value.liftedBy.isEmpty) {
      if (floor.value.resolved != floor.value.floor) {
        add(0, '${floor.key} has no lift, so it must resolve at its floor');
      }
    } else {
      for (final String module in floor.value.liftedBy) {
        if (!floors.containsKey(module)) {
          add(0, '${floor.key} names the unknown lifting module $module');
        }
      }
    }
  }
  return findings;
}

Map<String, _Floor> _parseTable(String json) {
  final Object? decoded = jsonDecode(json);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('the floor table is not a JSON object');
  }
  return {
    for (final MapEntry<String, Object?> e in decoded.entries)
      e.key: _floor(e.key, e.value),
  };
}

_Floor _floor(String name, Object? value) {
  if (value is! Map<String, Object?>) {
    throw FormatException('floor entry for $name is not an object');
  }
  String field(String key) {
    final Object? v = value[key];
    if (v is! String || v.isEmpty) {
      throw FormatException('floor entry for $name has no $key');
    }
    return v;
  }

  final Object? lifted = value['lifted_by'];
  if (lifted is! List<Object?> || lifted.any((m) => m is! String)) {
    throw FormatException('floor entry for $name has no lifted_by list');
  }
  return (
    floor: field('floor'),
    current: field('current'),
    resolved: field('resolved'),
    liftedBy: lifted.cast<String>(),
  );
}

/// The `(offset, body)` of every `kind(...)` call in [code].
Iterable<(int, String)> _calls(String code, String kind) sync* {
  final start = RegExp('\\b$kind\\s*\\(');
  final String blanked = blank(code);
  for (final RegExpMatch m in start.allMatches(code)) {
    final int close = closingParen(blanked, m.end - 1);
    if (close < 0) throw FormatException('unterminated $kind( call');
    yield (m.start, code.substring(m.end, close));
  }
}

String? _string(String body, String name) =>
    RegExp('\\b$name\\s*=\\s*"([^"]*)"').firstMatch(body)?.group(1);

List<_Dep> _dependencies(String code) => [
  for (final (int offset, String body) in _calls(code, 'bazel_dep'))
    (
      name:
          _string(body, 'name') ??
          (throw FormatException('bazel_dep without a name: $body')),
      version: _string(body, 'version') ?? '',
      dev: RegExp(r'\bdev_dependency\s*=\s*True\b').hasMatch(body),
      offset: offset,
    ),
];

Map<String, String> _overrides(String code) => {
  for (final (int _, String body) in _calls(code, 'single_version_override'))
    if (_string(body, 'module_name') case final String module)
      module: _string(body, 'version') ?? '',
};
