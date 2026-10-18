// Build-action runner for `dart compile js` and `dart compile wasm` over a
// staged project directory.
//
// Under `--spawn_strategy=local` (or any non-sandboxed strategy), `<name>.proj`
// and `<name>.extpkgs` persist in the shared execroot across incremental
// builds. When a source file or dependency is removed from a web binary's
// closure, Bazel stops creating its symlink in `<name>.proj/src/` or
// `<name>.extpkgs/`, but does not delete the old symlink from the previous
// build. This runner prunes unlisted files against `.dart_tool/src_manifest.txt`
// and `.dart_tool/extpkgs_manifest.txt` before invoking `dart compile`.
import 'dart:convert';
import 'dart:io';

void main(List<String> rawArgs) {
  final code = runWebCompileRequest(
    _expandParamFiles(rawArgs),
    outSink: stdout,
    errSink: stderr,
  );
  exit(code);
}

/// Runs a single web compile request after pruning orphaned staged files.
int runWebCompileRequest(
  List<String> args, {
  required StringSink outSink,
  required StringSink errSink,
  String? workingDirectory,
}) {
  String? dart;
  String? project;
  final compileArgs = <String>[];

  var inCompileArgs = false;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (inCompileArgs) {
      compileArgs.add(arg);
      continue;
    }
    if (arg == 'compile') {
      inCompileArgs = true;
      compileArgs.add(arg);
      continue;
    }
    if (arg == '--dart') {
      if (i + 1 >= args.length) {
        errSink.writeln('web_compile_runner: --dart requires a value');
        return 64;
      }
      dart = args[++i];
    } else if (arg.startsWith('--dart=')) {
      dart = arg.substring('--dart='.length);
    } else if (arg == '--project') {
      if (i + 1 >= args.length) {
        errSink.writeln('web_compile_runner: --project requires a value');
        return 64;
      }
      project = args[++i];
    } else if (arg.startsWith('--project=')) {
      project = arg.substring('--project='.length);
    } else {
      inCompileArgs = true;
      compileArgs.add(arg);
    }
  }

  project ??= _inferProjectFromArgs(compileArgs);

  if (dart == null ||
      dart.isEmpty ||
      project == null ||
      project.isEmpty ||
      compileArgs.isEmpty) {
    errSink.writeln(
      'web_compile_runner: --dart, --project, and compile arguments are required',
    );
    return 64;
  }

  String resolveInWorkDir(String path) {
    if (workingDirectory == null ||
        workingDirectory.isEmpty ||
        path.startsWith('/') ||
        (path.length >= 2 && path[1] == ':')) {
      return path;
    }
    return '${_trimTrailingSlash(workingDirectory)}/$path';
  }

  final rawOutputPath = _extractOutputPath(compileArgs);
  final outputPath = rawOutputPath == null
      ? null
      : resolveInWorkDir(rawOutputPath);
  if (outputPath != null) {
    _deleteOutputs(outputPath);
  }

  final normProject = _trimTrailingSlash(resolveInWorkDir(project));
  final allowedSrc = pruneOrphanedStagedFiles(normProject);
  if (allowedSrc != null) {
    if (allowedSrc.isEmpty) {
      errSink.writeln(
        'web_compile_runner: no sources listed in src_manifest.txt in $normProject',
      );
      return 1;
    }
    for (final rel in allowedSrc) {
      if (!FileSystemEntity.isFileSync('$normProject/src/$rel')) {
        errSink.writeln('web_compile_runner: expected source missing: $rel');
        return 1;
      }
    }
  }

  final extManifest = File('$normProject/.dart_tool/extpkgs_manifest.txt');
  final extDir = _siblingExtpkgsDir(normProject);
  if (extManifest.existsSync() && extDir != null) {
    for (final raw in extManifest.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.endsWith('/')) continue;
      final rel = _normRel(line);
      if (!FileSystemEntity.isFileSync('${extDir.path}/$rel')) {
        errSink.writeln(
          'web_compile_runner: expected external source missing: $rel',
        );
        return 1;
      }
    }
  }

  final rawEntrypointPath = _extractEntrypointPath(compileArgs);
  final entrypointPath = rawEntrypointPath == null
      ? null
      : resolveInWorkDir(rawEntrypointPath);
  if (entrypointPath != null) {
    final normEntry = entrypointPath.replaceAll(r'\', '/');
    final srcPrefix = '${normProject.replaceAll(r'\', '/')}/src/';
    if (allowedSrc != null && normEntry.startsWith(srcPrefix)) {
      final relEntry = _normRel(normEntry.substring(srcPrefix.length));
      if (!allowedSrc.contains(relEntry)) {
        errSink.writeln(
          'web_compile_runner: entrypoint not listed in src_manifest.txt: $relEntry',
        );
        return 1;
      }
    }
    if (!FileSystemEntity.isFileSync(entrypointPath)) {
      errSink.writeln(
        'web_compile_runner: entrypoint missing: $entrypointPath',
      );
      return 1;
    }
  }

  Map<String, String>? env;
  String? fallbackHomeDir;
  if (outputPath != null &&
      !Platform.environment.containsKey('HOME') &&
      !Platform.environment.containsKey('USERPROFILE')) {
    fallbackHomeDir = '$outputPath.home';
    env = dart.endsWith('.exe')
        ? {'USERPROFILE': fallbackHomeDir, 'LOCALAPPDATA': fallbackHomeDir}
        : {'HOME': fallbackHomeDir};
  }
  final activeHome =
      fallbackHomeDir ??
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'];

  final ProcessResult result;
  try {
    result = Process.runSync(
      dart,
      compileArgs,
      workingDirectory: workingDirectory,
      environment: env,
    );
  } finally {
    if (activeHome != null && activeHome.endsWith('.home')) {
      final dir = Directory(activeHome);
      if (dir.existsSync()) {
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException {
          // Ignore cleanup errors.
        }
      }
    }
  }
  errSink.write(result.stderr);
  if (result.exitCode != 0) {
    outSink.write(result.stdout);
    if (outputPath != null) {
      _deleteOutputs(outputPath);
    }
    return result.exitCode;
  }
  return 0;
}

