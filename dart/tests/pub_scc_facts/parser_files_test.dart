import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Guard that the pub cycle-planning facts digest covers the pubspec parser.
///
/// Fact keys embed a digest of `dart/pub/yaml_parser.bzl` and every `.bzl`
/// file it loads, transitively (see `parser_schema` in
/// `dart/pub/private/pub_scc_facts.bzl` and `PARSER_SOURCE_LABELS` in
/// `dart/pub/private/parser_sources.bzl`). A new `load` in `yaml_parser.bzl` that is not
/// added to the digested inputs would silently reuse facts the old parser
/// recorded, so this test fails when the label list differs from the actual
/// load closure. It runs unsandboxed over the live tree like
/// `download_digest_guard_test.dart`: the workspace root comes from a
/// runfiles-resolved anchor (this test's own source, passed as an
/// `rlocationpath` argument and declared in `data`).
void main(List<String> args) {
  group('parser files', () {
    test('the digested labels match the parser load closure', () {
      final root = _workspaceRoot(args);
      final closure = _loadClosure(root, 'dart/pub/yaml_parser.bzl');
      final labels = _digestedLabels(root);
      expect(
        labels,
        closure,
        reason:
            'update PARSER_SOURCE_LABELS in '
            'dart/pub/private/parser_sources.bzl to '
            'match the load closure of dart/pub/yaml_parser.bzl; '
            'closure=$closure labels=$labels',
      );
    });

    test('every digested file exists', () {
      final root = _workspaceRoot(args);
      for (final rel in _digestedLabels(root)) {
        expect(
          File('$root/$rel').existsSync(),
          isTrue,
          reason: 'digested file $rel must exist',
        );
      }
    });
  });

  group('guard unit tests', () {
    test('a new transitive load joins the closure', () {
      final files = {
        'dart/pub/yaml_parser.bzl': 'load("//dart/pub/private:a.bzl", "x")\n',
        'dart/pub/private/a.bzl': 'load(":b.bzl", "y")\n',
        'dart/pub/private/b.bzl': 'x = 1\n',
      };
      expect(_closureOf(files, 'dart/pub/yaml_parser.bzl'), {
        'dart/pub/yaml_parser.bzl',
        'dart/pub/private/a.bzl',
        'dart/pub/private/b.bzl',
      });
    });

    test('a label outside the list block is not digested', () {
      const extensions =
          'PARSER_SOURCE_LABELS = [\n'
          '    Label(":yaml_parser.bzl"),\n'
          ']\n'
          'other = Label(":elsewhere.bzl")\n';
      expect(_labelsInBlock(extensions), ['dart/pub/private/yaml_parser.bzl']);
    });
  });
}

/// The load closure of the parser: itself plus every `.bzl` its loads reach.
Set<String> _loadClosure(String root, String entry) {
  final files = <String, String>{};
  final found = <String>[];
  _walkForBzl(Directory('$root/dart/pub'), found);
  for (final path in found) {
    final rel = _relative(root, File(path));
    files[rel] = File(path).readAsStringSync();
  }
  return _closureOf(files, entry);
}

/// The workspace-relative paths `PARSER_SOURCE_LABELS` in parser_sources.bzl digests.
Set<String> _digestedLabels(String root) {
  final text = File('$root/dart/pub/private/parser_sources.bzl')
      .readAsStringSync();
  return _labelsInBlock(text).toSet();
}

/// The `Label("...")` strings inside the `PARSER_SOURCE_LABELS` block,
/// resolved against package `dart/pub/private`.
List<String> _labelsInBlock(String extensions) {
  final start = extensions.indexOf('PARSER_SOURCE_LABELS = [');
  if (start == -1) {
    fail('no PARSER_SOURCE_LABELS list in dart/pub/private/parser_sources.bzl');
  }
  final open = extensions.indexOf('[', start);
  final close = _matchingBracket(extensions, open);
  if (close == -1) fail('the PARSER_SOURCE_LABELS list never closes');
  final block = extensions.substring(open, close + 1);
  return [
    for (final m in RegExp(r'Label\("([^"]+)"\)').allMatches(block))
      _resolveIn('dart/pub/private/parser_sources.bzl', m.group(1)!),
  ];
}

