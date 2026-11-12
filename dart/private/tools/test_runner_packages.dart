import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// One package a `dart_test` reaches: its name and `lib_root` (the
/// `short_path`-based directory above its `lib/`), as `dart_test` lists them.
typedef PackageRoot = ({String name, String root});

/// The packages listed in a `<name>.package_roots` file, one
/// `<name>\t<lib_root>` line each. A line with no tab is not one.
List<PackageRoot> parsePackageRoots(Iterable<String> lines) {
  final roots = <PackageRoot>[];
  for (final line in lines) {
    final int tab = line.indexOf('\t');
    if (tab <= 0) continue;
    roots.add((name: line.substring(0, tab), root: line.substring(tab + 1)));
  }
  return roots;
}

/// The runfiles path of [root]'s `lib/` directory.
///
/// A `lib_root` of another repository starts with `../`; the main
/// repository's is relative to [workspace], and empty for the root package.
String libRunfilesPath(PackageRoot root, String workspace) {
  final String r = root.root;
  if (r.startsWith('../')) return '${r.substring(3)}/lib';
  return r.isEmpty ? '$workspace/lib' : '$workspace/$r/lib';
}

/// What a launcher can see of its runfiles: the directory tree, the manifest
/// lines (each `<runfiles path> <real path>`), or both.
typedef RunfilesView = ({String? directory, List<String> manifest});

/// The directory of each package in [roots] that has files staged under its
/// `lib/`, by package name; a package with none is left out.
///
/// A runfiles tree holds the directory when something was staged there. With
/// no tree (Windows, `--noenable_runfiles`) the manifest is searched for an
/// entry below `lib/` and the real directory is read off its target. The first
/// listing of a name wins.
Map<String, String> stagedLibDirs(
  List<PackageRoot> roots, {
  required String workspace,
  required RunfilesView runfiles,
}) {
  final dirs = <String, String>{};
  for (final root in roots) {
    if (dirs.containsKey(root.name)) continue;
    final String rpath = libRunfilesPath(root, workspace);
    final String? dir = _lookupLibDir(rpath, runfiles);
    if (dir != null) dirs[root.name] = dir;
  }
  return dirs;
}

String? _lookupLibDir(String rpath, RunfilesView runfiles) {
  final String? tree = runfiles.directory;
  if (tree != null) {
    final candidate = '$tree/$rpath';
    if (Directory(candidate).existsSync()) return candidate;
  }
  final below = '$rpath/';
  for (final String line in runfiles.manifest) {
    final int space = line.indexOf(' ');
    if (space < 0) continue;
    final String key = line.substring(0, space);
    final String real = line.substring(space + 1);
    if (key == rpath && Directory(real).existsSync()) return real;
    if (key.startsWith(below) && key.length > below.length) {
      // The real path ends in the same suffix as the key below `lib/`.
      final int suffix = key.length - below.length;
      return real.substring(0, real.length - suffix - 1);
    }
  }
  return null;
}

/// The `package_config.json` text mapping each package in [libDirs] to its
/// directory by an absolute `file:` URI, in name order.
///
/// Each package's root is the directory above its `lib/` and its `packageUri`
/// is `lib/`, as pub lays one out, so
/// `Isolate.resolvePackageUri(package:<name>/<path>)` is `<dir>/<path>`.
String packageConfigJson(Map<String, String> libDirs) {
  final List<String> names = libDirs.keys.toList()..sort();
  return const JsonEncoder.withIndent('  ').convert({
    'configVersion': 2,
    'packages': [for (final name in names) _packageEntry(name, libDirs[name]!)],
  });
}

Map<String, String> _packageEntry(String name, String libDir) {
  final Uri dir = Directory(libDir).absolute.uri;
  final List<String> segments = dir.pathSegments;
  return {
    'name': name,
    'rootUri': dir.resolve('../').toString(),
    'packageUri': '${segments[segments.length - 2]}/',
  };
}

/// Writes [json] to [target], creating its directory.
///
/// The file appears whole or not at all: it is written beside the target and
/// renamed onto it. Throws [FileSystemException] when the directory cannot be
/// written.
void writePackageConfig(File target, String json) {
  target.parent.createSync(recursive: true);
  final partial = File('${target.path}.partial');
  partial.writeAsStringSync(json, flush: true);
  partial.renameSync(target.path);
}

/// The package config JSON for a launcher run: the packages listed in the
/// roots file `RULES_DART_PACKAGE_ROOTS` names, less those with nothing
/// staged. Outside Bazel, with no list, it maps no package.
String runtimePackageConfig({
  required Map<String, String> env,
  required Runfiles runfiles,
  required String? manifest,
  required String? workspace,
}) {
  final String? key = env['RULES_DART_PACKAGE_ROOTS'];
  if (key == null || key.isEmpty || workspace == null) {
    return packageConfigJson(const {});
  }
  final List<PackageRoot> roots = parsePackageRoots(
    File(runfiles.rlocation(key)).readAsLinesSync(),
  );
  final String? tree = env['RUNFILES_DIR'];
  return packageConfigJson(
    stagedLibDirs(
      roots,
      workspace: workspace,
      runfiles: (
        directory: tree != null && Directory(tree).existsSync()
            ? Directory(tree).resolveSymbolicLinksSync()
            : null,
        manifest: manifest == null
            ? const []
            : File(manifest).readAsLinesSync(),
      ),
    ),
  );
}