/// Removes any orphaned symlinks or unlisted files under `<project>/src/` when
/// `.dart_tool/src_manifest.txt` is present, and under sibling `<name>.extpkgs/`
/// when `.dart_tool/extpkgs_manifest.txt` (or `package_config.json`) is present.
/// Returns the set of `/` relative paths allowed under `src/`, or `null` when
/// no file-level `src_manifest.txt` is present. Never prunes without a manifest.
Set<String>? pruneOrphanedStagedFiles(String project) {
  final normProject = _trimTrailingSlash(project);
  _pruneExtpkgs(normProject);

  final srcDir = Directory('$normProject/src');
  if (!srcDir.existsSync()) return null;
  final manifestFile = File('$normProject/.dart_tool/src_manifest.txt');
  if (!manifestFile.existsSync()) return null;

  final lines = [
    for (final line in manifestFile.readAsLinesSync())
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (lines.contains('*')) return null;

  final allowed = <String>{for (final line in lines) _normRel(line)};
  final rootPath = srcDir.path;
  final dirs = <Directory>[];
  for (final entity in srcDir.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) {
      dirs.add(entity);
      continue;
    }
    final rel = _relative(rootPath, entity.path);
    if (!allowed.contains(rel)) {
      _tryDelete(entity);
    }
  }
  _removeEmptyDirsBottomUp(dirs);
  return allowed;
}

void _pruneExtpkgs(String normProject) {
  final extDir = _siblingExtpkgsDir(normProject);
  if (extDir == null || !extDir.existsSync()) return;

  final extManifest = File('$normProject/.dart_tool/extpkgs_manifest.txt');
  if (extManifest.existsSync()) {
    final allowedFiles = <String>{};
    final allowedDirPrefixes = <String>[];
    for (final raw in extManifest.readAsLinesSync()) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.endsWith('/')) {
        allowedDirPrefixes.add(_normRel(trimmed));
      } else {
        allowedFiles.add(_normRel(trimmed));
      }
    }
    final rootPath = extDir.path;
    final dirs = <Directory>[];
    for (final entity in extDir.listSync(recursive: true, followLinks: false)) {
      if (entity is Directory) {
        dirs.add(entity);
        continue;
      }
      final rel = _relative(rootPath, entity.path);
      final inAllowedDir = allowedDirPrefixes.any(rel.startsWith);
      if (!inAllowedDir && !allowedFiles.contains(rel)) {
        _tryDelete(entity);
      }
    }
    _removeEmptyDirsBottomUp(dirs);
    return;
  }

  final srcManifest = File('$normProject/.dart_tool/src_manifest.txt');
  final pkgConfig = File('$normProject/.dart_tool/package_config.json');
  if (!srcManifest.existsSync() || !pkgConfig.existsSync()) return;

  final referencedExtPkgs = _referencedExtPackages(normProject, pkgConfig);
  if (referencedExtPkgs == null) return;
  for (final entity in extDir.listSync(followLinks: false)) {
    final name = _relative(extDir.path, entity.path);
    if (!referencedExtPkgs.contains(name)) {
      try {
        entity.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore if read-only or already removed.
      }
    }
  }
}

