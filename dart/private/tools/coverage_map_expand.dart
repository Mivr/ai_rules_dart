// Writes a `dart_test`'s `<name>.coverage_map.json`: the map from the source
// URIs the VM reports to the exec paths of the files. `dart_test` runs this under
// `bazel coverage` only, so the sources reach it as records of a params file
// that Bazel expands lazily from the depset of the test's closure.
//
// The params file (one value per line) is what `write_coverage_map` in
// `dart/private/coverage_map.bzl` writes, after the `--coverage-map` tag:
//
//   <out>                                  where to write the finished map
//   --package <name> <prefix> <lib_root>   a package the compile resolves against;
//                                          <prefix> is its `lib/` short path
//   --origin-map <file>                    a `dart_source_set` origin map, once per set
//   --dir <path> <short_path>              a directory source (tree artifact)
//   --file <path> <short_path>             one Dart file, outside or inside some `--dir`
//
// Every value of the finished map is an exec path, as `COVERAGE_MANIFEST`
// lists it. A file a `dart_source_set` staged maps to the exec path
// of the input it was staged from; any other file maps to its own.

import 'dart:convert';
import 'dart:io';

/// The first line of a params file that asks for a coverage map.
const String requestTag = '--coverage-map';

/// A failure to read the request or to map a file. The message is for the log.
class CoverageMapError implements Exception {
  new(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A directory source and the package whose root it is.
class SourceDir {
  const new({
    required this.path,
    required this.shortPath,
    required this.packageName,
  });

  final String path;
  final String shortPath;
  final String packageName;
}

/// One Dart file found inside a [SourceDir], or outside every one.
class MemberFile {
  const new({required this.path, required this.shortPath});

  final String path;
  final String shortPath;
}

/// A package the compile resolves against.
class PackageRoot {
  const new({
    required this.name,
    required this.libPrefix,
    required this.libRoot,
  });

  final String name;
  final String libPrefix;
  final String libRoot;
}

/// A parsed request.
class CoverageMapRequest {
  new({
    required this.out,
    required this.packages,
    required this.originMaps,
    required this.dirs,
    required this.files,
  });

  final String out;
  final List<PackageRoot> packages;
  final List<String> originMaps;
  final List<SourceDir> dirs;
  final List<MemberFile> files;
}

/// Parses the params file's lines after the tag.
CoverageMapRequest parseCoverageMapRequest(List<String> lines) {
  var i = 0;
  String next() {
    if (i >= lines.length) {
      throw CoverageMapError('params file ends inside a record');
    }
    return lines[i++];
  }

  final String out = next();
  final packages = <PackageRoot>[];
  final originMaps = <String>[];
  final dirs = <SourceDir>[];
  final files = <MemberFile>[];
  while (i < lines.length) {
    final String tag = next();
    switch (tag) {
      case '--package':
        packages.add(
          PackageRoot(name: next(), libPrefix: next(), libRoot: next()),
        );
      case '--origin-map':
        originMaps.add(next());
      case '--dir':
        final String path = next();
        final String shortPath = next();
        dirs.add(
          SourceDir(
            path: path,
            shortPath: shortPath,
            packageName: _rootedAt(packages, shortPath, path),
          ),
        );
      case '--file':
        files.add(MemberFile(path: next(), shortPath: next()));
      default:
        throw CoverageMapError('unknown record "$tag" in params file');
    }
  }
  return CoverageMapRequest(
    out: out,
    packages: packages,
    originMaps: originMaps,
    dirs: dirs,
    files: files,
  );
}

/// The name of the first package whose `lib_root` is [shortPath].
String _rootedAt(List<PackageRoot> packages, String shortPath, String path) {
  for (final pkg in packages) {
    if (pkg.libRoot == shortPath) return pkg.name;
  }
  throw CoverageMapError(
    'the directory source `$shortPath` ($path) is the root of no Dart '
    'package, so its files cannot be mapped for `bazel coverage`. Pass it as a '
    '`dart_library(srcs_dir = ...)`.',
  );
}

/// The entries for Dart files outside every directory source.
///
/// Each file gets its `org-dartlang-root:` URI and, when it is under the `lib/`
/// of a package, its `package:` URI. The deepest matching `lib/` wins, and the
/// first package listed wins a tie. Both name the file's exec path.
Map<String, String> plainEntries({
  required List<PackageRoot> packages,
  required List<MemberFile> files,
}) {
  final byPrefix = <String, PackageRoot>{};
  for (final pkg in packages) {
    byPrefix.putIfAbsent(pkg.libPrefix, () => pkg);
  }
  final entries = <String, String>{};
  for (final file in files) {
    final String execPath = file.path.replaceAll(r'\', '/');
    entries['org-dartlang-root:///${_stable(file.shortPath)}'] = execPath;
    final PackageRoot? owner = _deepestOwner(byPrefix, file.shortPath);
    if (owner != null) {
      final String rel = file.shortPath.substring(owner.libPrefix.length);
      entries['package:${owner.name}/$rel'] = execPath;
    }
  }
  return entries;
}

PackageRoot? _deepestOwner(Map<String, PackageRoot> byPrefix, String path) {
  int end = path.lastIndexOf('/');
  while (end >= 0) {
    final PackageRoot? owner = byPrefix[path.substring(0, end + 1)];
    if (owner != null) return owner;
    end = end == 0 ? -1 : path.lastIndexOf('/', end - 1);
  }
  return null;
}

/// The entries [files] add to a coverage map.
///
/// [origins] maps a staged file's path to the exec path of its input. Each file
/// gets its `org-dartlang-root:` URI, its `package:` URI when it is under the
/// `lib/` of the package its directory roots, and, when it was staged, its own
/// path, so the `file:` URI the VM reports for the staged file resolves too.
Map<String, String> expandDirectories({
  required List<SourceDir> dirs,
  required List<MemberFile> files,
  required Map<String, String> origins,
}) {
  final entries = <String, String>{};
  for (final file in files) {
    final SourceDir dir = _owner(dirs, file);
    final String origin = origins[file.path] ?? file.path;
    entries['org-dartlang-root:///${_stable(file.shortPath)}'] = origin;
    final String rel = file.path.substring(dir.path.length + 1);
    if (rel.startsWith('lib/')) {
      entries['package:${dir.packageName}/${rel.substring(4)}'] = origin;
    }
    if (origin != file.path) entries[file.path] = origin;
  }
  return entries;
}

/// A short path with `../repo` turned into `external/repo`.
String _stable(String shortPath) => shortPath.startsWith('../')
    ? 'external/${shortPath.substring(3)}'
    : shortPath;

SourceDir _owner(List<SourceDir> dirs, MemberFile file) {
  SourceDir? best;
  for (final dir in dirs) {
    if (!file.path.startsWith('${dir.path}/')) continue;
    if (best == null || dir.path.length > best.path.length) best = dir;
  }
  if (best == null) {
    throw CoverageMapError('${file.path} is in none of the listed directories');
  }
  return best;
}

Map<String, String> _readStringMap(String path) {
  final Object? decoded;
  try {
    decoded = jsonDecode(File(path).readAsStringSync());
  } on FileSystemException catch (e) {
    throw CoverageMapError('cannot read $path: ${e.message}');
  } on FormatException catch (e) {
    throw CoverageMapError('$path is not JSON: ${e.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw CoverageMapError('$path is not a JSON object');
  }
  return {for (final e in decoded.entries) e.key: '${e.value}'};
}

/// Runs a request: reads the maps it names and writes the finished one.
void writeCoverageMap(List<String> lines) {
  final CoverageMapRequest request = parseCoverageMapRequest(lines);
  final origins = <String, String>{};
  for (final String path in request.originMaps) {
    origins.addAll(_readStringMap(path));
  }
  final List<MemberFile> inDir = [];
  final List<MemberFile> plain = [];
  for (final MemberFile file in request.files) {
    (_isInside(request.dirs, file) ? inDir : plain).add(file);
  }
  final entries = <String, String>{
    ..._sortedByKey(plainEntries(packages: request.packages, files: plain)),
    ...expandDirectories(dirs: request.dirs, files: inDir, origins: origins),
  };
  File(request.out).writeAsStringSync(jsonEncode(entries));
}

/// [map] in key order, which is how the analysis-time `json.encode` wrote the
/// entries of the sources outside directories; entries of directories follow.
Map<String, String> _sortedByKey(Map<String, String> map) => Map.fromEntries(
  map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
);

bool _isInside(List<SourceDir> dirs, MemberFile file) =>
    dirs.any((dir) => file.path.startsWith('${dir.path}/'));
