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

/// Rewrites [packagesPath] so every package root is named under the app
/// scheme, and writes the result to [outPath].
///
/// The compile reads its inputs in place, through the `--multi-root`
/// directories the rule names (the generated roots, then the exec root), so a
/// root under the app scheme names a workspace path and needs nothing.
/// Roots on the filesystem must sit under the action's working directory,
/// where the multi-roots find them by the same workspace path; a root anywhere
/// else (a `file:` URI the compiler would read straight off the host, outside
/// every multi-root) fails the compile instead of passing through. Roots under
/// any other scheme are left alone: the compiler reports what it cannot
/// resolve.
void _rewritePackageConfig(
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

/// The flag naming the declared-inputs manifest the read set is checked against.
const _declaredInputsFlag = '--declared-inputs=';

/// The declared inputs a `--declared-inputs` manifest lists, exec-root
/// relative: the sources before the first `#` line and the other files the
/// compile may read after it. The rule writes the manifest from the action's
/// own inputs; the compile argv adds nothing to it.
Set<String> readDeclaredInputs(String manifestPath) {
  final declared = <String>{};
  for (final String line in File(manifestPath).readAsLinesSync()) {
    final String path = _normalizeReadPath(line.trim());
    if (path.isEmpty || path.startsWith('#')) continue;
    declared.add(path);
  }
  return declared;
}

/// [path] with `\` read as `/`, runs of slashes collapsed and a leading `./`
/// dropped: the spelling the read-set comparison uses on both sides.
String _normalizeReadPath(String path) => path
    .replaceAll(r'\', '/')
    .replaceAll(RegExp('/{2,}'), '/')
    .replaceFirst(RegExp(r'^(?:\./)+'), '');

/// The files a dart2js `.deps` file names: one URI per line, `file:` ones
/// being the files the compiler read. Other schemes name a library, not a
/// file, and are skipped: the file each resolves to has its own line.
List<String> dart2JsDepsReads(String content) {
  final reads = <String>[];
  for (final String raw in content.split('\n')) {
    final String line = raw.trim();
    if (!line.startsWith('file:')) continue;
    reads.add(Uri.parse(line).toFilePath());
  }
  return reads;
}

/// The files a dart2wasm `--depfile` names: the prerequisites of its one
/// make rule, `\ ` escaping a space and a trailing `\` continuing a line.
List<String> depfileReads(String content) {
  final String joined = content.replaceAll(RegExp(r'\\\r?\n'), ' ');
  final int colon = joined.indexOf(': ');
  final String deps = colon < 0 ? '' : joined.substring(colon + 2);
  final reads = <String>[];
  final current = StringBuffer();
  for (var i = 0; i < deps.length; i++) {
    final String c = deps[i];
    if (c == r'\' && i + 1 < deps.length && deps[i + 1] == ' ') {
      current.write(' ');
      i++;
    } else if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
      if (current.isNotEmpty) reads.add(current.toString());
      current.clear();
    } else {
      current.write(c);
    }
  }
  if (current.isNotEmpty) reads.add(current.toString());
  return reads;
}

/// The reads in [reads] that name no declared input: each is a path the
/// compiler opened, absolute or relative to [cwdPath]. A read under
/// [scratchPath] (the wrapper's own rewritten package config) is allowed;
/// any other read must be under the working directory and be listed in
/// [declared] by its exec-root-relative path.
///
/// The compile reads its sources in place, through roots that hold every
/// file of the source tree and of the output directories, so under local
/// and worker strategies an undeclared file is there to be read. This check,
/// over the compiler's own dependency report, fails such a build instead of
/// caching bytes Bazel never reruns on; the sandbox, or remote execution,
/// exposes only declared inputs in the first place.
List<String> undeclaredWebReads(
  Iterable<String> reads,
  Set<String> declared, {
  required String cwdPath,
  required String scratchPath,
}) {
  final String cwd = _normalizeReadPath(cwdPath)
      .replaceFirst(RegExp(r'/$'), '');
  final String scratch = _normalizeReadPath(
    scratchPath,
  ).replaceFirst(RegExp(r'/$'), '');
  final undeclared = <String>[];
  for (final read in reads) {
    String path = _normalizeReadPath(read);
    if (!path.startsWith('/') && !RegExp('^[a-zA-Z]:').hasMatch(path)) {
      path = '$cwd/$path';
    }
    path = Uri.file(path).normalizePath().toFilePath().replaceAll(r'\', '/');
    if (path.startsWith('$scratch/')) continue;
    if (path.startsWith('$cwd/') &&
        declared.contains(path.substring(cwd.length + 1))) {
      continue;
    }
    undeclared.add(read);
  }
  return undeclared;
}

/// Fails the compile when its dependency report names an undeclared read.
void _checkReadSet(
  String? declaredInputs,
  List<String> reads, {
  required String cwdPath,
  required String scratchPath,
}) {
  if (declaredInputs == null) return;
  final List<String> undeclared = undeclaredWebReads(
    reads,
    readDeclaredInputs(declaredInputs),
    cwdPath: cwdPath,
    scratchPath: scratchPath,
  );
  if (undeclared.isEmpty) return;
  for (final read in undeclared) {
    stderr.writeln(
      'web_template compile: the compiler read $read, which is not an input '
      'of this action. List the file in the `srcs` of the target that owns it.',
    );
  }
  exit(1);
}

void _runDart2Wasm(List<String> args) {
  final exeSuffix = Platform.isWindows ? '.exe' : '';
  final String sdkBin = File(Platform.resolvedExecutable).parent.path;
  final dartaotruntime = '$sdkBin/dartaotruntime$exeSuffix';

  final ({
    String? declaredInputs,
    List<String> extraOptions,
    List<String> forwardArgs,
    String? mainDart,
    List<String> multiRoots,
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
      multiRoots: parsed.multiRoots,
      declaredInputs: parsed.declaredInputs,
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
  List<String> multiRoots,
  String? declaredInputs,
  bool noSourceMaps,
  List<String> extraOptions,
  List<String> forwardArgs,
})
_parseDart2WasmArgs(List<String> args) {
  String? packagesPath;
  String? outputWasm;
  String? mainDart;
  String? declaredInputs;
  final multiRoots = <String>[];
  var noSourceMaps = false;
  final extraOptions = <String>[];
  final forwardArgs = <String>[];

  for (var i = 0; i < args.length; i++) {
    final String arg = args[i];
    if (arg.startsWith('--packages=')) {
      packagesPath = arg.substring('--packages='.length);
    } else if (arg.startsWith('--multi-root=')) {
      multiRoots.add(arg.substring('--multi-root='.length));
    } else if (arg.startsWith(_declaredInputsFlag)) {
      declaredInputs = arg.substring(_declaredInputsFlag.length);
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
    multiRoots: multiRoots,
    declaredInputs: declaredInputs,
    noSourceMaps: noSourceMaps,
    extraOptions: extraOptions,
    forwardArgs: forwardArgs,
  );
}

/// The inputs for one `compile wasm` or `compile js` invocation.
///
/// [_compileWasm] and [_compileDart2Js] share the tool, SDK, entrypoint,
/// package, multi-root, declared-inputs and forwarded-flag inputs; each reads
/// only the half it
/// needs (the scratch paths for dart2js, the output and wasm options for
/// dart2wasm), so one request type serves both without a Map bag.
class _WebCompileRequest {
  final String dartaotruntime;
  final String sdkBin;
  final String? packagesPath;
  final String? mainDart;

  /// The roots the compile reads its inputs in place from, exec-root relative
  /// (the generated roots, then `.`); empty to read from the working directory.
  final List<String> multiRoots;

  /// The `--declared-inputs` manifest the compiler's read set is checked
  /// against, or null for no check.
  final String? declaredInputs;
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
    required this.multiRoots,
    required this.forwardArgs,
    this.declaredInputs,
    this.tmpPath,
    this.tmpAbsPath,
    this.cwdPath,
    this.outputWasm,
    this.noSourceMaps = false,
    this.extraOptions = const [],
  });
}

/// Compiles [mainDart] to [outputWasm] (plus its `.mjs` and optional source
/// map), reading every input in place through the request's multi-roots, then
/// checks the compiler's read set against the declared inputs.
void _compileWasm(_WebCompileRequest req) {
  final exeSuffix = Platform.isWindows ? '.exe' : '';
  final outWasmFile = File(req.outputWasm!)..parent.createSync(recursive: true);
  final tmpDir = Directory('${outWasmFile.parent.path}/_wasm_tmp')
    ..createSync(recursive: true);
  final String tmpAbsPath = tmpDir.absolute.path;
  try {
    final String cwdPath = Directory.current.absolute.path;
    final List<String> rootDirPaths = req.multiRoots.isEmpty
        ? [cwdPath]
        : [
            for (final r in req.multiRoots)
              Uri.parse(rootDirUri(r))
                  .toFilePath()
                  .replaceFirst(RegExp(r'[/\\]$'), ''),
          ];
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
    final depfile = '${tmpDir.path}/main.dart.wasm.d';
    final String normMainDart = req.multiRoots.isNotEmpty
        ? _toAppSchemeRelPath(req.mainDart!)
        : req.mainDart!.replaceAll(r'\', '/');
    final wasmArgs = <String>[
      '${req.sdkBin}/snapshots/dart2wasm_product.snapshot',
      ...req.extraOptions,
      '--packages=$rewrittenPkgPath',
      '--multi-root-scheme=org-dartlang-app',
      for (final root in rootDirPaths) '--multi-root=$root',
      '--wasm-opt=${req.sdkBin}/utils/wasm-opt$exeSuffix',
      if (req.declaredInputs != null) '--depfile=$depfile',
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
    if (req.declaredInputs != null) {
      _checkReadSet(
        req.declaredInputs,
        depfileReads(File(depfile).readAsStringSync()),
        cwdPath: cwdPath,
        scratchPath: tmpAbsPath,
      );
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

/// Scrubs host-specific file URIs, temporary package_config paths, output
/// directory paths and compilation timestamps from dart2js output artifacts in [outDir].
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
  String? tmpDirPath,
  String? packagesPath,
  String? rewrittenPkgPath,
}) {
  final _ScrubPrefixes prefixes = _scrubPrefixesFor(
    cwdPath: cwdPath,
    tmpDirPath: tmpDirPath,
    packagesPath: packagesPath,
    rewrittenPkgPath: rewrittenPkgPath,
  );
  final state = _ScrubState(file.readAsStringSync());
  _scrubPackageUris(state, prefixes);
  _scrubDirectoryUris(state, prefixes);
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
  final String cwdUriPrefix;

  new({
    required this.pkgAppUri,
    required this.rewrittenPkgUri,
    required this.origPkgUri,
    required this.tmpDirUriPrefix,
    required this.cwdUriPrefix,
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

/// Computes the host-specific spellings of the cwd, temp dir and package
/// configs that compiler outputs may record.
_ScrubPrefixes _scrubPrefixesFor({
  required String cwdPath,
  required String? tmpDirPath,
  required String? packagesPath,
  required String? rewrittenPkgPath,
}) {
  final String normCwd = cwdPath.replaceAll(r'\', '/');
  final cwdPrefix = normCwd.endsWith('/') ? normCwd : '$normCwd/';
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
    cwdUriPrefix: Uri.directory(cwdPath).toString(),
  );
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

/// Rewrites recorded temp, output-directory and working-directory URIs to
/// the stable app-scheme root: a file read in place is recorded by its path
/// under the exec root, a generated one under its output directory too, and
/// both spellings name the same workspace path under the scheme.
void _scrubDirectoryUris(_ScrubState state, _ScrubPrefixes p) {
  if (p.tmpDirUriPrefix != null) {
    state.replace(p.tmpDirUriPrefix!, 'org-dartlang-app:///');
  }
  state.replace(p.cwdUriPrefix, 'org-dartlang-app:///');
  state.replace(
    RegExp(r'org-dartlang-app:///(?:\./)?bazel-out/[^/]+/(?:bin|genfiles)/'),
    'org-dartlang-app:///',
  );
}

/// Normalizes a `.info.json` dump: relative output paths and compilation
/// timestamps.
void _scrubInfoJson(_ScrubState state, File file, _ScrubPrefixes p) {
  if (!file.path.endsWith('.info.json')) return;
  state.replace(RegExp(r'(?:\./)?bazel-out/[^/]+/(?:bin|genfiles)/'), '');
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

/// Builds the `dart2js` snapshot argv for a multi-root compile that reads
/// its inputs in place.
///
/// The js frontend resolves `org-dartlang-app:///` URIs against `file:`
/// multi-roots naming the directories the inputs sit in (the generated roots,
/// then the exec root), tried in order; the entrypoint and every package root
/// are addressed by workspace path under the scheme, so the recorded library
/// URIs stay stable, with no sandbox or execroot absolute paths. Mirrors
/// [_runDart2Wasm]'s stable scheme, adapted to the js frontend's
/// `file:`-rooted multi-roots (a plain path multi-root answers "Unknown scheme
/// in uri").
List<String> buildDart2JsSnapshotArgs({
  required List<String> forwardArgs,
  required String rewrittenPkgPath,
  required List<String> rootUris,
  required String normMainDart,
}) {
  final entryUri = 'org-dartlang-app:///$normMainDart';
  return <String>[
    for (final a in forwardArgs)
      if (a.startsWith('--packages=')) '--packages=$rewrittenPkgPath' else a,
    '--multi-root-scheme=org-dartlang-app',
    for (final root in rootUris) '--multi-root=$root',
    entryUri,
  ];
}

/// The `file:` multi-root URI for the directory [multiRoot] names: the Bazel
/// action passes it exec-root-relative (`.` for the exec root), so absolutize
/// against the working directory; an already-absolute or `file:` spelling is
/// honored. Dot segments are resolved, so `.` names the working directory.
String rootDirUri(String multiRoot) {
  final String norm = multiRoot.replaceAll(r'\', '/');
  if (norm.startsWith('file:')) {
    final Uri uri = Uri.parse(norm);
    return Uri.directory(uri.toFilePath()).normalizePath().toString();
  }
  return Uri.directory(
    Directory(multiRoot).absolute.path,
  ).normalizePath().toString();
}

void _runDart2Js(List<String> args) {
  final exeSuffix = Platform.isWindows ? '.exe' : '';
  final String sdkBin = File(Platform.resolvedExecutable).parent.path;
  final dartaotruntime = '$sdkBin/dartaotruntime$exeSuffix';

  final ({
    String? declaredInputs,
    List<String> forwardArgs,
    String? mainDart,
    List<String> multiRoots,
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
  String? rewrittenPkgPath;
  try {
    rewrittenPkgPath = _compileDart2Js(
      _WebCompileRequest(
        dartaotruntime: dartaotruntime,
        sdkBin: sdkBin,
        tmpPath: tmpDir.path,
        tmpAbsPath: tmpAbsPath,
        multiRoots: parsed.multiRoots,
        declaredInputs: parsed.declaredInputs,
        packagesPath: parsed.packagesPath,
        mainDart: parsed.mainDart,
        forwardArgs: parsed.forwardArgs,
        cwdPath: cwdPath,
      ),
      outJs: parsed.outJs,
    );
  } finally {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  }

  _scrubDart2JsResults(
    _Dart2JsScrubRequest(
      outJs: parsed.outJs,
      cfeOnly: cfeOnly,
      cwdPath: cwdPath,
      tmpAbsPath: tmpAbsPath,
      packagesPath: parsed.packagesPath,
      rewrittenPkgPath: rewrittenPkgPath,
    ),
  );
}

/// The `compile js` flags in [args].
({
  String? outJs,
  List<String> multiRoots,
  String? declaredInputs,
  String? packagesPath,
  String? mainDart,
  List<String> forwardArgs,
})
_parseDart2JsArgs(List<String> args) {
  String? outJs;
  String? declaredInputs;
  String? packagesPath;
  String? mainDart;
  final multiRoots = <String>[];
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
      multiRoots.add(arg.substring('--multi-root='.length));
    } else if (arg.startsWith(_declaredInputsFlag)) {
      declaredInputs = arg.substring(_declaredInputsFlag.length);
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
    multiRoots: multiRoots,
    declaredInputs: declaredInputs,
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

/// Runs the dart2js snapshot in [tmpPath]'s scratch, rewriting the package
/// config first when the compile mounts multi-roots, then checks the
/// compiler's read set (its `<outJs>.deps` report) against the declared
/// inputs; answers the rewritten package config the output scrub needs.
String? _compileDart2Js(_WebCompileRequest req, {required String? outJs}) {
  String? rewrittenPkgPath;
  List<String> jsArgs;
  if (req.multiRoots.isNotEmpty &&
      req.packagesPath != null &&
      req.mainDart != null) {
    final String normCwd = req.cwdPath!.replaceAll(r'\', '/');
    final cwdPrefix = normCwd.endsWith('/') ? normCwd : '$normCwd/';
    rewrittenPkgPath = '${req.tmpPath!}/package_config.json';
    _rewritePackageConfig(
      req.packagesPath!,
      normCwd,
      cwdPrefix,
      rewrittenPkgPath,
    );
    final String relMain = _toAppSchemeRelPath(req.mainDart!);
    jsArgs = buildDart2JsSnapshotArgs(
      forwardArgs: req.forwardArgs,
      rewrittenPkgPath: rewrittenPkgPath,
      rootUris: [for (final root in req.multiRoots) rootDirUri(root)],
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
  if (req.declaredInputs != null && outJs != null) {
    final deps = File('$outJs.deps');
    if (!deps.existsSync()) {
      stderr.writeln(
        'web_template compile: dart2js wrote no dependency report at '
        '${deps.path}, so its reads cannot be checked; refusing the output.',
      );
      exit(1);
    }
    _checkReadSet(
      req.declaredInputs,
      dart2JsDepsReads(deps.readAsStringSync()),
      cwdPath: req.cwdPath!,
      scratchPath: req.tmpAbsPath!,
    );
  }
  return rewrittenPkgPath;
}

/// What [_scrubDart2JsResults] normalizes: this action's own compiler outputs
/// plus the host-specific paths the scrub rewrites to stable spellings.
class _Dart2JsScrubRequest {
  final String? outJs;
  final bool cfeOnly;
  final String cwdPath;
  final String tmpAbsPath;
  final String? packagesPath;
  final String? rewrittenPkgPath;

  const new({
    required this.outJs,
    required this.cfeOnly,
    required this.cwdPath,
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
        tmpDirPath: scrub.tmpAbsPath,
        packagesPath: scrub.packagesPath,
        rewrittenPkgPath: scrub.rewrittenPkgPath,
      );
    }
  }
}
