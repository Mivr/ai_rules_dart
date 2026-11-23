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
//     origin  <text>                 where the `pkg` records after it come from
//     pkg     <name> <lib_root> <language_version> <workspace_root> <version>
//     file    <path> <short_path> <owner_workspace_root> <is_directory 0|1>
//     own     <path> <short_path>    a file being checked
//     options <path> <short_path>    a listed `analysis_options.yaml`
//
// `pkg` and `file` records come in the order the old staging read its lists,
// and the first record of a package name, or the first file of a short path,
// wins as it did there. As there (`merge_package_records`), two records of
// one package that state different versions or language versions are an
// error, not a choice: [LayoutManifest.parse] throws a [LayoutException]
// naming every disagreement. And as `copy_tree` did when a directory input
// put the staged tree into copy mode, two inputs that land on one path are an
// error unless they share a short path and bytes.
//
// This file uses `dart:io` alone, so every runner can list it in `srcs`.
import 'dart:io';

/// The layout flag every runner accepts before its own arguments.
const String layoutFlag = '--layout';

/// A manifest the runner must refuse, or a tree it cannot lay out. The
/// message is for the build log.
final class LayoutException implements Exception {
  new(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One package record of the manifest.
final class LayoutPackage {
  new(
    this.name,
    this.libRoot,
    this.languageVersion,
    this.workspace, {
    this.version = '',
    this.origin = '',
  });

  final String name;
  final String libRoot;
  final String languageVersion;
  final String workspace;

  /// The package's resolved version; empty when unknown.
  final String version;

  /// Where the record comes from, for error messages.
  final String origin;

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

  /// Parses the manifest [text]; throws [FormatException] on a bad record
  /// and [LayoutException] on package records that disagree.
  factory parse(String text) {
    String? name;
    var sdkVersion = '';
    var named = false;
    var origin = '';
    final records = <LayoutPackage>[];
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
        case 'origin':
          origin = field(1);
        case 'pkg':
          records.add(
            LayoutPackage(
              field(1),
              field(2),
              field(3),
              field(4),
              version: f.length > 5 ? f[5] : '',
              origin: origin,
            ),
          );
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
    final String? disagreement = packageAgreementError(records);
    if (disagreement != null) throw LayoutException(disagreement);
    // `merge_package_records`: once the records agree, the first of a name
    // wins. Two records may still name different roots: one package supplied
    // by two pub hubs, which the rules accept.
    final seen = <String>{};
    final List<LayoutPackage> packages = [
      for (final r in records)
        if (seen.add(r.name)) r,
    ];
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

const _versionRemedy = '''
Each package listed just above was resolved to different versions by two
package sources. Typically two pub hubs — rules_flutter's `flutter.pub()` and
rules_dart's `pub.from_lock()` each generating a spoke for the same package —
whose lock files have drifted apart. Only one record per package can win, and
dependency order would decide which, so the build would compile against
whichever came first regardless of what the other's lock pins.

Reconcile the lock files feeding the two hubs so both pin one version of each,
then re-run `dart pub get` / `flutter pub get` in each workspace. Every package
that disagrees is listed, so one reconciliation settles all of them.

rules_dart does not support multiple versions of a package.
''';

const _languageVersionRemedy = '''
Each package listed just above has records stating different
`language_version`s, so the Dart semantics its sources compile under would be
decided by dependency order. Set `language_version` consistently on every
`dart_library` contributing to the package — Gazelle derives it from the
nearest `pubspec.yaml`'s `environment.sdk` constraint and writes the same value
on each.
''';

/// `package_agreement_error` of `common.bzl`: every package whose records
/// state two different known versions or language versions, or null.
///
/// An empty value is unknown and agrees with anything. Each value is listed
/// with the root and the origin of the first record stating it.
String? packageAgreementError(List<LayoutPackage> records) {
  final blocks = <String>[];
  for (final (String Function(LayoutPackage) field, label, remedy) in [
    ((LayoutPackage p) => p.version, 'versions', _versionRemedy),
    (
      (LayoutPackage p) => p.languageVersion,
      'language versions',
      _languageVersionRemedy,
    ),
  ]) {
    final stated = <String, Map<String, LayoutPackage>>{};
    for (final r in records) {
      final String value = field(r);
      if (value.isEmpty) continue;
      stated.putIfAbsent(r.name, () => {}).putIfAbsent(value, () => r);
    }
    final reported = <String>[];
    for (final String name in stated.keys.toList()..sort()) {
      final Map<String, LayoutPackage> seen = stated[name]!;
      if (seen.length < 2) continue;
      final buffer = StringBuffer(
        'Package "$name" is supplied more than once with different $label:\n',
      );
      for (final String value in seen.keys.toList()..sort()) {
        final LayoutPackage r = seen[value]!;
        final from = r.origin.isEmpty ? '' : ', from ${r.origin}';
        buffer.write('  - $value (${r.libRoot}$from)\n');
      }
      reported.add(buffer.toString());
    }
    if (reported.isNotEmpty) blocks.add(reported.join() + remedy);
  }
  return blocks.isEmpty ? null : blocks.join('\n');
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

  // `src/`: per-file links. A directory input puts the tree in copy mode, as
  // `copy_tree` did: every file of a directory is linked at its path below
  // the directory's short path, and two inputs landing on one path are an
  // error unless they share a short path and bytes.
  final bool hasDirInputs = srcFiles.any((f) => f.isDirectory);
  final occupied = <String>{};
  if (!hasDirInputs) {
    for (final (rel, name) in stubs) {
      _write(
        '$proj/src/$rel',
        layoutPubspecStub(
          packages,
          name: name,
          sdkVersion: manifest.sdkVersion,
        ),
      );
      occupied.add(rel);
    }
    for (final f in srcFiles) {
      if (!occupied.add(f.shortPath)) continue;
      _link('$proj/src/${f.shortPath}', f.path);
    }
  } else {
    final placed = _Placed();
    for (final f in srcFiles) {
      if (f.isDirectory) {
        _linkDirectory(f, '$proj/src/${f.shortPath}', placed);
      } else {
        placed.link('$proj/src/${f.shortPath}', f.path, f.shortPath);
      }
    }
    // A stub stands in for a package's missing `pubspec.yaml`. A directory
    // input that carries the real one (a `srcs_dir` holding a whole package)
    // keeps it, as a real `pubspec.yaml` listed as a file always has: the
    // stub is written only where no staged file has that path.
    for (final (rel, name) in stubs) {
      final dest = '$proj/src/$rel';
      if (placed.has(dest)) {
        stubPaths.remove('src/$rel');
        continue;
      }
      _write(
        dest,
        layoutPubspecStub(
          packages,
          name: name,
          sdkVersion: manifest.sdkVersion,
        ),
      );
    }
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
      final placed = _Placed();
      for (final f in files) {
        final dest = '$extDir/$mangled/${_workspacePath(f.shortPath)}';
        if (f.isDirectory) {
          _linkDirectory(f, dest, placed);
        } else {
          placed.link(dest, f.path, f.shortPath);
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

/// The files one copy-mode tree has placed: destination to short path and
/// input, so a second input landing on a destination is checked as
/// `copy_tree` checked it.
final class _Placed {
  final _byDest = <String, (String, String)>{};

  bool has(String dest) => _byDest.containsKey(dest);

  /// Links [dest] to the input at [path], whose short path is [shortPath].
  ///
  /// A second input for [dest] is skipped when it has the same short path and
  /// bytes (a source file and its copy in `bazel-out`), and refused otherwise.
  void link(String dest, String path, String shortPath) {
    final (String, String)? first = _byDest[dest];
    if (first == null) {
      _byDest[dest] = (shortPath, path);
      _link(dest, path);
      return;
    }
    final (String firstShort, String firstPath) = first;
    if (firstShort == shortPath && _sameBytes(firstPath, path)) return;
    throw LayoutException(
      'Two inputs would be staged at `$dest`:\n'
      '  - $firstPath (short path $firstShort)\n'
      '  - $path (short path $shortPath)\n'
      'Each staged path takes one file. Remove one of them from the '
      "target's sources or its dependencies.",
    );
  }
}

bool _sameBytes(String a, String b) {
  final List<int> x = File(a).readAsBytesSync();
  final List<int> y = File(b).readAsBytesSync();
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

/// Links every file below the input directory [dir] at the same path below
/// [dest], creating real directories, so files staged into one directory
/// from several inputs merge rather than write through a linked directory.
void _linkDirectory(LayoutFile dir, String dest, _Placed placed) {
  Directory(dest).createSync(recursive: true);
  final String root = Directory(dir.path).absolute.path;
  final List<FileSystemEntity> entries = Directory(
    root,
  ).listSync(recursive: true)..sort((a, b) => a.path.compareTo(b.path));
  for (final e in entries) {
    if (e is! File) continue;
    final String rel = e.path.substring(root.length + 1);
    placed.link('$dest/$rel', e.path, '${dir.shortPath}/$rel');
  }
}