Set<String>? _referencedExtPackages(String normProject, File pkgConfig) {
  final Object? decoded;
  try {
    decoded = jsonDecode(pkgConfig.readAsStringSync());
  } on Object {
    return null;
  }
  if (decoded is! Map || decoded['packages'] is! List) return null;
  final extDir = _siblingExtpkgsDir(normProject);
  if (extDir == null) return null;
  final extBaseName = extDir.path
      .replaceAll(r'\', '/')
      .split('/')
      .where((s) => s.isNotEmpty)
      .last;
  final marker = '$extBaseName/';
  final pkgs = <String>{};
  for (final entry in decoded['packages'] as List) {
    if (entry is! Map) continue;
    final rootUri = entry['rootUri'];
    if (rootUri is! String) continue;
    final idx = rootUri.indexOf(marker);
    if (idx < 0) continue;
    final rest = rootUri.substring(idx + marker.length);
    final seg = rest
        .split('/')
        .firstWhere((s) => s.isNotEmpty, orElse: () => '');
    if (seg.isNotEmpty) {
      pkgs.add(seg);
    }
  }
  return pkgs;
}

Directory? _siblingExtpkgsDir(String normProject) {
  if (!normProject.endsWith('.proj')) return null;
  return Directory(
    '${normProject.substring(0, normProject.length - '.proj'.length)}.extpkgs',
  );
}

void _tryDelete(FileSystemEntity entity) {
  try {
    entity.deleteSync();
  } on FileSystemException {
    // Ignore if read-only or already removed.
  }
}

void _removeEmptyDirsBottomUp(List<Directory> dirs) {
  dirs.sort((a, b) => b.path.length.compareTo(a.path.length));
  for (final d in dirs) {
    try {
      if (d.existsSync() && d.listSync(followLinks: false).isEmpty) {
        d.deleteSync();
      }
    } on FileSystemException {
      // Ignore if non-empty or read-only.
    }
  }
}

String? _extractMultiRoot(List<String> compileArgs) {
  for (final arg in compileArgs) {
    if (arg.startsWith('--multi-root=')) {
      return arg.substring('--multi-root='.length);
    }
    if (arg.startsWith('-E--multi-root=')) {
      return arg.substring('-E--multi-root='.length);
    }
  }
  return null;
}

String _resolveMultiRootUri(String rawUriOrPath, String? multiRoot) {
  final schemeIdx = rawUriOrPath.indexOf(':///');
  if (schemeIdx < 0) return rawUriOrPath;
  final rel = rawUriOrPath.substring(schemeIdx + ':///'.length);
  if (multiRoot == null || multiRoot.isEmpty || multiRoot == '.') {
    return rel;
  }
  return '${_trimTrailingSlash(multiRoot)}/$rel';
}

String? _inferProjectFromArgs(List<String> compileArgs) {
  const pkgSuffix = '/.dart_tool/package_config.json';
  final multiRoot = _extractMultiRoot(compileArgs);
  for (final arg in compileArgs) {
    if (!arg.startsWith('--packages=')) continue;
    final val = _resolveMultiRootUri(
      arg.substring('--packages='.length),
      multiRoot,
    );
    if (val.endsWith(pkgSuffix)) {
      return val.substring(0, val.length - pkgSuffix.length);
    }
  }
  return null;
}

String? _extractOutputPath(List<String> compileArgs) {
  for (var i = 0; i < compileArgs.length; i++) {
    final arg = compileArgs[i];
    if (arg == '-o' || arg == '--output') {
      if (i + 1 < compileArgs.length) {
        return compileArgs[i + 1];
      }
    } else if (arg.startsWith('-o') &&
        arg.length > 2 &&
        !arg.startsWith('--')) {
      return arg.substring(2);
    } else if (arg.startsWith('--output=')) {
      return arg.substring('--output='.length);
    }
  }
  return null;
}

String? _extractEntrypointPath(List<String> compileArgs) {
  if (compileArgs.isEmpty) return null;
  final last = compileArgs.last;
  if (last.startsWith('-')) return null;
  return _resolveMultiRootUri(last, _extractMultiRoot(compileArgs));
}

void _deleteOutputs(String outputPath) {
  final candidates = <String>[
    outputPath,
    '$outputPath.map',
    '$outputPath.deps',
    if (outputPath.endsWith('.wasm')) ...[
      '${outputPath.substring(0, outputPath.length - '.wasm'.length)}.mjs',
      '${outputPath.substring(0, outputPath.length - '.wasm'.length)}.support.js',
      '${outputPath.substring(0, outputPath.length - '.wasm'.length)}.unopt.wasm',
    ],
  ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) {
      _tryDelete(file);
    }
  }
}

List<String> _expandParamFiles(List<String> args) {
  final expanded = <String>[];
  for (final arg in args) {
    if (arg.startsWith('@') && arg.length > 1) {
      final file = File(arg.substring(1));
      if (file.existsSync()) {
        for (final line in file.readAsLinesSync()) {
          if (line.isNotEmpty) {
            expanded.add(line);
          }
        }
        continue;
      }
    }
    expanded.add(arg);
  }
  return expanded;
}

String _trimTrailingSlash(String raw) {
  var s = raw;
  while (s.length > 1 && (s.endsWith('/') || s.endsWith(r'\'))) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

String _normRel(String raw) {
  var rel = raw.replaceAll(r'\', '/');
  while (rel.startsWith('./')) {
    rel = rel.substring(2);
  }
  while (rel.startsWith('/')) {
    rel = rel.substring(1);
  }
  return rel;
}

String _relative(String root, String path) {
  return _normRel(path.substring(root.length));
}