/// The transitive load closure of [entry] over workspace-relative [files].
Set<String> _closureOf(Map<String, String> files, String entry) {
  final seen = {entry};
  final queue = [entry];
  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    for (final label in _loadsOf(files[current] ?? '')) {
      final resolved = _resolveIn(current, label);
      if (resolved.startsWith('@')) {
        fail(
          'load of $resolved from $current reaches outside the workspace; '
          'the facts digest cannot cover it',
        );
      }
      if (seen.add(resolved)) queue.add(resolved);
    }
  }
  return seen;
}

/// The loaded file labels of one Starlark source: the first string of each
/// `load(` call.
List<String> _loadsOf(String text) => [
  for (final m in RegExp(r'load\(\s*"([^"]+)"').allMatches(text)) m.group(1)!,
];

/// Resolves a load or `Label("...")` string against the workspace-relative
/// file holding it. `@`-labels keep their `@` prefix for the caller to reject.
String _resolveIn(String from, String label) {
  if (label.startsWith('@')) return label;
  if (label.startsWith('//')) {
    final path = label.substring(2);
    final colon = path.indexOf(':');
    if (colon == -1) return '$path/${path.split('/').last}';
    return '${path.substring(0, colon)}/${path.substring(colon + 1)}';
  }
  final dir = from.contains('/')
      ? from.substring(0, from.lastIndexOf('/'))
      : '';
  final colon = label.indexOf(':');
  if (colon == -1) return dir.isEmpty ? label : '$dir/$label';
  final pkg = label.substring(0, colon);
  final file = label.substring(colon + 1);
  final base = pkg.isEmpty ? dir : '$dir/$pkg';
  return base.isEmpty ? file : '$base/$file';
}

/// The offset of the `]` closing the `[` at [open], or -1.
int _matchingBracket(String text, int open) {
  var depth = 0;
  for (var i = open; i < text.length; i++) {
    if (text[i] == '[') depth++;
    if (text[i] == ']') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// Every `.bzl` file path under [dir], sorted.
void _walkForBzl(Directory dir, List<String> found) {
  List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } on FileSystemException {
    return;
  }
  entries.sort((a, b) => a.path.compareTo(b.path));
  for (final entry in entries) {
    final name = entry.path.split(Platform.pathSeparator).last;
    if (name.startsWith('.') || name.startsWith('bazel-')) continue;
    if (entry is File) {
      if (entry.path.endsWith('.bzl')) found.add(entry.path);
    } else if (entry is Directory) {
      _walkForBzl(entry, found);
    }
  }
}

/// The `file:line`-style relative path of [file] under [root], always with
/// forward slashes.
String _relative(String root, File file) {
  var base = root.replaceAll('\\', '/');
  var rel = file.path.replaceAll('\\', '/');
  if (rel.startsWith(base)) rel = rel.substring(base.length);
  while (rel.startsWith('/')) {
    rel = rel.substring(1);
  }
  return rel;
}

/// Locates the source-tree workspace root from the runfiles anchor or the
/// ancestor walk. Mirrors `download_digest_guard_test.dart`.
String _workspaceRoot(List<String> args) {
  if (args.isNotEmpty) {
    try {
      final located = Runfiles.create().rlocation(args.first);
      if (File(located).existsSync()) {
        final root = _sourceRootAbove(Directory(located).parent.path);
        if (root != null) return root;
      }
    } catch (_) {}
  }
  final env = Platform.environment;
  for (final start in [
    env['BUILD_WORKSPACE_DIRECTORY'],
    env['BUILD_WORKING_DIRECTORY'],
    Directory.current.path,
  ]) {
    final root = _sourceRootAbove(start);
    if (root != null) return root;
  }
  fail('cannot locate the workspace root; the guard must run unsandboxed');
}

/// The source-tree workspace root at or above [start], or null when none.
String? _sourceRootAbove(String? start) {
  var dir = start == null ? null : Directory(start);
  while (dir != null) {
    final module = File('${dir.path}/MODULE.bazel');
    if (module.existsSync()) {
      final root = File(module.resolveSymbolicLinksSync()).parent.path;
      if (FileSystemEntity.typeSync('$root/dart', followLinks: false) ==
          FileSystemEntityType.directory) {
        return root;
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
  return null;
}
