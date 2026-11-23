/// Reading the dependency-floor table and the `bazel_dep` declarations that
/// it governs.
///
/// Both the root floor guard and `e2e/min_versions` read the same checked-in
/// table and the same `MODULE.bazel` shape, so the parser lives here once.
/// Every failure names the call or field it could not read; nothing is
/// skipped silently.
library;

import 'dart:convert';

/// A `bazel_dep` declaration from a `MODULE.bazel`.
class Dependency {
  new(this.name, this.version, this.dev);

  /// The module name.
  final String name;

  /// The declared version, which is the supported floor in this repository.
  final String version;

  /// Whether the declaration is a `dev_dependency` (not inherited by
  /// consumers, so it carries no floor).
  final bool dev;
}

/// One entry of `dependency_floors.json`.
class Floor {
  new(this.floor, this.current, this.resolved, this.liftedBy, this.symbol);

  /// The minimum version this repository supports.
  final String floor;

  /// The release this repository itself builds against, through a root-only
  /// `single_version_override`.
  final String current;

  /// The version a consumer graph resolves: the floor unless [liftedBy] names
  /// a module whose own requirement is higher.
  final String resolved;

  /// Modules whose own `bazel_dep` raises [resolved] above [floor].
  final List<String> liftedBy;

  /// The symbol, package or attribute that makes [floor] the minimum.
  final String symbol;
}

/// The body of every `kind(...)` call in [source], matched on balanced
/// parentheses so a multi-line call is read whole.
List<String> _calls(String source, String kind) {
  final bodies = <String>[];
  final start = RegExp('\\b$kind\\s*\\(');
  for (final RegExpMatch match in start.allMatches(source)) {
    var depth = 1;
    int i = match.end;
    String? quote;
    while (i < source.length && depth > 0) {
      final String ch = source[i];
      if (quote != null) {
        if (ch == r'\' && i + 1 < source.length) {
          i += 2;
          continue;
        }
        if (ch == quote) quote = null;
      } else if (ch == '"' || ch == "'") {
        quote = ch;
      } else if (ch == '(') {
        depth++;
      } else if (ch == ')') {
        depth--;
      }
      i++;
    }
    if (depth != 0) {
      throw StateError('unterminated $kind( call in MODULE.bazel');
    }
    bodies.add(source.substring(match.end, i - 1));
  }
  return bodies;
}

/// The value of `name = "..."` in [body], or null when absent.
String? _stringAttribute(String body, String name) {
  final RegExpMatch? match = RegExp('\\b$name\\s*=\\s*"([^"]*)"')
      .firstMatch(body);
  return match?.group(1);
}

/// Whether [body] carries `dev_dependency = True`.
bool _isDev(String body) =>
    RegExp(r'\bdev_dependency\s*=\s*True\b').hasMatch(body);

/// Every `bazel_dep` in [source], in file order.
List<Dependency> dependencies(String source) {
  final deps = <Dependency>[];
  for (final String body in _calls(source, 'bazel_dep')) {
    final String? name = _stringAttribute(body, 'name');
    final String? version = _stringAttribute(body, 'version');
    if (name == null || version == null) {
      throw StateError('bazel_dep without name/version: $body');
    }
    deps.add(Dependency(name, version, _isDev(body)));
  }
  return deps;
}

/// Every `single_version_override` in [source], keyed by module name.
Map<String, String> overrides(String source) {
  final found = <String, String>{};
  for (final String body in _calls(source, 'single_version_override')) {
    final String? module = _stringAttribute(body, 'module_name');
    final String? version = _stringAttribute(body, 'version');
    if (module == null || version == null) {
      throw StateError('single_version_override without module/version: $body');
    }
    found[module] = version;
  }
  return found;
}

/// Parse the checked-in table, failing when an entry lacks a field instead of
/// silently skipping it.
Map<String, Floor> parseFloors(String source) {
  final dynamic decoded = jsonDecode(source);
  if (decoded is! Map<String, dynamic>) {
    throw StateError('dependency_floors.json is not a JSON object');
  }
  final floors = <String, Floor>{};
  decoded.forEach((name, value) {
    if (value is! Map<String, dynamic>) {
      throw StateError('floor entry for $name is not an object');
    }
    String field(String key) {
      final dynamic entry = value[key];
      if (entry is! String || entry.isEmpty) {
        throw StateError('floor entry for $name has no $key');
      }
      return entry;
    }

    final dynamic lifted = value['lifted_by'];
    if (lifted is! List || lifted.any((module) => module is! String)) {
      throw StateError('floor entry for $name has no lifted_by string list');
    }
    floors[name] = Floor(
      field('floor'),
      field('current'),
      field('resolved'),
      List<String>.from(lifted),
      field('symbol'),
    );
  });
  return floors;
}
