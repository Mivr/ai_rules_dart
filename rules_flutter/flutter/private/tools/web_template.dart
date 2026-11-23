/// Runs the web compilers for the web rules: `compile wasm` (`dart2wasm`) and
/// `compile js` (`dart2js`), each through `dartaotruntime` with its outputs
/// confined to the sandbox. The page around the compiled program (index.html,
/// `flutter_bootstrap.js`, the service worker) is written by the Flutter
/// tool's own code, in the asset tool's `web` command.
library;

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'compile') {
    _runWebCompile(args.sublist(1));
    return;
  }
  stderr.writeln('Usage: web_template compile wasm|js <args>');
  exit(64);
}

/// Runs `dart2wasm` or `dart2js` directly via `dartaotruntime`, bypassing
/// `dartdev` (which probes `execroot/bin` outside declared inputs) and
/// normalizing output paths so compilation is sandbox-confined and
/// workspace-path-independent.
void _runWebCompile(List<String> args) {
  final String subcommand = args.isNotEmpty ? args.first : '';
  if (subcommand == 'wasm') {
    _runDart2Wasm(args.sublist(1));
  } else if (subcommand == 'js') {
    _runDart2Js(args.sublist(1));
  } else {
    stderr.writeln('web_template compile: unknown subcommand "$subcommand"');
    exit(64);
  }
}

