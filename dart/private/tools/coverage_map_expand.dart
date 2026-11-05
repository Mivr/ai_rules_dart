// Completes a `dart_test`'s `<name>.coverage_map.json` with the Dart files of
// the directories (tree artifacts) the test reads: the step `dart_test` runs,
// through `copy_tree`, when one of its sources is a directory such as the output
// of a `dart_source_set`. A directory's files are only known at execution time.
//
// The params file (one value per line) is what `write_coverage_map` in
// `dart/private/coverage_map.bzl` writes, after the `--coverage-map` tag:
//
//   <out>                                  where to write the finished map
//   --static <file>                        the map for the sources known at analysis time
//   --origin-map <file>                    a `dart_source_set` origin map, once per set
//   --dir <path> <short_path> <package>    a directory source and the package it roots
//   --file <path> <short_path>             one Dart file inside some `--dir`
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

/// One Dart file found inside a [SourceDir].
class MemberFile {
  const new({required this.path, required this.shortPath});

  final String path;
  final String shortPath;
}

/// A parsed request.
class CoverageMapRequest {
  new({
    required this.out,
    required this.staticMap,
    required this.originMaps,
    required this.dirs,
    required this.files,
  });

  final String out;
  final String staticMap;
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
  var staticMap = '';
  final originMaps = <String>[];
  final dirs = <SourceDir>[];
  final files = <MemberFile>[];
  while (i < lines.length) {
    final String tag = next();
    switch (tag) {
      case '--static':
        staticMap = next();
      case '--origin-map':
        originMaps.add(next());
      case '--dir':
        dirs.add(
          SourceDir(path: next(), shortPath: next(), packageName: next()),
        );
      case '--file':
        files.add(MemberFile(path: next(), shortPath: next()));
      default:
        throw CoverageMapError('unknown record "$tag" in params file');
    }
  }
  return CoverageMapRequest(
    out: out,
    staticMap: staticMap,
    originMaps: originMaps,
    dirs: dirs,
    files: files,
  );
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
  final entries = <String, String>{
    ..._readStringMap(request.staticMap),
    ...expandDirectories(
      dirs: request.dirs,
      files: request.files,
      origins: origins,
    ),
  };
  File(request.out).writeAsStringSync(jsonEncode(entries));
}
