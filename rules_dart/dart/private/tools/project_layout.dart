// Lays out a staged project at execution, from a layout manifest.
//
// The `dart_analyze` aspect used to stage each analyzed target's project at
// analysis time: one declared file and one symlink action per file of the
// target's closure, and a Starlark pass over the flattened closure to write
// the package config, the pubspec stubs and the excludes. That cost grew with
// the square of the graph. The aspect now writes one manifest per project,
// expanded by Bazel at execution from the closure's depsets, and the tool that
// reads the project calls [layOutProject] first. The tree it builds is the one
// the aspect used to declare, at the same relative paths:
//
//     <name>.proj/.dart_tool/package_config.json
//     <name>.proj/.dart_tool/src_manifest.txt
//     <name>.proj/.dart_tool/extpkgs_manifest.txt
//     <name>.proj/pubspec.yaml                   (stub)
//     <name>.proj/analysis_options.yaml          (wrapper)
//     <name>.proj/src/<short_path>               (main-repository files)
//     <name>.proj/src/<lib_root>/pubspec.yaml    (stub, one per package root)
//     <name>.extpkgs/<package>/<workspace_path>  (external packages)
//
// so the runners read it exactly as they read the staged one. Every staged
// file is a symlink to a declared input of the action (the manifest names the
// same depsets the action takes as inputs); every other file is written from
// the manifest. Nothing else is read.
//
// The manifest holds one record per line, fields separated by tabs:
//
//     name    <name>                 prefix of `<name>.proj` and `<name>.extpkgs`
//     sdk     <version>              toolchain SDK version (pubspec constraint)
//     named   0|1                    name every external package in the config
//     pkg     <name> <lib_root> <language_version> <workspace_root>
//     file    <path> <short_path> <owner_workspace_root> <is_directory 0|1>
//     own     <path> <short_path>    a file being checked
//     options <path> <short_path>    a listed `analysis_options.yaml`
//
// `pkg` and `file` records come in the order the old staging read its lists,
// and the first record of a package name, or the first file of a short path,
// wins as it did there.
//
// This file uses `dart:io` alone, so every runner can list it in `srcs`.
import 'dart:io';

/// The layout flag every runner accepts before its own arguments.
const String layoutFlag = '--layout';

/// One package record of the manifest.
final class LayoutPackage {
  new(this.name, this.libRoot, this.languageVersion, this.workspace);

  final String name;
  final String libRoot;
  final String languageVersion;
  final String workspace;

  bool get isExternalRoot => libRoot.startsWith('../');
}

/// One file record of the manifest.
final class LayoutFile {
  new(this.path, this.shortPath, this.ownerWorkspace, this.isDirectory);

  final String path;
  final String shortPath;
  final String ownerWorkspace;
  final bool isDirectory;

  /// Whether the file is outside the main repository.
  bool get isExternal =>
      shortPath.startsWith('../') || ownerWorkspace.isNotEmpty;
}

/// A parsed layout manifest.
final class LayoutManifest {
  new({
    required this.name,
    required this.sdkVersion,
    required this.allPackagesNamed,
    required this.packages,
    required this.files,
    required this.own,
    required this.options,
  });

  /// Parses the manifest [text]; throws [FormatException] on a bad record.
  factory parse(String text) {
    String? name;
    var sdkVersion = '';
    var named = false;
    final packages = <LayoutPackage>[];
    final seenPackages = <String>{};
    final files = <LayoutFile>[];
    final own = <LayoutFile>[];
    final options = <LayoutFile>[];
    for (final String line in text.split('\n')) {
      if (line.isEmpty) continue;
      final List<String> f = line.split('\t');
      String field(int i) {
        if (i >= f.length) {
          throw FormatException('layout manifest: short record `$line`');
        }
        return f[i];
      }

      switch (f.first) {
        case 'name':
          name = field(1);
        case 'sdk':
          sdkVersion = field(1);
        case 'named':
          named = field(1) == '1';
        case 'pkg':
          // `merge_package_records`: the first record of a name wins.
          if (seenPackages.add(field(1))) {
            packages.add(LayoutPackage(field(1), field(2), field(3), field(4)));
          }
        case 'file':
          files.add(LayoutFile(field(1), field(2), field(3), field(4) == '1'));
        case 'own':
          own.add(LayoutFile(field(1), field(2), '', false));
        case 'options':
          options.add(LayoutFile(field(1), field(2), '', false));
        default:
          throw FormatException('layout manifest: unknown record `$line`');
      }
    }
    if (name == null || name.isEmpty) {
      throw const FormatException('layout manifest: no `name` record');
    }
    return LayoutManifest(
      name: name,
      sdkVersion: sdkVersion,
      allPackagesNamed: named,
      packages: packages,
      files: files,
      own: own,
      options: options,
    );
  }

