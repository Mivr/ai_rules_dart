/// `maven-lock-unpinned`: an e2e `maven.install` whose artifacts are not
/// pinned by a checked-in lock file with a sha256 for each of them.
library;

import 'dart:convert';

import 'package:inventory/finding.dart';
import 'package:inventory/source_tree.dart';
import 'package:inventory/starlark.dart';

/// The rule's name in debt files and allow comments.
const String mavenLockRule = 'maven-lock-unpinned';

final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

typedef _Coordinate = ({
  String group,
  String artifact,
  String version,
  String text,
});

typedef _Install = ({
  String name,
  int offset,
  List<String> lockFiles,
  List<_Coordinate> declared,
});

/// Checks every `maven.install` in `<module>/e2e/*` and `<module>/e2e/*/*`.
/// A tree without any install has nothing to check: the Android workspaces
/// take their Maven artifacts by hash from a pinned Gradle model.
///
/// Each install must name one `lock_file` inside its workspace. The lock must
/// exist, be a JSON object of version 2 or 3 with artifacts, carry a 64-hex
/// sha256 for every artifact, and pin every declared coordinate at its
/// declared version, directly or through `conflict_resolution`.
List<Finding> checkMavenLocks(SourceTree tree, {required String module}) {
  final modulePattern = RegExp('^$module/e2e/[^/]+(/[^/]+)?/MODULE\\.bazel\$');
  final findings = <Finding>[];
  for (final String path in tree.paths.where(modulePattern.hasMatch)) {
    final String text = tree.read(path);
    final lines = Lines(text);
    final String workspace = path.substring(
      0,
      path.length - '/MODULE.bazel'.length,
    );
    for (final _Install install in _installs(text)) {
      for (final String problem in _problems(tree, workspace, install)) {
        final int line = lines.of(install.offset);
        if (isAllowed(lines, mavenLockRule, line)) continue;
        findings.add(
          Finding(
            rule: mavenLockRule,
            file: path,
            line: line,
            message: "install '${install.name}': $problem",
            key: "install '${install.name}': $problem",
          ),
        );
      }
    }
  }
  return findings;
}

List<String> _problems(SourceTree tree, String workspace, _Install install) {
  final problems = <String>[
    for (final _Coordinate c in install.declared)
      if (c.group.isEmpty || c.artifact.isEmpty || c.version.isEmpty)
        "declared artifact '${c.text}' needs an explicit non-empty group, artifact and version",
  ];
  final Set<String> labels = install.lockFiles.toSet();
  if (labels.contains('')) return problems..add('has no lock_file');
  if (labels.length > 1) {
    return problems
      ..add("install blocks disagree on lock_file (${labels.join(', ')})");
  }
  final String label = labels.single;
  if ((label.startsWith('@') && !label.startsWith('@//')) ||
      label.split(RegExp('[/:]')).contains('..')) {
    return problems..add("lock_file '$label' must point inside the workspace");
  }
  final lockPath =
      '$workspace/${label.replaceFirst(RegExp('^@?//'), '').replaceFirst(RegExp('^:'), '').replaceAll(':', '/')}';
  if (!tree.paths.contains(lockPath)) {
    return problems..add('lock file $lockPath is missing');
  }
  return problems..addAll(_lockProblems(tree.read(lockPath), install.declared));
}

List<String> _lockProblems(String json, List<_Coordinate> declared) {
  final Object? lock;
  try {
    lock = jsonDecode(json);
  } on FormatException {
    return ['lock file is not valid JSON'];
  }
  if (lock is! Map<String, Object?>) {
    return ['lock file is not valid JSON (expected a JSON object)'];
  }
  final problems = <String>[];
  if (lock['version'] != '2' && lock['version'] != '3') {
    problems.add("expected lock version 2 or 3, got '${lock['version']}'");
  }
  final Object? artifacts = lock['artifacts'];
  if (artifacts is! Map<String, Object?> || artifacts.isEmpty) {
    return problems..add('lock file has no valid artifacts map');
  }
  final pinned = <String, Set<String>>{};
  for (final MapEntry<String, Object?> e in artifacts.entries) {
    final Object? entry = e.value;
    final Object? shasums = entry is Map<String, Object?>
        ? entry['shasums']
        : null;
    if (shasums is! Map<String, Object?> ||
        shasums.isEmpty ||
        shasums.values.any((s) => s is! String || !_hex64.hasMatch(s))) {
      problems.add("artifact '${e.key}' has no 64-hex sha256 under shasums");
    }
    final List<String> parts = e.key.split(':');
    final Object? version = entry is Map<String, Object?>
        ? entry['version']
        : null;
    if (parts.length >= 2 && version is String) {
      pinned.putIfAbsent('${parts[0]}:${parts[1]}', () => {}).add(version);
    }
  }
  for (final c in declared) {
    if (c.group.isEmpty || c.artifact.isEmpty || c.version.isEmpty) continue;
    final ga = '${c.group}:${c.artifact}';
    final Set<String>? versions = pinned[ga];
    if (versions == null) {
      problems.add("declared artifact '${c.text}' ($ga) is absent from lock");
    } else if (!_isPinned(
      ga,
      c.version,
      versions,
      lock['conflict_resolution'],
    )) {
      problems.add(
        "declared artifact '${c.text}' ($ga) version '${c.version}' is not "
        'pinned in lock (lock has ${(versions.toList()..sort()).join(', ')})',
      );
    }
  }
  return problems;
}

