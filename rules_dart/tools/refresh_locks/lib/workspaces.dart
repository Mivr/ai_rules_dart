/// Finds the Bazel workspaces of this repository: every directory holding a
/// `MODULE.bazel` that Bazel can resolve on its own.
library;

import 'dart:io';

/// Directories that hold a `MODULE.bazel` but are not workspaces of their own,
/// each with the reason. A new directory of that kind fails loudly the first
/// time the tool runs on it, and is added here with its reason.
const skippedWorkspaces = <String, String>{
  'rules_dart/e2e/pub_lock_cross_module/module_b':
      'consumed only from its parent; resolves with the parent\'s overrides',
  'rules_dart/e2e/pub_lock_cross_module/module_c': 'consumed only from its parent; its hub name collides with the parent\'s on purpose',
  'rules_dart/e2e/pub_scanner_intruder/intruder':
      'a non-root module the parent pulls in with `local_path_override`',
  'rules_dart/tools/conformance/overlays/counter':
      'an overlay copied onto a corpus project, which brings its pubspec.lock',
  'rules_dart/tools/conformance/overlays/dart_pkg':
      'an overlay copied onto a corpus project, which brings its pubspec.lock',
  'rules_dart/tools/conformance/overlays/flavors_defines':
      'an overlay copied onto a corpus project, which brings its pubspec.lock',
  'rules_dart/tools/conformance/overlays/large':
      'an overlay copied onto a corpus project, which brings its pubspec.lock',
};

/// The text of Bazel's own warning when a hub names the `file://FIXTURES_ROOT`
/// registry that a CI step or the e2e runner rewrites to a real path.
const _placeholderRegistry = 'Unsupported non-local file URL';

/// Workspaces whose module extension cannot finish in place, with the text the
/// failure must contain: they are red by design, or name a registry that only
/// exists once a CI step has rewritten a placeholder. Bazel records every other
/// extension before it fails, so the rest of their lock is refreshed like any
/// other, and nothing about pub is.
const expectedFailures = <String, String>{
  'rules_dart/e2e/pub_lock_conflict': 'conflicting versions across lock files',
  'rules_dart/e2e/pub_lock_unpinned': 'has no sha256',
  'rules_dart/e2e/sdk_unknown_version': "instead of '9.9.9'",
  'rules_flutter/e2e/podfile_lock_red': 'cannot read YAML',
  'rules_dart/e2e/pub_symlink': _placeholderRegistry,
  'rules_dart/e2e/pub_symlink/cycle': _placeholderRegistry,
  'rules_dart/e2e/pub_lock_scc/spoke_facts': _placeholderRegistry,
  'rules_flutter/e2e/pub_hosted_escape': _placeholderRegistry,
};

/// A Bazel workspace: [path] is relative to the repository root, with `/`.
final class Workspace {
  const Workspace(this.path, this.directory);

  /// `rules_dart/e2e/smoke`.
  final String path;

  /// The absolute directory.
  final String directory;

  /// The workspace's lockfile.
  String get lockfile => '$directory/MODULE.bazel.lock';

  @override
  String toString() => path;
}

/// Every workspace under [root], sorted by path. Hidden directories, `bazel-*`
/// output links, `references/` and symbolic links are never entered.
List<Workspace> findWorkspaces(
  String root, {
  Map<String, String> skipped = skippedWorkspaces,
}) {
  final found = <Workspace>[];
  void walk(Directory dir, String rel) {
    if (File('${dir.path}/MODULE.bazel').existsSync() &&
        !skipped.containsKey(rel)) {
      found.add(Workspace(rel.isEmpty ? '.' : rel, dir.path));
    }
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (name.startsWith('.') ||
          name.startsWith('bazel-') ||
          name == 'references') {
        continue;
      }
      walk(entity, rel.isEmpty ? name : '$rel/$name');
    }
  }

  walk(Directory(root), '');
  found.sort((a, b) => a.path.compareTo(b.path));
  return found;
}

/// The workspaces whose path equals one of [filters] or lies under it. All of
/// them when [filters] is empty.
List<Workspace> selectWorkspaces(List<Workspace> all, List<String> filters) {
  if (filters.isEmpty) return all;
  final cleaned = [
    for (final f in filters) f.replaceAll(RegExp(r'^\./|/+$'), ''),
  ];
  return [
    for (final w in all)
      if (cleaned.any((f) => w.path == f || w.path.startsWith('$f/'))) w,
  ];
}

/// The repository root: the first directory from [start] upwards that holds
/// both `rules_dart/MODULE.bazel` and `rules_flutter/MODULE.bazel`.
String? findRepositoryRoot(String start) {
  var dir = Directory(start).absolute;
  while (true) {
    if (File('${dir.path}/rules_dart/MODULE.bazel').existsSync() &&
        File('${dir.path}/rules_flutter/MODULE.bazel').existsSync()) {
      return dir.path;
    }
    if (dir.parent.path == dir.path) return null;
    dir = dir.parent;
  }
}
