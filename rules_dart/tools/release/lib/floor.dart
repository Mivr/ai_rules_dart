/// The floor `rules_flutter` names on `rules_dart`, in every place it is
/// written down.
///
/// Inside the repository the number is inert: every build takes `rules_dart/`
/// through a path override. For a consumer it is the first `rules_dart`
/// release that has what `rules_flutter` loads. `rules_flutter/MODULE.bazel`
/// is the source; [checkFloor] fails when another place disagrees, and
/// [setFloor] writes one version everywhere.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// A file, and a pattern whose capture groups are all the floor.
final class FloorSite {
  /// Creates a site.
  const FloorSite(this.path, this.pattern, this.what);

  /// The file, from the repository root.
  final String path;

  /// Every capture group is a floor version.
  final String pattern;

  /// What the place is, for the messages.
  final String what;
}

/// The fixed sites. Every `rules_flutter/**/MODULE.bazel` that names
/// `ai_rules_dart` is a site too ([moduleFileSites]).
const floorSites = <FloorSite>[
  FloorSite(
    'rules_flutter/flutter/tests/dependency_floors.json',
    r'"ai_rules_dart": \{\s*"floor": "([^"]+)",\s*"current": "([^"]+)",'
        r'\s*"resolved": "([^"]+)"',
    'floor table',
  ),
  FloorSite(
    'rules_flutter/docs/dependencies.md',
    r'\| `ai_rules_dart` \(repo `rules_dart`\) \| ([0-9][^ |]*) \|',
    'dependency table',
  ),
  FloorSite(
    'rules_flutter/docs/ARCHITECTURE.md',
    r'comes from `ai_rules_dart` ([0-9][^ ,`]*),',
    'architecture note',
  ),
  FloorSite(
    'rules_flutter/README.md',
    r'Its floor is `ai_rules_dart` ([0-9][^ ,`]*)[ ,]',
    'README floor sentence',
  ),
  FloorSite(
    'rules_flutter/README.md',
    r'\| Every app \| `ai_rules_dart` ([0-9][^ `]*) ',
    'README module table',
  ),
  FloorSite(
    'rules_flutter/README.md',
    r'bazel_dep\(name = "ai_rules_dart", version = "([^"]+)"',
    'README override snippet',
  ),
];

/// The `bazel_dep` of `rules_dart` in a module file.
final _moduleDep = RegExp(
  r'bazel_dep\(name = "ai_rules_dart", version = "([^"]+)"',
);

const _ownModule = 'rules_flutter/MODULE.bazel';

/// The module files under `rules_flutter/` (from [root]) that depend on
/// `ai_rules_dart`, as paths from [root] with `/`; the module's own is first.
///
/// A workspace that declares version `0.0.0` (the number of a module that a
/// path override takes, as the test workspaces of `rules_dart` do) names no
/// floor and is left out.
List<String> moduleFileSites(String root) {
  final sites = <String>[];
  void walk(Directory dir) {
    for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
      final String name = p.basename(e.path);
      if (e is Directory) {
        if (name.startsWith('.') ||
            name.startsWith('bazel-') ||
            name == 'node_modules') {
          continue;
        }
        walk(e);
      } else if (e is File && name == 'MODULE.bazel') {
        final String? version = _moduleDep
            .firstMatch(e.readAsStringSync())
            ?.group(1);
        if (version != null && version != '0.0.0') {
          sites.add(p.posix.joinAll(p.split(p.relative(e.path, from: root))));
        }
      }
    }
  }

  walk(Directory(p.join(root, 'rules_flutter')));
  sites.sort((a, b) {
    if (a == _ownModule) return -1;
    if (b == _ownModule) return 1;
    return a.compareTo(b);
  });
  return sites;
}

/// The floor `rules_flutter/MODULE.bazel` declares.
String declaredFloor(String root) {
  final String text = File(p.join(root, _ownModule)).readAsStringSync();
  final RegExpMatch? m = _moduleDep.firstMatch(text);
  if (m == null) {
    throw StateError('$_ownModule has no bazel_dep on ai_rules_dart');
  }
  return m[1]!;
}

/// Every place that disagrees with [declaredFloor] or has lost its text.
List<String> checkFloor(String root) {
  final String floor = declaredFloor(root);
  final problems = <String>[];
  void check(String path, RegExp pattern, String what) {
    final String text = File(p.join(root, path)).readAsStringSync();
    final Iterable<RegExpMatch> matches = pattern.allMatches(text);
    if (matches.isEmpty) {
      problems.add('$path: the $what is gone (${pattern.pattern})');
    }
    for (final m in matches) {
      for (var i = 1; i <= m.groupCount; i++) {
        if (m[i] != floor) {
          problems.add('$path: the $what says ${m[i]}, not $floor');
        }
      }
    }
  }

  for (final s in floorSites) {
    check(s.path, RegExp(s.pattern), s.what);
  }
  for (final path in moduleFileSites(root)) {
    check(path, _moduleDep, 'bazel_dep on ai_rules_dart');
  }
  return problems;
}

/// Writes [version] (`0.29.0`, no `v`) at every site. Returns the files it
/// changed, from [root].
List<String> setFloor(String root, String version) {
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
    throw FormatException('Floor must look like 1.2.3, got "$version"');
  }
  final changed = <String>[];
  void rewrite(String path, RegExp pattern, String what) {
    final File f = File(p.join(root, path));
    final String text = f.readAsStringSync();
    if (!pattern.hasMatch(text)) {
      throw StateError('$path: the $what is gone (${pattern.pattern})');
    }
    final String out = text.replaceAllMapped(pattern, (m) {
      // The groups come in order and the text between them is fixed, so each
      // group is found after the one before it.
      final String whole = m[0]!;
      final result = StringBuffer();
      var from = 0;
      for (var i = 1; i <= m.groupCount; i++) {
        final int at = whole.indexOf(m[i]!, from);
        result
          ..write(whole.substring(from, at))
          ..write(version);
        from = at + m[i]!.length;
      }
      return (result..write(whole.substring(from))).toString();
    });
    if (out != text) {
      f.writeAsStringSync(out);
      if (!changed.contains(path)) changed.add(path);
    }
  }

  for (final s in floorSites) {
    rewrite(s.path, RegExp(s.pattern), s.what);
  }
  for (final path in moduleFileSites(root)) {
    rewrite(path, _moduleDep, 'bazel_dep on ai_rules_dart');
  }
  return changed;
}