bool _isPinned(
  String ga,
  String version,
  Set<String> pinned,
  Object? conflicts,
) {
  if (pinned.contains(version)) return true;
  if (conflicts is! Map<String, Object?>) return false;
  final Object? resolved = conflicts['$ga:$version'];
  return resolved is String &&
      resolved.startsWith('$ga:') &&
      pinned.contains(resolved.substring(ga.length + 1));
}

/// The installs of a `MODULE.bazel`, grouped by install name.
List<_Install> _installs(String text) {
  final String code = blank(text, blankStrings: false);
  final String blanked = blank(text);
  final Set<String> receivers = {
    'maven',
    for (final RegExpMatch m in RegExp(
      r'''(\w+)\s*=\s*use_extension\([^)]*(['"])maven\2''',
    ).allMatches(code))
      m.group(1)!,
  };
  final calls = RegExp(
    '\\b(?:${receivers.join('|')})\\s*\\.\\s*(install|artifact)\\s*\\(',
  );
  final installs = <String, _Install>{};
  final inside = <(int, int)>[];
  final tags = <(int, String)>[];
  for (final RegExpMatch m in calls.allMatches(blanked)) {
    final int close = closingParen(blanked, m.end - 1);
    if (close < 0) break;
    final String args = code.substring(m.end, close);
    if (m.group(1) == 'install') {
      inside.add((m.start, close));
      final String top = topLevel(args);
      final String name = _attribute(top, 'name') ?? 'maven';
      final _Install install = installs.putIfAbsent(
        name,
        () => (name: name, offset: m.start, lockFiles: [], declared: []),
      );
      install.lockFiles.add(_attribute(top, 'lock_file') ?? '');
      install.declared.addAll(
        _artifactsAttribute(args, calls, blanked.substring(m.end, close)),
      );
    } else {
      tags.add((m.start, args));
    }
  }
  for (final (int start, String args) in tags) {
    if (inside.any((r) => r.$1 < start && start < r.$2)) continue;
    final String top = topLevel(args);
    installs[_attribute(top, 'name') ?? 'maven']?.declared.add(_tag(top));
  }
  return installs.values.toList();
}

String? _attribute(String top, String name) =>
    RegExp('\\b$name\\s*=\\s*([\'"])([^\'"]*)\\1').firstMatch(top)?.group(2);

_Coordinate _tag(String top) {
  final String group = _attribute(top, 'group') ?? '';
  final String artifact = _attribute(top, 'artifact') ?? '';
  final String version = _attribute(top, 'version') ?? '';
  return (
    group: group,
    artifact: artifact,
    version: version,
    text: [group, artifact, version].where((p) => p.isNotEmpty).join(':'),
  );
}

/// The coordinates of `artifacts = [...] + [...]`: the `maven.artifact(...)`
/// tags and the plain `"group:artifact:version"` strings.
List<_Coordinate> _artifactsAttribute(
  String args,
  RegExp calls,
  String blanked,
) {
  final coordinates = <_Coordinate>[];
  final RegExpMatch? start = RegExp(r'\bartifacts\s*=\s*\[')
      .firstMatch(blanked);
  if (start == null) return coordinates;
  int open = start.end - 1;
  while (open >= 0) {
    final int close = closing(blanked, open, '[', ']');
    if (close < 0) break;
    String body = args.substring(open + 1, close);
    final String bodyBlank = blanked.substring(open + 1, close);
    for (final RegExpMatch tag in calls.allMatches(bodyBlank)) {
      final int end = closingParen(bodyBlank, tag.end - 1);
      if (end < 0) break;
      coordinates.add(_tag(topLevel(body.substring(tag.end, end))));
      body = body.replaceRange(tag.start, end + 1, ' ' * (end + 1 - tag.start));
    }
    for (final RegExpMatch s in RegExp(
      '([\'"])([^\'"]*)\\1',
    ).allMatches(body)) {
      final List<String> parts = s.group(2)!.split(':');
      final bool complete =
          parts.length >= 3 && parts.every((p) => p.isNotEmpty);
      coordinates.add((
        group: parts[0],
        artifact: parts.length >= 2 ? parts[1] : '',
        version: complete ? parts.last : '',
        text: s.group(2)!,
      ));
    }
    final RegExpMatch? next = RegExp(r'^\s*\+\s*\[')
        .firstMatch(args.substring(close + 1));
    if (next == null) break;
    open = close + 1 + next.end - 1;
  }
  return coordinates;
}
