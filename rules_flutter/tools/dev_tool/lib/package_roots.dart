/// Repoints a dev `package_config.json` at Bazel's repository tree.
///
/// A build-emitted dev package_config names third-party packages relatively:
///
/// ```json
/// {"name": "flutter", "rootUri": "../../../external/ai_rules_flutter++flutter+deps__flutter"}
/// ```
///
/// Resolved from where that file lives (`bazel-out/<config>/bin/`), those three
/// `..` steps land on `<output_base>/execroot/_main/external/<repo>` — an entry
/// in the symlink forest Bazel plants per command, holding only the
/// repositories *that* command needed. Bazel re-plants the forest on every
/// command, so any concurrent Bazel invocation deletes those symlinks while a
/// live frontend_server is reading through them, and the compile fails on a
/// source file that is not missing at all.
///
/// Every repository the forest points *at* lives at `<output_base>/external/`,
/// and that tree is not per-command — Bazel neither prunes nor re-plants it
/// between builds. So each `file:` root is rewritten to name the repository
/// tree directly. The rewrite is pure path arithmetic — deleting an
/// `execroot/<name>/` pair from the middle of an already-resolved path —
/// rather than reading the symlink, because reading it is the very thing that
/// races: a `resolveSymbolicLinks` at session start can land in the same
/// window and throw.
///
/// Roots in the app's own `--filesystem-scheme` (`org-dartlang-app:///…`) are
/// left exactly as they are. They address live source through the compiler's
/// multi-root machinery, not the filesystem, and rewriting one would break the
/// mixed-scheme resolution the source-assembled dev loop is built on.
///
/// This covers third-party sources only. The app's own generated sources are
/// read out of `bazel-out`, which Bazel deletes before re-running the action
/// that writes them, and there is no second copy of those to point at.
///
/// One residual race is known and left: resolving the config's own directory
/// traverses the workspace `bazel-out` convenience symlink, which Bazel also
/// rewrites per command. A peer command landing on exactly that instant makes
/// this throw.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:path/path.dart' as p;

/// Where [stabilizePackageRoots] wrote its copy, and what it changed.
class StabilizedPackageConfig {
  /// Absolute path of the rewritten package_config to hand the compiler.
  final String path;

  /// Package names whose root was rewritten: made absolute, and moved off the
  /// per-command execroot where it ran through one. Empty is a legitimate
  /// outcome — a config whose roots are all `org-dartlang-app:` has nothing to
  /// rewrite — so callers report this rather than treating it as a failure.
  final List<String> repointed;

  const new({required this.path, required this.repointed});
}

/// Write a copy of [packageConfigPath] into [into] whose `file:` package roots
/// name Bazel's repository tree rather than the per-command execroot forest.
///
/// The build-emitted original is never modified.
StabilizedPackageConfig stabilizePackageRoots(
  String packageConfigPath, {
  required Directory into,
}) {
  final source = File(packageConfigPath);
  if (!source.existsSync()) {
    throw DevToolException(
      'The build-emitted dev package config is missing: $packageConfigPath',
    );
  }
  final dynamic decoded = json.decode(source.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    throw DevToolException(
      'Expected a JSON object in $packageConfigPath, got ${decoded.runtimeType}.',
    );
  }
  final dynamic packages = decoded['packages'];
  if (packages is! List) {
    throw DevToolException('Expected a "packages" list in $packageConfigPath.');
  }

  // The directory the relative roots resolve against, with its own symlinks
  // already followed. This is `bazel-out/<config>/bin`, which is an ordinary
  // directory inside the output base — resolving it does not touch the forest,
  // and doing it once here is what makes the per-package work pure arithmetic.
  final String base = Directory(
    p.dirname(packageConfigPath),
  ).resolveSymbolicLinksSync();

  final repointed = <String>[];
  for (final Object? entry in packages) {
    if (entry is! Map<String, dynamic>) continue;
    final dynamic rootUri = entry['rootUri'];
    if (rootUri is! String) continue;
    final String? moved = _repointRoot(rootUri, base: base);
    if (moved == null) continue;
    entry['rootUri'] = moved;
    repointed.add(entry['name'] as String? ?? '<unnamed>');
  }

  final out = File(p.join(into.path, 'dev_package_config.json'));
  out.writeAsStringSync(json.encode(decoded));
  return StabilizedPackageConfig(path: out.path, repointed: repointed);
}