  final String name;
  final String sdkVersion;
  final bool allPackagesNamed;
  final List<LayoutPackage> packages;
  final List<LayoutFile> files;
  final List<LayoutFile> own;
  final List<LayoutFile> options;
}

/// Removes `--layout <manifest>` from [args] and lays out the project the
/// `--project` argument names. Returns the remaining arguments and the project
/// laid out (null when [args] carry no `--layout`).
({List<String> args, String? project}) applyLayoutArgs(List<String> args) {
  final int at = args.indexOf(layoutFlag);
  if (at < 0) return (args: args, project: null);
  if (at + 1 >= args.length) {
    throw const FormatException('`--layout` needs a value');
  }
  final String manifest = args[at + 1];
  final List<String> rest = [...args.sublist(0, at), ...args.sublist(at + 2)];
  final int projectAt = rest.indexOf('--project');
  if (projectAt < 0 || projectAt + 1 >= rest.length) {
    throw const FormatException('`--layout` needs `--project`');
  }
  final String project = rest[projectAt + 1];
  layOutProject(
    LayoutManifest.parse(File(manifest).readAsStringSync()),
    project,
  );
  return (args: rest, project: project);
}

/// Removes a project [layOutProject] built, and its `.extpkgs` sibling.
///
/// The project sits in a directory the action declares as an output; leaving
/// the symlinks there would make that output point at the action's inputs.
void removeLayout(String project) {
  for (final String path in [project, _extpkgsDir(project)]) {
    final dir = Directory(path);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

String _trimSlash(String path) {
  var p = path;
  while (p.length > 1 && (p.endsWith('/') || p.endsWith(r'\'))) {
    p = p.substring(0, p.length - 1);
  }
  return p;
}

String _extpkgsDir(String project) {
  final String trimmed = _trimSlash(project);
  if (!trimmed.endsWith('.proj')) {
    throw FormatException('layout project `$project` must end in `.proj`');
  }
  return '${trimmed.substring(0, trimmed.length - '.proj'.length)}.extpkgs';
}

/// `mangle_package_dir`: path-hostile characters become `_`.
String mangleLayoutPackageDir(String name) =>
    name.replaceAll(RegExp('[/:.+]'), '_');

/// `package_index` and `package_for_index` of `source_set.bzl`.
final class _PackageIndex {
  new(Iterable<LayoutPackage> packages) {
    for (final pkg in packages) {
      _byRoot.putIfAbsent(pkg.libRoot, () => pkg.name);
    }
  }

  final _byRoot = <String, String>{};

  String? owner(String shortPath) {
    if (shortPath.isNotEmpty) {
      final String? name = _byRoot[shortPath];
      if (name != null) return name;
    }
    final List<String> parts = shortPath.split('/');
    for (int i = parts.length - 1; i >= 0; i--) {
      if (parts[i] == 'lib') {
        final String? name = _byRoot[parts.sublist(0, i).join('/')];
        if (name != null) return name;
      }
    }
    return null;
  }
}

bool _isUnder(String shortPath, String root) =>
    root.isEmpty || shortPath == root || shortPath.startsWith('$root/');

/// `pubspec_stub` of `project_staging.bzl`.
String layoutPubspecStub(
  List<LayoutPackage> packages, {
  String name = 'analyze_stub',
  String sdkVersion = '',
}) {
  var sdk = '>=3.0.0 <4.0.0';
  final List<String> parts = sdkVersion.split('.');
  if (parts.length >= 2) sdk = '^${parts[0]}.${parts[1]}.0';
  for (final p in packages) {
    if (p.name == name && p.languageVersion.isNotEmpty) {
      sdk = '^${p.languageVersion}.0';
      break;
    }
  }
  final lines = ['name: $name', 'environment:', '  sdk: "$sdk"'];
  final List<String> names = [
    for (final p in packages)
      if (p.name.isNotEmpty && p.name != name) p.name,
  ]..sort();
  if (names.isNotEmpty) {
    lines.add('dependencies:');
    for (final dep in names) {
      lines.add('  $dep: any');
    }
  }
  return '${lines.join('\n')}\n';
}

/// `_wrapper_options` of `analyze_targets.bzl`.
String _wrapperOptions(List<String> excluded) {
  final lines = ['# rules_dart: staged project root'];
  if (excluded.isNotEmpty) {
    lines
      ..add('analyzer:')
      ..add('  exclude:');
    for (final path in excluded) {
      lines.add('    - "$path"');
    }
  }
  return '${lines.join('\n')}\n';
}

/// `staged_package_config_content` of `project_staging.bzl`, for a project
/// whose external packages sit in its `.extpkgs` sibling.
String _packageConfig(
  List<LayoutPackage> packages,
  Set<String> extStaged,
  String name,
) {
  final entries = <String>[];
  for (final pkg in packages) {
    final String rootUri;
    if (pkg.isExternalRoot) {
      if (!extStaged.contains(pkg.name)) continue;
      final String sub = pkg.libRoot.split('/').skip(2).join('/');
      rootUri =
          '../../$name.extpkgs/${mangleLayoutPackageDir(pkg.name)}'
          '${sub.isEmpty ? '' : '/$sub'}';
    } else if (pkg.libRoot.isNotEmpty) {
      rootUri = '../src/${pkg.libRoot}';
    } else {
      rootUri = '../src';
    }
    final lv = pkg.languageVersion.isEmpty
        ? ''
        : ', "languageVersion": "${pkg.languageVersion}"';
    entries.add(
      '    {"name": "${pkg.name}", "rootUri": "$rootUri", '
      '"packageUri": "lib/"$lv}',
    );
  }
  return '{\n  "configVersion": 2,\n  "packages": [\n'
      '${entries.join(',\n')}\n  ]\n}\n';
}

/// The repository-relative path of a file: its short path less the
/// `../<repo>/` an external file carries.
String _workspacePath(String shortPath) => shortPath.startsWith('../')
    ? shortPath.substring(shortPath.indexOf('/', 3) + 1)
    : shortPath;

/// Lays out [manifest]'s project at [project] and its `.extpkgs` sibling.
///
/// Both are removed first, so a project left by an earlier run in the same
/// output directory cannot widen what this run reads.
void layOutProject(LayoutManifest manifest, String project) {
  removeLayout(project);
  final String proj = _trimSlash(project);
  final String extDir = _extpkgsDir(proj);
  final List<LayoutPackage> packages = manifest.packages;

  // External files, grouped by the package that owns them.
  final extIndex = _PackageIndex(packages.where((p) => p.isExternalRoot));
  final extFilesByPkg = <String, List<LayoutFile>>{};
  for (final LayoutFile f in manifest.files) {
    if (!f.shortPath.startsWith('../')) continue;
    final String? owner = extIndex.owner(f.shortPath);
    if (owner != null) extFilesByPkg.putIfAbsent(owner, () => []).add(f);
  }
  final List<LayoutFile> srcFiles = [
    for (final f in manifest.files)
      if (!f.isExternal) f,
  ];

  // One stub pubspec per main-repository package root holding a staged file.
  final allRoots = <String, String>{};
  for (final pkg in packages) {
    if (pkg.isExternalRoot || pkg.name.isEmpty) continue;
    final String? prev = allRoots[pkg.libRoot];
    if (prev == null || pkg.name.compareTo(prev) < 0) {
      allRoots[pkg.libRoot] = pkg.name;
    }
  }
  final List<String> rootsLongestFirst = allRoots.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final activeRoots = <String, String>{};
  for (final f in srcFiles) {
    for (final root in rootsLongestFirst) {
      if (_isUnder(f.shortPath, root)) {
        activeRoots[root] = allRoots[root]!;
        break;
      }
    }
  }
  final Set<String> existing = {for (final f in srcFiles) f.shortPath};
  final stubs = <(String, String)>[]; // (rel path, package name)
  final stubPaths = <String>[];
  for (final String root in activeRoots.keys.toList()..sort()) {
    final rel = root.isEmpty ? 'pubspec.yaml' : '$root/pubspec.yaml';
    if (existing.contains(rel)) continue;
    stubs.add((rel, activeRoots[root]!));
    stubPaths.add('src/$rel');
  }

  // `src/`: per-file links, or every file of a directory input linked at its
  // path below the directory's short path.
  final bool hasDirInputs = srcFiles.any((f) => f.isDirectory);
  final occupied = <String>{};
  for (final (rel, name) in stubs) {
    _write(
      '$proj/src/$rel',
      layoutPubspecStub(packages, name: name, sdkVersion: manifest.sdkVersion),
    );
    occupied.add(rel);
  }
  for (final f in srcFiles) {
    if (f.isDirectory) {
      _linkDirectory(f.path, '$proj/src/${f.shortPath}');
      occupied.add(f.shortPath);
      continue;
    }
    if (!occupied.add(f.shortPath)) continue;
    _link('$proj/src/${f.shortPath}', f.path);
  }
  _write(
    '$proj/.dart_tool/src_manifest.txt',
    hasDirInputs
        ? '*\n'
        : [for (final p in occupied.toList()..sort()) '$p\n'].join(),
  );

  // External packages, below the `.extpkgs` sibling.
  final Set<String> extStaged = extFilesByPkg.keys.toSet();
  if (manifest.allPackagesNamed) {
    for (final pkg in packages) {
      if (pkg.isExternalRoot) extStaged.add(pkg.name);
    }
  }
  final extEntries = <String>[];
  extFilesByPkg.forEach((pkgName, files) {
    final String mangled = mangleLayoutPackageDir(pkgName);
    if (files.any((f) => f.isDirectory)) {
      for (final f in files) {
        final dest = '$extDir/$mangled/${_workspacePath(f.shortPath)}';
        if (f.isDirectory) {
          _linkDirectory(f.path, dest);
        } else if (!_exists(dest)) {
          _link(dest, f.path);
        }
      }
      extEntries.add('$mangled/');
      return;
    }
    final seen = <String>{};
    for (final f in files) {
      final String workspacePath = _workspacePath(f.shortPath);
      if (!seen.add(workspacePath)) continue;
      final rel = '$mangled/$workspacePath';
      extEntries.add(rel);
      _link('$extDir/$rel', f.path);
    }
  });
  _write(
    '$proj/.dart_tool/extpkgs_manifest.txt',
    [for (final e in extEntries..sort()) '$e\n'].join(),
  );

  _write(
    '$proj/.dart_tool/package_config.json',
    _packageConfig(packages, extStaged, manifest.name),
  );
  _write(
    '$proj/pubspec.yaml',
    layoutPubspecStub(packages, sdkVersion: manifest.sdkVersion),
  );

  // Everything under `src/` is there to resolve against and excluded, but
  // for the files being checked and the options files above one of them.
  final Set<String> ownPaths = {for (final f in manifest.own) f.path};
  final Set<String> governing = {
    for (final o in manifest.options)
      if (manifest.own.any((f) => _isUnderDir(f.shortPath, o.shortPath)))
        o.path,
  };
  final excluded = <String>{
    for (final f in srcFiles)
      if (!f.shortPath.startsWith('../') &&
          !ownPaths.contains(f.path) &&
          !governing.contains(f.path))
        'src/${f.shortPath}',
  };
  _write(
    '$proj/analysis_options.yaml',
    _wrapperOptions([...excluded.toList()..sort(), ...stubPaths]),
  );
}

/// `_is_under_dir` of `analyze_targets.bzl`: whether [path] sits below the
/// directory of the options file at [optionsPath].
bool _isUnderDir(String path, String optionsPath) {
  final int slash = optionsPath.lastIndexOf('/');
  final String dir = slash < 0 ? '' : optionsPath.substring(0, slash);
  return dir.isEmpty || path.startsWith('$dir/');
}

bool _exists(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;

void _write(String path, String content) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

/// Links [link] to the input at exec path [target], by absolute path: the
/// action runs at the exec root, sandboxed or not.
void _link(String link, String target) {
  final l = Link(link);
  l.parent.createSync(recursive: true);
  l.createSync(File(target).absolute.path);
}

/// Links every file below the input directory [dir] at the same path below
/// [dest], creating real directories, so files staged into one directory
/// from several inputs merge rather than write through a linked directory.
void _linkDirectory(String dir, String dest) {
  Directory(dest).createSync(recursive: true);
  final String root = Directory(dir).absolute.path;
  for (final FileSystemEntity e in Directory(root).listSync(recursive: true)) {
    if (e is! File) continue;
    final String rel = e.path.substring(root.length + 1);
    final to = '$dest/$rel';
    if (!_exists(to)) _link(to, e.path);
  }
}