String _toAppSchemeRelPath(String path) {
  final String norm = path.replaceAll(r'\', '/');
  return norm.replaceFirst(
    RegExp(r'^(?:\./)?bazel-out/[^/]+/(?:bin|genfiles)/'),
    '',
  );
}

/// A parsed `package_config.json` and the file it was read from.
typedef _PackageConfig = ({
  File file,
  Map<String, dynamic> json,
  List<Map<String, dynamic>> packages,
});

/// Reads the package config at [packagesPath].
_PackageConfig _readPackageConfig(String packagesPath) {
  final File file = File(packagesPath).absolute;
  final parsed = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
  final List<Map<String, dynamic>> packages =
      (parsed['packages'] as List<dynamic>).cast<Map<String, dynamic>>();
  return (file: file, json: parsed, packages: packages);
}

/// Rewrites [packagesPath] so every package root resolves inside the compile's
/// staging root, and writes the result to [outPath].
///
/// Roots under the app scheme name the staged tree directly. Roots on the
/// filesystem must sit under the action's working directory, where the staging
/// root holds their staged copies; a root anywhere else (a `file:` URI the
/// compiler would read straight off the host, outside every multi-root) fails
/// the compile instead of passing through. Roots under any other scheme are
/// left alone: the compiler reports what it cannot resolve.
void _rewritePackageConfigForStage(
  String packagesPath,
  String normCwd,
  String cwdPrefix,
  String outPath,
) {
  final _PackageConfig config = _readPackageConfig(packagesPath);
  for (final Map<String, dynamic> p in config.packages) {
    final rootUri = p['rootUri'] as String;
    String rel = '';
    if (rootUri.startsWith('org-dartlang-app:///')) {
      rel = _toAppSchemeRelPath(
        rootUri.substring('org-dartlang-app:///'.length),
      );
    } else {
      final Uri resolved = config.file.uri.resolve(rootUri);
      if (resolved.scheme != 'file') continue;
      final String fsPath = resolved.toFilePath().replaceAll(r'\', '/');
      if (fsPath.startsWith(cwdPrefix)) {
        String r = fsPath.substring(cwdPrefix.length);
        if (r.endsWith('/') && r.length > 1) r = r.substring(0, r.length - 1);
        rel = _toAppSchemeRelPath(r);
      } else if (fsPath == normCwd || fsPath == cwdPrefix) {
        rel = '';
      } else {
        stderr.writeln(
          'web_template compile: package ${p['name']} root $rootUri resolves '
          'outside the declared inputs ($fsPath); refusing to compile.',
        );
        exit(1);
      }
    }
    p['rootUri'] = 'org-dartlang-app:///$rel';
  }
  File(outPath).writeAsStringSync(json.encode(config.json));
}

/// Rewrites [packagesPath] so every package root resolves inside the compile's
/// staging root, and writes the result to [outPath]. The wasm compiler mounts
/// the staging root itself (see [_runDart2Wasm]), so roots under the working
/// directory name their staged copies; a root anywhere else (a `file:` URI the
/// compiler would read straight off the host, outside every multi-root) fails
/// the compile instead of passing through. Roots under any other scheme are
/// left alone: the compiler reports what it cannot resolve.
void _rewritePackageConfig(
  String packagesPath,
  String normCwd,
  String cwdPrefix,
  String outPath,
) {
  final _PackageConfig config = _readPackageConfig(packagesPath);
  for (final Map<String, dynamic> p in config.packages) {
    final rootUri = p['rootUri'] as String;
    if (rootUri.startsWith('org-dartlang-app:///')) continue;
    final Uri resolved = config.file.uri.resolve(rootUri);
    if (resolved.scheme == 'file') {
      final String fsPath = resolved.toFilePath().replaceAll(r'\', '/');
      if (fsPath.startsWith(cwdPrefix)) {
        String rel = fsPath.substring(cwdPrefix.length);
        if (rel.endsWith('/') && rel.length > 1) {
          rel = rel.substring(0, rel.length - 1);
        }
        rel = _toAppSchemeRelPath(rel);
        p['rootUri'] = 'org-dartlang-app:///$rel';
      } else if (fsPath == normCwd || fsPath == cwdPrefix) {
        p['rootUri'] = 'org-dartlang-app:///';
      } else {
        stderr.writeln(
          'web_template compile: package ${p['name']} root $rootUri resolves '
          'outside the declared inputs ($fsPath); refusing to compile.',
        );
        exit(1);
      }
    }
  }
  File(outPath).writeAsStringSync(json.encode(config.json));
}

void _runDart2Wasm(List<String> args) {
  final exeSuffix = Platform.isWindows ? '.exe' : '';
  final String sdkBin = File(Platform.resolvedExecutable).parent.path;
  final dartaotruntime = '$sdkBin/dartaotruntime$exeSuffix';

  final ({
    List<String> extraOptions,
    List<String> forwardArgs,
    String? mainDart,
    String? multiRoot,
    bool noSourceMaps,
    String? outputWasm,
    String? packagesPath,
  })
  parsed = _parseDart2WasmArgs(args);
  final String? packagesPath = parsed.packagesPath;
  final String? outputWasm = parsed.outputWasm;
  final String? mainDart = parsed.mainDart;
  if (packagesPath == null || outputWasm == null || mainDart == null) {
    stderr.writeln(
      'web_template compile wasm: --packages, -o, and entrypoint are required',
    );
    exit(64);
  }

  _compileWasm(
    _WebCompileRequest(
      dartaotruntime: dartaotruntime,
      sdkBin: sdkBin,
      packagesPath: packagesPath,
      outputWasm: outputWasm,
      mainDart: mainDart,
      multiRoot: parsed.multiRoot,
      noSourceMaps: parsed.noSourceMaps,
      extraOptions: parsed.extraOptions,
      forwardArgs: parsed.forwardArgs,
    ),
  );
}

/// The `compile wasm` flags in [args].
({
  String? packagesPath,
  String? outputWasm,
  String? mainDart,
  String? multiRoot,
  bool noSourceMaps,
  List<String> extraOptions,
  List<String> forwardArgs,
})
_parseDart2WasmArgs(List<String> args) {
  String? packagesPath;
  String? outputWasm;
  String? mainDart;
  String? multiRoot;
  var noSourceMaps = false;
  final extraOptions = <String>[];
  final forwardArgs = <String>[];

  for (var i = 0; i < args.length; i++) {
    final String arg = args[i];
    if (arg.startsWith('--packages=')) {
      packagesPath = arg.substring('--packages='.length);
    } else if (arg.startsWith('--multi-root=')) {
      multiRoot = arg.substring('--multi-root='.length);
    } else if (arg.startsWith('--extra-compiler-option=')) {
      extraOptions.add(arg.substring('--extra-compiler-option='.length));
    } else if (arg == '-o') {
      outputWasm = args[++i];
    } else if (arg.startsWith('-o=')) {
      outputWasm = arg.substring('-o='.length);
    } else if (arg == '--no-source-maps') {
      noSourceMaps = true;
      forwardArgs.add(arg);
    } else if (arg.startsWith('-')) {
      forwardArgs.add(arg);
    } else {
      mainDart = arg;
    }
  }
  return (
    packagesPath: packagesPath,
    outputWasm: outputWasm,
    mainDart: mainDart,
    multiRoot: multiRoot,
    noSourceMaps: noSourceMaps,
    extraOptions: extraOptions,
    forwardArgs: forwardArgs,
  );
}

/// The inputs for one `compile wasm` or `compile js` invocation.
///
/// [_compileWasm] and [_compileDart2Js] share the tool, SDK, entrypoint,
/// package, multi-root and forwarded-flag inputs; each reads only the half it
/// needs (the scratch paths for dart2js, the output and wasm options for
/// dart2wasm), so one request type serves both without a Map bag.
class _WebCompileRequest {
  final String dartaotruntime;
  final String sdkBin;
  final String? packagesPath;
  final String? mainDart;
  final String? multiRoot;
  final List<String> forwardArgs;

  /// The dart2js scratch directory and its absolute path (null for wasm).
  final String? tmpPath;
  final String? tmpAbsPath;

  /// The working directory the dart2js compile runs in (null for wasm).
  final String? cwdPath;

  /// The wasm output, source-map flag and extra compiler options (wasm only).
  final String? outputWasm;
  final bool noSourceMaps;
  final List<String> extraOptions;

  const new({
    required this.dartaotruntime,
    required this.sdkBin,
    required this.packagesPath,
    required this.mainDart,
    required this.multiRoot,
    required this.forwardArgs,
    this.tmpPath,
    this.tmpAbsPath,
    this.cwdPath,
    this.outputWasm,
    this.noSourceMaps = false,
    this.extraOptions = const [],
  });
}

/// Compiles [mainDart] to [outputWasm] (plus its `.mjs` and optional source
/// map) with the wasm compiler's staging root mounted.
void _compileWasm(_WebCompileRequest req) {
  final exeSuffix = Platform.isWindows ? '.exe' : '';
  final outWasmFile = File(req.outputWasm!)..parent.createSync(recursive: true);
  final tmpDir = Directory('${outWasmFile.parent.path}/_wasm_tmp')
    ..createSync(recursive: true);
  final String tmpAbsPath = tmpDir.absolute.path;
  try {
    final String cwdPath = Directory.current.absolute.path;
    final String rootDirPath = req.multiRoot != null
        ? Directory(req.multiRoot!).absolute.path
        : cwdPath;
    final String normCwd = cwdPath.replaceAll(r'\', '/');
    final cwdPrefix = normCwd.endsWith('/') ? normCwd : '$normCwd/';
    final rewrittenPkgPath = '${tmpDir.path}/package_config.json';
    _rewritePackageConfig(
      req.packagesPath!,
      normCwd,
      cwdPrefix,
      rewrittenPkgPath,
    );

    final tmpWasm = '${tmpDir.path}/main.dart.wasm';
    final String normMainDart = req.multiRoot != null
        ? _toAppSchemeRelPath(req.mainDart!)
        : req.mainDart!.replaceAll(r'\', '/');
    final wasmArgs = <String>[
      '${req.sdkBin}/snapshots/dart2wasm_product.snapshot',
      ...req.extraOptions,
      '--packages=$rewrittenPkgPath',
      '--multi-root-scheme=org-dartlang-app',
      '--multi-root=$rootDirPath',
      '--wasm-opt=${req.sdkBin}/utils/wasm-opt$exeSuffix',
      ...req.forwardArgs,
      'org-dartlang-app:///$normMainDart',
      tmpWasm,
    ];
    final ProcessResult res = Process.runSync(
      req.dartaotruntime,
      wasmArgs,
      environment: {
        ...Platform.environment,
        'TMPDIR': tmpAbsPath,
        'TMP': tmpAbsPath,
        'TEMP': tmpAbsPath,
      },
    );
    if (res.exitCode != 0) {
      stdout.write(res.stdout as String);
      stderr.write(res.stderr as String);
      exit(res.exitCode);
    }

    _copyWasmOutputs(req.outputWasm!, tmpDir, req.noSourceMaps, tmpWasm);
  } finally {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  }
}

/// Copies the compiled wasm, its `.mjs` loader and optional source map out of
/// the scratch directory.
void _copyWasmOutputs(
  String outputWasm,
  Directory tmpDir,
  bool noSourceMaps,
  String tmpWasm,
) {
  File(tmpWasm).copySync(outputWasm);

  final outputMjs = outputWasm.endsWith('.wasm')
      ? '${outputWasm.substring(0, outputWasm.length - 5)}.mjs'
      : '$outputWasm.mjs';
  File('${tmpDir.path}/main.dart.mjs').copySync(outputMjs);

  if (!noSourceMaps) {
    final tmpMap = File('$tmpWasm.map');
    if (tmpMap.existsSync()) tmpMap.copySync('$outputWasm.map');
  }
}

String _toAppSchemeUri(String path, String cwdPrefix) {
  String norm = path.replaceAll(r'\', '/');
  if (norm.startsWith(cwdPrefix)) norm = norm.substring(cwdPrefix.length);
  return 'org-dartlang-app:///${_toAppSchemeRelPath(norm)}';
}

/// Scrubs host-specific file URIs, temporary package_config paths, stage paths,
/// and compilation timestamps from dart2js output artifacts in [outDir].
///
/// Directory-wide scrubbing is only safe when no other action writes compiler
/// outputs into [outDir] concurrently: every scrub below is a read-modify-write
/// computed with only this action's temp paths, so scrubbing a sibling
/// action's file can overwrite its normalized result with a sorted-but-raw
/// copy. A compile that shares its output directory — the base and canvaskit
/// icon kernels both emit `<dill>.deps` into the same `bin` dir — must scrub
/// only its own files with [scrubDart2JsFile].
void scrubDart2JsOutputs(
  Directory outDir, {
  required String cwdPath,
  String? rootDirPath,
  String? tmpDirPath,
  String? packagesPath,
  String? rewrittenPkgPath,
}) {
  if (!outDir.existsSync()) return;

  final List<FileSystemEntity> entries = outDir.listSync(recursive: true)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in entries) {
    if (entity is File &&
        (entity.path.endsWith('.deps') ||
            entity.path.endsWith('.info.json') ||
            entity.path.endsWith('.map') ||
            entity.path.endsWith('.js'))) {
      scrubDart2JsFile(
        entity,
        cwdPath: cwdPath,
        rootDirPath: rootDirPath,
        tmpDirPath: tmpDirPath,
        packagesPath: packagesPath,
        rewrittenPkgPath: rewrittenPkgPath,
      );
    }
  }
}

/// Scrubs one compiler output file in place.
///
/// This is the per-file core of [scrubDart2JsOutputs], split out so an action
/// whose outputs share a directory with a concurrent action's outputs can
/// normalize exactly the files it owns and never read-modify-write a file
/// another action is still producing. The base and canvaskit icon kernels
/// (see the `--cfe-only` branch of [_runDart2Js]) compile concurrently into
/// the same `bin` dir: with a directory-wide scrub, a scrub that read the
/// sibling's `<dill>.deps` while raw and wrote it back after the sibling's
/// own scrub overwrote the normalized file with a sorted-but-still-raw copy —
/// a declared output differing per strategy (P-web-icon-dill-paths).
void scrubDart2JsFile(
  File file, {
  required String cwdPath,
  String? rootDirPath,
  String? tmpDirPath,
  String? packagesPath,
  String? rewrittenPkgPath,
}) {
  final _ScrubPrefixes prefixes = _scrubPrefixesFor(
    cwdPath: cwdPath,
    rootDirPath: rootDirPath,
    tmpDirPath: tmpDirPath,
    packagesPath: packagesPath,
    rewrittenPkgPath: rewrittenPkgPath,
  );
  final state = _ScrubState(file.readAsStringSync());
  _scrubPackageUris(state, prefixes);
  _scrubDirectoryUris(state, prefixes);
  _scrubSourcemapStageRefs(state, file, prefixes);
  _scrubInfoJson(state, file, prefixes);
  _scrubDepsFile(state, file);
  if (state.changed) file.writeAsStringSync(state.content);
}

/// The host-specific spellings `scrubDart2JsFile` normalizes away.
class _ScrubPrefixes {
  final String? pkgAppUri;
  final String? rewrittenPkgUri;
  final String? origPkgUri;
  final String? tmpDirUriPrefix;
  final String? stageUriPrefix;
  final String cwdUriPrefix;
  final String? stageDirName;
  final String? relStagePrefix;

  new({
    required this.pkgAppUri,
    required this.rewrittenPkgUri,
    required this.origPkgUri,
    required this.tmpDirUriPrefix,
    required this.stageUriPrefix,
    required this.cwdUriPrefix,
    required this.stageDirName,
    required this.relStagePrefix,
  });
}

/// One compiler output file mid-scrub: its current [content] and whether any
/// replacement has changed it yet.
class _ScrubState {
  String content;
  bool changed = false;

  new(this.content);

  /// Replaces every [from] with [to], recording the change.
  void replace(Pattern from, String to) {
    final String next = content.replaceAll(from, to);
    if (next != content) {
      content = next;
      changed = true;
    }
  }
}

/// Computes the host-specific spellings of the cwd, staging root, temp dir
/// and package configs that compiler outputs may record.
_ScrubPrefixes _scrubPrefixesFor({
  required String cwdPath,
  required String? rootDirPath,
  required String? tmpDirPath,
  required String? packagesPath,
  required String? rewrittenPkgPath,
}) {
  final String normCwd = cwdPath.replaceAll(r'\', '/');
  final cwdPrefix = normCwd.endsWith('/') ? normCwd : '$normCwd/';
  final String? normRootDir = rootDirPath?.replaceAll(r'\', '/');
  return _ScrubPrefixes(
    pkgAppUri: packagesPath != null
        ? _toAppSchemeUri(packagesPath, cwdPrefix)
        : null,
    rewrittenPkgUri: rewrittenPkgPath != null
        ? Uri.file(File(rewrittenPkgPath).absolute.path).toString()
        : null,
    origPkgUri: packagesPath != null
        ? Uri.file(File(packagesPath).absolute.path).toString()
        : null,
    tmpDirUriPrefix: tmpDirPath != null
        ? Uri.directory(tmpDirPath).toString()
        : null,
    stageUriPrefix: rootDirPath != null
        ? Uri.directory(rootDirPath).toString()
        : null,
    cwdUriPrefix: Uri.directory(cwdPath).toString(),
    stageDirName: rootDirPath != null ? _stageDirName(rootDirPath) : null,
    relStagePrefix: normRootDir != null && normRootDir.startsWith(cwdPrefix)
        ? _toAppSchemeRelPath(normRootDir.substring(cwdPrefix.length))
        : null,
  );
}

/// The staging root's own directory name, for source-map relative spellings.
String? _stageDirName(String rootDirPath) {
  final List<String> segments = Directory(rootDirPath).uri.pathSegments
      .where((s) => s.isNotEmpty)
      .toList();
  return segments.isNotEmpty ? segments.last : null;
}

/// Rewrites recorded package-config URIs to their stable app-scheme spelling.
void _scrubPackageUris(_ScrubState state, _ScrubPrefixes p) {
  if (p.pkgAppUri != null) {
    if (p.rewrittenPkgUri != null) {
      state.replace(p.rewrittenPkgUri!, p.pkgAppUri!);
    }
    if (p.origPkgUri != null) state.replace(p.origPkgUri!, p.pkgAppUri!);
  }
}

/// Rewrites recorded temp, staging-root and working-directory URIs to the
/// stable app-scheme root.
void _scrubDirectoryUris(_ScrubState state, _ScrubPrefixes p) {
  if (p.tmpDirUriPrefix != null) {
    state.replace(p.tmpDirUriPrefix!, 'org-dartlang-app:///');
  }
  if (p.stageUriPrefix != null) {
    state.replace(p.stageUriPrefix!, 'org-dartlang-app:///');
  }
  state.replace(p.cwdUriPrefix, 'org-dartlang-app:///');
  state.replace(
    RegExp(r'org-dartlang-app:///(?:\./)?bazel-out/[^/]+/(?:bin|genfiles)/'),
    'org-dartlang-app:///',
  );
  // A staged input is addressed as `<stage>/<rel>` under the same scheme,
  // so the same file is recorded with and without the `<stage>/` prefix
  // depending on which copy the frontend chose. Without this the depfile
  // differs per strategy even though every URI is already stable.
  state.replace(
    RegExp(r'org-dartlang-app:///.*?\.stage/'),
    'org-dartlang-app:///',
  );
}

/// Rewrites the staging directory's relative spellings in a source map.
void _scrubSourcemapStageRefs(_ScrubState state, File file, _ScrubPrefixes p) {
  if (file.path.endsWith('.map') &&
      p.stageDirName != null &&
      p.stageDirName!.isNotEmpty) {
    state.replace(
      RegExp('(?:\\.\\./)+${RegExp.escape(p.stageDirName!)}/'),
      'org-dartlang-app:///',
    );
  }
}

/// Normalizes a `.info.json` dump: relative output paths and compilation
/// timestamps.
void _scrubInfoJson(_ScrubState state, File file, _ScrubPrefixes p) {
  if (!file.path.endsWith('.info.json')) return;
  state.replace(RegExp(r'(?:\./)?bazel-out/[^/]+/(?:bin|genfiles)/'), '');
  if (p.relStagePrefix != null &&
      p.relStagePrefix!.isNotEmpty &&
      state.content.contains('${p.relStagePrefix!}/')) {
    state.replace('${p.relStagePrefix!}/', '');
  }
  state.content = state.content
      .replaceAllMapped(
        RegExp(r'"compilationMoment":\s*"[^"]*"'),
        (_) => '"compilationMoment": "1970-01-01 00:00:00.000000"',
      )
      .replaceAllMapped(
        RegExp(
          r'"(compilationDuration|toJsonDuration|dumpInfoDuration)":\s*\d+',
        ),
        (m) => '"${m.group(1)}": 0',
      );
  state.changed = true;
}

/// Sorts, trims and dedupes a `.deps` depfile.
void _scrubDepsFile(_ScrubState state, File file) {
  if (!file.path.endsWith('.deps')) return;
  final List<String> lines =
      state.content
          .split('\n')
          .map((l) => l.trimRight())
          .where((l) => l.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
  final normalized = lines.isEmpty ? '' : '${lines.join('\n')}\n';
  if (normalized != state.content) {
    state.content = normalized;
    state.changed = true;
  }
}

/// Builds the `dart2js` snapshot argv for a staged multi-root compile.
///
/// The js frontend resolves `org-dartlang-app:///` URIs against a `file:`
/// multi-root naming the per-action staging tree that holds both source and
/// generated inputs; the entrypoint and every package root are addressed as
/// URIs relative to that root, so the compile reads only declared inputs
/// whatever the strategy. The recorded library URIs stay stable relative URIs
/// with no sandbox or execroot absolute paths. Mirrors [_runDart2Wasm]'s
/// stable scheme, adapted to the js frontend's `file:`-rooted multi-root
/// (a plain path multi-root answers "Unknown scheme in uri").
List<String> buildDart2JsSnapshotArgs({
  required List<String> forwardArgs,
  required String rewrittenPkgPath,
  required String stageRootUri,
  required String normMainDart,
}) {
  final entryUri = 'org-dartlang-app:///$normMainDart';
  return <String>[
    for (final a in forwardArgs)
      if (a.startsWith('--packages=')) '--packages=$rewrittenPkgPath' else a,
    '--multi-root-scheme=org-dartlang-app',
    '--multi-root=$stageRootUri',
    entryUri,
  ];
}

/// The `file:` multi-root URI for the staging directory [multiRoot] names:
/// the Bazel action passes it exec-root-relative, so absolutize against the
/// working directory; an already-absolute or `file:` spelling is honored.
String stageRootUri(String multiRoot) {
  final String norm = multiRoot.replaceAll(r'\', '/');
  if (norm.startsWith('file:')) {
    final Uri uri = Uri.parse(norm);
    return Uri.directory(uri.toFilePath()).toString();
  }
  return Uri.directory(Directory(multiRoot).absolute.path).toString();
}

void _runDart2Js(List<String> args) {
  final exeSuffix = Platform.isWindows ? '.exe' : '';
  final String sdkBin = File(Platform.resolvedExecutable).parent.path;
  final dartaotruntime = '$sdkBin/dartaotruntime$exeSuffix';

  final ({
    List<String> forwardArgs,
    String? mainDart,
    String? multiRoot,
    String? outJs,
    String? packagesPath,
  })
  parsed = _parseDart2JsArgs(args);

  // `dart compile js --cfe-only` produces a kernel dill for const_finder
  // (the `app.dill` upstream runs icon tree-shaking on) rather than
  // JavaScript. Its `-o` names a file, not a directory, so the scratch
  // directory is a uniquely-named sibling of the output (the compiler already
  // writes `<dill>.deps` there, so the parent is the action's own output
  // tree); two icon kernels compile concurrently into one `bin` dir, hence
  // the timestamp/pid suffix. JS scrubbing is skipped: there is no JS to
  // scrub, and the `.deps` sibling is normalized below.
  final bool cfeOnly = parsed.forwardArgs.contains('--cfe-only');

  final String cwdPath = Directory.current.absolute.path;
  final ({String tmpAbsPath, Directory tmpDir}) scratch = _dart2JsScratchDir(
    outJs: parsed.outJs,
    cfeOnly: cfeOnly,
    cwdPath: cwdPath,
  );
  final Directory tmpDir = scratch.tmpDir;
  final String tmpAbsPath = scratch.tmpAbsPath;
  String? rootDirPath;
  String? rewrittenPkgPath;
  try {
    final ({String? rewrittenPkgPath, String? rootDirPath}) compiled =
        _compileDart2Js(
          _WebCompileRequest(
            dartaotruntime: dartaotruntime,
            sdkBin: sdkBin,
            tmpPath: tmpDir.path,
            tmpAbsPath: tmpAbsPath,
            multiRoot: parsed.multiRoot,
            packagesPath: parsed.packagesPath,
            mainDart: parsed.mainDart,
            forwardArgs: parsed.forwardArgs,
            cwdPath: cwdPath,
          ),
        );
    rootDirPath = compiled.rootDirPath;
    rewrittenPkgPath = compiled.rewrittenPkgPath;
  } finally {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  }

  _scrubDart2JsResults(
    _Dart2JsScrubRequest(
      outJs: parsed.outJs,
      cfeOnly: cfeOnly,
      cwdPath: cwdPath,
      rootDirPath: rootDirPath,
      tmpAbsPath: tmpAbsPath,
      packagesPath: parsed.packagesPath,
      rewrittenPkgPath: rewrittenPkgPath,
    ),
  );
}

/// The `compile js` flags in [args].
({
  String? outJs,
  String? multiRoot,
  String? packagesPath,
  String? mainDart,
  List<String> forwardArgs,
})
_parseDart2JsArgs(List<String> args) {
  String? outJs;
  String? multiRoot;
  String? packagesPath;
  String? mainDart;
  final forwardArgs = <String>[];
  for (var i = 0; i < args.length; i++) {
    final String arg = args[i];
    if (arg == '-o' && i + 1 < args.length) {
      outJs = args[++i];
      forwardArgs.addAll(['-o', outJs]);
    } else if (arg.startsWith('-o=')) {
      outJs = arg.substring('-o='.length);
      forwardArgs.add(arg);
    } else if (arg.startsWith('--multi-root=')) {
      multiRoot = arg.substring('--multi-root='.length);
    } else if (arg.startsWith('--packages=')) {
      packagesPath = arg.substring('--packages='.length);
      forwardArgs.add(arg);
    } else if (arg.startsWith('-')) {
      forwardArgs.add(arg);
    } else {
      mainDart = arg;
    }
  }
  return (
    outJs: outJs,
    multiRoot: multiRoot,
    packagesPath: packagesPath,
    mainDart: mainDart,
    forwardArgs: forwardArgs,
  );
}

/// The compile's scratch directory and its absolute path.
///
/// The icon-kernel scratch sits under the action's output directory when the
/// output is known (never the shared system temp): for a tree-artifact
/// output that is `outJs`'s own directory, for a dill output its parent dir.
({Directory tmpDir, String tmpAbsPath}) _dart2JsScratchDir({
  required String? outJs,
  required bool cfeOnly,
  required String cwdPath,
}) {
  final String baseTmpParent = (cfeOnly || outJs == null)
      ? cwdPath
      : (File(outJs).parent..createSync(recursive: true)).path;
  final String cfeScratchParent = cfeOnly && outJs != null
      ? (File(outJs).parent..createSync(recursive: true)).path
      : baseTmpParent;
  final tmpDir = Directory(
    cfeOnly
        ? '$cfeScratchParent/rules_flutter_dart2js_cfe_${DateTime.now().microsecondsSinceEpoch}_${pid}'
        : '$baseTmpParent/_dart2js_tmp',
  )..createSync(recursive: true);
  return (tmpDir: tmpDir, tmpAbsPath: tmpDir.absolute.path);
}

/// Runs the dart2js snapshot in [tmpPath]'s scratch, staging the package
/// config first when the compile mounts a multi-root; answers the staging
/// root and rewritten package config the output scrub needs.
({String? rootDirPath, String? rewrittenPkgPath}) _compileDart2Js(
  _WebCompileRequest req,
) {
  String? rootDirPath;
  String? rewrittenPkgPath;
  List<String> jsArgs;
  if (req.multiRoot != null &&
      req.packagesPath != null &&
      req.mainDart != null) {
    rootDirPath = Uri.parse(stageRootUri(req.multiRoot!)).toFilePath();
    final String normCwd = req.cwdPath!.replaceAll(r'\', '/');
    final cwdPrefix = normCwd.endsWith('/') ? normCwd : '$normCwd/';
    rewrittenPkgPath = '${req.tmpPath!}/package_config.json';
    _rewritePackageConfigForStage(
      req.packagesPath!,
      normCwd,
      cwdPrefix,
      rewrittenPkgPath,
    );
    final String relMain = _toAppSchemeRelPath(req.mainDart!);
    jsArgs = buildDart2JsSnapshotArgs(
      forwardArgs: req.forwardArgs,
      rewrittenPkgPath: rewrittenPkgPath,
      stageRootUri: stageRootUri(req.multiRoot!),
      normMainDart: relMain,
    );
  } else {
    jsArgs = <String>[
      ...req.forwardArgs,
      if (req.mainDart != null) req.mainDart!,
    ];
  }

  final ProcessResult res = Process.runSync(
    req.dartaotruntime,
    [
      '${req.sdkBin}/snapshots/dart2js_aot.dart.snapshot',
      '--invoker=dart_cli',
      ...jsArgs,
    ],
    environment: {
      ...Platform.environment,
      'TMPDIR': req.tmpAbsPath!,
      'TMP': req.tmpAbsPath!,
      'TEMP': req.tmpAbsPath!,
    },
  );
  if (res.exitCode != 0) {
    stdout.write(res.stdout as String);
    stderr.write(res.stderr as String);
    exit(res.exitCode);
  }
  return (rootDirPath: rootDirPath, rewrittenPkgPath: rewrittenPkgPath);
}

/// What [_scrubDart2JsResults] normalizes: this action's own compiler outputs
/// plus the host-specific paths the scrub rewrites to stable spellings.
class _Dart2JsScrubRequest {
  final String? outJs;
  final bool cfeOnly;
  final String cwdPath;
  final String? rootDirPath;
  final String tmpAbsPath;
  final String? packagesPath;
  final String? rewrittenPkgPath;

  const new({
    required this.outJs,
    required this.cfeOnly,
    required this.cwdPath,
    required this.rootDirPath,
    required this.tmpAbsPath,
    required this.packagesPath,
    required this.rewrittenPkgPath,
  });
}

/// Normalizes this action's own compiler outputs.
///
/// A directory-wide scrub for a regular JS output; only the `<dill>.deps`
/// sibling for a `--cfe-only` kernel, never the whole output directory: the
/// base and canvaskit icon kernels compile concurrently into the same `bin`
/// dir, and a directory-wide scrub is a read-modify-write of the sibling's
/// depfile with only this action's temp paths known. A scrub that read the
/// sibling's file while raw and writes it back after the sibling's own scrub
/// overwrites the normalized file with a sorted-but-still-raw copy — a
/// declared output that then differs per strategy (P-web-icon-dill-paths).
/// The `.dill` itself needs no scrubbing: the kernel records
/// workspace-relative library URIs.
void _scrubDart2JsResults(_Dart2JsScrubRequest scrub) {
  if (scrub.outJs != null && !scrub.cfeOnly) {
    scrubDart2JsOutputs(
      File(scrub.outJs!).parent,
      cwdPath: scrub.cwdPath,
      rootDirPath: scrub.rootDirPath,
      tmpDirPath: scrub.tmpAbsPath,
      packagesPath: scrub.packagesPath,
      rewrittenPkgPath: scrub.rewrittenPkgPath,
    );
  }
  if (scrub.outJs != null && scrub.cfeOnly) {
    final depsFile = File('${scrub.outJs!}.deps');
    if (depsFile.existsSync()) {
      scrubDart2JsFile(
        depsFile,
        cwdPath: scrub.cwdPath,
        rootDirPath: scrub.rootDirPath,
        tmpDirPath: scrub.tmpAbsPath,
        packagesPath: scrub.packagesPath,
        rewrittenPkgPath: scrub.rewrittenPkgPath,
      );
    }
  }
}