/// The rewritten form of [rootUri], or null to leave it exactly as it is.
///
/// Null means one thing only: a root in the app's own filesystem scheme
/// (`org-dartlang-app:///…`), which addresses live source through the
/// compiler's multi-root machinery rather than the filesystem.
///
/// Every other root comes back **absolute**, whether or not it ran through an
/// execroot. That is not incidental. The rewritten config is written to a
/// different directory from the build-emitted one, so a relative root carried
/// over unchanged would silently re-anchor to the new directory.
String? _repointRoot(String rootUri, {required String base}) {
  final Uri parsed = Uri.parse(rootUri);
  if (parsed.hasScheme && parsed.scheme != 'file') return null;

  final String asPath = parsed.scheme == 'file' ? parsed.toFilePath() : rootUri;
  // `..` in a package root is resolved by the OS against real directories, so
  // normalizing against the already-resolved [base] gives the same answer the
  // compiler would have reached — without following the symlink at the end.
  final String resolved = p.normalize(
    p.isAbsolute(asPath) ? asPath : p.join(base, asPath),
  );
  final String stable = _dropExecroot(resolved) ?? resolved;

  if (!Directory(stable).existsSync()) {
    throw DevToolException(
      'The package root $rootUri in the build-emitted dev package config '
      'resolves to $stable, which does not exist. The dev loop reads package '
      'sources through this path, so a compile against it would fail on '
      'every library in that package.',
    );
  }
  return p.toUri(stable).toString();
}

/// `<output_base>/execroot/<name>/external/<repo>` → `<output_base>/external/<repo>`.
///
/// Null when [path] has no `execroot/<name>/external/` in it. Both segments are
/// required together: `external/` alone is not evidence of the forest, and it
/// is the pairing that makes the repository tree the thing being named.
String? _dropExecroot(String path) {
  final List<String> parts = p.split(path);
  for (int i = parts.length - 3; i >= 0; i--) {
    if (parts[i] == 'execroot' && parts[i + 2] == 'external') {
      return p.joinAll([...parts.sublist(0, i), ...parts.sublist(i + 2)]);
    }
  }
  return null;
}

/// Maximum symlink dereferences before letting the OS resolver decide.
const _maxSymlinkHops = 64;

/// Resolve [path], stopping before the `<output_base>/external/<repo>` symlink
/// when the path passes through a Bazel repository tree.
///
/// Reproducible repository rules turn `<output_base>/external/<repo>` into a
/// symlink into Bazel's repo contents cache. Fully resolving a file inside the
/// web SDK repo (`web-sdk/libraries.<platform>.json`) moves it into that cache
/// entry, where its relative `../../<dart_sdk_repo>/dart-sdk/lib/libraries.json`
/// include no longer reaches the sibling Dart SDK repo under `external/`.
///
/// Throws the [FileSystemException] from [File.resolveSymbolicLinksSync] when
/// [path] does not resolve to an existing file. Paths that never enter an
/// `external/<repo>/` directory return [File.resolveSymbolicLinksSync] verbatim.
String resolveExternalPath(String path) {
  final String? underExternal = _walkPreservingRepoLink(path);
  if (underExternal != null) {
    File(underExternal).resolveSymbolicLinksSync();
    return underExternal;
  }
  return File(path).resolveSymbolicLinksSync();
}

class _PathWalk {
  new(String absolutePath)
    : resolved = [p.split(absolutePath).first],
      pending = p.split(absolutePath).skip(1).toList().reversed.toList();

  final List<String> resolved;
  final List<String> pending;
  int? repoFloor;
  int hops = 0;

  /// Whether the next significant segment enters the current directory rather
  /// than ending at it or climbing back out with `..`.
  bool get descendsIntoCurrent {
    for (int i = pending.length - 1; i >= 0; i--) {
      final String segment = pending[i];
      if (segment.isEmpty || segment == '.') continue;
      return segment != '..';
    }
    return false;
  }
}

String? _walkPreservingRepoLink(String path) {
  final String absolute = p.isAbsolute(path)
      ? path
      : p.join(Directory.current.path, path);
  final state = _PathWalk(absolute);
  while (state.pending.isNotEmpty) {
    final String segment = state.pending.removeLast();
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (state.resolved.length > 1) state.resolved.removeLast();
      if (state.repoFloor != null && state.resolved.length < state.repoFloor!) {
        state.repoFloor = null;
      }
      continue;
    }
    state.resolved.add(segment);
    if (_pinExternalRepoBoundary(state)) continue;
    if (!_followLinkIfNeeded(state)) return null;
  }
  return state.repoFloor == null ? null : p.joinAll(state.resolved);
}

String? _tryDropTrailingExecroot(List<String> resolved) {
  final int len = resolved.length;
  if (len < 5 ||
      resolved[len - 4] != 'execroot' ||
      resolved[len - 2] != 'external') {
    return null;
  }
  final String dropped = p.joinAll([
    ...resolved.sublist(0, len - 4),
    'external',
    resolved.last,
  ]);
  return FileSystemEntity.typeSync(dropped, followLinks: false) ==
          FileSystemEntityType.notFound
      ? null
      : dropped;
}

/// Pins `<output_base>/external/<repo>` without following `<repo>`, rewriting
/// an `execroot/<ws>/external/<repo>` forest path onto `<output_base>` first.
bool _pinExternalRepoBoundary(_PathWalk state) {
  if (!state.descendsIntoCurrent) return false;
  final String? dropped = _tryDropTrailingExecroot(state.resolved);
  if (dropped != null) {
    state.resolved
      ..clear()
      ..addAll(p.split(dropped));
  }
  final int len = state.resolved.length;
  if (len < 3 || state.resolved[len - 2] != 'external') return false;
  final String externalDir = p.joinAll(state.resolved.sublist(0, len - 1));
  if (FileSystemEntity.typeSync(externalDir, followLinks: false) !=
      FileSystemEntityType.directory) {
    return false;
  }
  final FileSystemEntityType repoType = FileSystemEntity.typeSync(
    p.joinAll(state.resolved),
    followLinks: false,
  );
  final bool shouldPin =
      dropped != null ||
      repoType == FileSystemEntityType.link ||
      (repoType == FileSystemEntityType.directory && state.repoFloor == null);
  if (!shouldPin) return false;
  final String repo = state.resolved.last;
  final String outputBase = Directory(
    p.joinAll(state.resolved.sublist(0, len - 2)),
  ).resolveSymbolicLinksSync();
  state.resolved
    ..clear()
    ..addAll(p.split(outputBase))
    ..add('external')
    ..add(repo);
  state.repoFloor = state.resolved.length;
  return true;
}

/// Follows a symlink at the tip of `state.resolved`, returning false on loop.
bool _followLinkIfNeeded(_PathWalk state) {
  final String current = p.joinAll(state.resolved);
  if (FileSystemEntity.typeSync(current, followLinks: false) !=
      FileSystemEntityType.link) {
    return true;
  }
  final String target = _stripWindowsDevicePrefix(Link(current).targetSync());
  state.hops++;
  if (state.hops > _maxSymlinkHops) return false;
  state.resolved.removeLast();
  if (p.isAbsolute(target)) {
    final List<String> parts = p.split(target);
    state.resolved
      ..clear()
      ..add(parts.first);
    state.repoFloor = null;
    state.pending.addAll(parts.skip(1).toList().reversed);
  } else {
    state.pending.addAll(target.split(RegExp(r'[\\/]')).reversed);
  }
  return true;
}

String _stripWindowsDevicePrefix(String target) =>
    target.startsWith(r'\\?\') && !target.startsWith(r'\\?\UNC\')
    ? target.substring(4)
    : target;
