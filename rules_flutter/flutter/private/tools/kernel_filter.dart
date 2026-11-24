/// Runs `frontend_server` for a kernel compile and drops the lines of its
/// batch protocol from the output, so a successful build prints nothing.
///
/// Outside interactive mode `frontend_server` still frames each compile for a
/// client that is not there: `result <uuid>`, the bare `<uuid>`, and
/// `<uuid> <output.dill> <error count>`. No flag turns them off, and Bazel
/// shows an action's output on success. Every other line, errors above all,
/// passes through unchanged, as does the exit code.
///
/// Before the compiler runs, every `@<file>` in its argv is expanded as a
/// define flagfile: each non-empty line is one argument, preserving its text,
/// and a line that is not a `-D` argument fails with the file and line number.
/// A nested `@<file>` expands recursively; a missing, unreadable or cyclic
/// file fails naming the chain. This keeps define values out of the action
/// command line while the compiler still receives them as ordinary flags.
///
/// Before the compiler runs, every declared source's directives are checked
/// against the declared inputs (`directive_guard.dart`): a directive that
/// names no declared file — a `file:` URI in any spelling, any other
/// unexpected scheme, or a relative URI climbing out of the declared inputs —
/// fails the build, under every strategy. The compile mounts a generated-only
/// stage plus the exec root, so under local and worker strategies undeclared
/// files are visible to the compiler: hermeticity rests on three layers — the
/// directive guard before the compile, the dependency report verified against
/// the declared-inputs manifest after it (failing closed on anything it
/// cannot verify), and the sandbox, or remote execution, which exposes only
/// declared inputs.
///
/// After the compiler runs, its `+file://` dependency lines are verified
/// against the same manifest: a read of a file the manifest does not name
/// fails the build instead of caching bytes Bazel never reruns on.
/// The lines are dropped either way, so a successful build stays silent.
/// The report is mandatory and fails closed: it must name a declared source
/// and the entrypoint, in a declared spelling, or the compile fails and its
/// output is deleted even when it exited 0.
///
/// The report cannot be switched off: the tool appends its own
/// `--print-incremental-dependencies` after the caller's flags (the last
/// occurrence wins in `frontend_server`'s `package:args` parsing), and a
/// compile that exits 0 while reporting no reads at all fails closed — a
/// real compile reads at least its entrypoint, so zero reads means the
/// report was silenced by other means.
///
/// The manifest is the only source of allowances: the tool derives nothing
/// from the compile argv. A flag smuggled into the argv (`--packages`,
/// `--import-dill`, `--platform` and the like, whether in `vm_flags` or
/// `extra_flags`) names no allowed read, and the refusal path deletes only
/// the manifest's output — never a path the argv names.
///
/// A plugin that is not available on the compiled platform fails the build
/// with a hint saying so: shipping without its registration (where `flutter
/// build` would fail) is never the right recovery.
///
/// It has no package dependencies and runs with the bare Dart SDK.
///
/// Usage:
///   dart kernel_filter.dart --declared-inputs <manifest> -- <executable> <arguments>
library;

import 'dart:io';

import 'directive_guard.dart';

/// Reads one flagfile as raw lines, empty lines included.
typedef FlagfileReader = List<String> Function(String path);

/// Reads [path] as raw lines, keeping empty lines so a refusal can name the
/// 1-based line number a reader sees in the file.
List<String> readFlagfileLines(String path) => File(path).readAsLinesSync();

/// Expands every `@<file>` argument in [argv] as a define flagfile.
///
/// Each non-empty line of a flagfile is one argv element, preserving its text
/// exactly: no shell word splitting and no quote stripping. A line naming
/// another `@<file>` is expanded recursively. A line that is not a nested
/// reference must start with `-D`; such a line is already a spelled compiler
/// argument, so no `-D` prefix is added. [readFile] substitutes the filesystem
/// in tests.
List<String> expandDefineFlagfiles(
  List<String> argv, {
  FlagfileReader? readFile,
}) {
  final List<String> Function(String path) read = readFile ?? readFlagfileLines;
  final out = <String>[];
  for (final arg in argv) {
    if (arg.startsWith('@')) {
      out.addAll(expandDefineFlagfile(arg.substring(1), readFile: read));
    } else {
      out.add(arg);
    }
  }
  return out;
}

/// Expands one define flagfile named [path], recursively.
///
/// [chain] names the files that included this one, so a missing, unreadable or
/// cyclic file fails with the whole chain. A line that does not start with
/// `-D` fails with the file and its 1-based line number. [readFile] substitutes
/// the filesystem in tests.
List<String> expandDefineFlagfile(
  String path, {
  FlagfileReader? readFile,
  List<String> chain = const [],
}) {
  final List<String> Function(String path) read = readFile ?? readFlagfileLines;
  return _expandDefineFlagfile(path, read, chain, <String>{});
}

List<String> _expandDefineFlagfile(
  String path,
  FlagfileReader read,
  List<String> chain,
  Set<String> visiting,
) {
  final String identity = File(path).absolute.path;
  final fileChain = [...chain, path];
  if (!visiting.add(identity)) {
    throw FormatException(
      'define flagfile cycle: ${fileChain.join(' -> ')}',
    );
  }
  try {
    final List<String> lines = _readDefineFlagfile(path, read, fileChain);
    final out = <String>[];
    for (var index = 0; index < lines.length; index++) {
      final String line = lines[index];
      if (line.isEmpty) continue;
      if (line.startsWith('@')) {
        out.addAll(
          _expandDefineFlagfile(
            line.substring(1),
            read,
            fileChain,
            visiting,
          ),
        );
      } else if (line.startsWith('-D')) {
        out.add(line);
      } else {
        throw FormatException(
          'define flagfile $path line ${index + 1}: expected an argument '
          'starting with -D, got "$line"',
        );
      }
    }
    return out;
  } finally {
    visiting.remove(identity);
  }
}

List<String> _readDefineFlagfile(
  String path,
  FlagfileReader read,
  List<String> chain,
) {
  try {
    return read(path);
  } on FileSystemException catch (e) {
    throw FormatException(
      'define flagfile chain ${chain.join(' -> ')}: cannot read $path: '
      '${e.message}',
    );
  }
}

const _uuid =
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';

final _boundary = RegExp('^(result $_uuid|$_uuid|$_uuid \\S.* \\d+)\$');

/// Whether [line] is one of `frontend_server`'s batch-protocol lines.
bool isBoundaryLine(String line) => _boundary.hasMatch(line);

/// Splits [stdoutText] into the `+uri` dependency lines the compiler printed
/// and everything else (without its batch-protocol lines).
({List<String> reads, String rest}) splitDependencyLines(String stdoutText) {
  final reads = <String>[];
  final kept = <String>[];
  for (final String line in stdoutText.split('\n')) {
    if (isBoundaryLine(line)) continue;
    if (line.startsWith('+')) {
      reads.add(line);
    } else {
      kept.add(line);
    }
  }
  return (reads: reads, rest: kept.join('\n'));
}

/// [path] with each run of slashes collapsed to one: the front end spells a
/// `lib/src//d.dart` read as written but reads the file `lib/src/d.dart`, so
/// the declared-set comparison uses the collapsed spelling. Nothing else is
/// normalized (`.` and `..` segments, case and symlinks stay).
String _collapseSlashes(String path) => path.replaceAll(RegExp('/{2,}'), '/');

/// The exec-root-relative path a `+file://` dependency [line] names, or null
/// when the line names no file under the compile's working directory. Percent
/// escapes decode once, the way the front end spells them.
String? dependencyExecPath(String line) {
  final String text = line.substring(1).trim();
  final Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException {
    return null;
  }
  if (uri.scheme != 'file') return null;
  final String path = _collapseSlashes(uri.toFilePath().replaceAll(r'\', '/'));
  final String cwd = Directory.current.path.replaceAll(r'\', '/');
  if (path == cwd) return '';
  if (!path.startsWith('$cwd/')) return null;
  return path.substring(cwd.length + 1);
}

/// The absolute normalized path a `+file://` dependency [line] names, or null
/// when the line is not a `file:` URI. Relative spellings resolve against the
/// compile's working directory. Percent escapes decode once and `.`/`..`
/// segments resolve first (`toFilePath` normalizes both spellings), the way
/// the front end spells them.
String? dependencyAbsolutePath(String line) {
  final String text = line.substring(1).trim();
  final Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException {
    return null;
  }
  if (uri.scheme != 'file') return null;
  String path = _collapseSlashes(uri.toFilePath().replaceAll(r'\', '/'));
  if (!path.startsWith('/') && !RegExp(r'^[a-zA-Z]:').hasMatch(path)) {
    path = '${Directory.current.path.replaceAll(r'\', '/')}/$path';
  }
  return path;
}

/// The subset of `frontend_server`'s `+uri` dependency [lines] that names no
/// declared input: each entry is the offending line. [declared] holds the
/// exec-root-relative paths from the `--declared-inputs` manifest's source
/// and staged sections, and [extraAllowed] the manifest's `allowed-reads`
/// section (the package config, the platform dill, the summary dills, the
/// native-assets manifest) — never the compile argv.
///
/// A read spelt like a working-directory path is decided by the manifest
/// alone. Any other read — including one under a `--filesystem-root` the
/// compile argv names — is undeclared: the manifest is the only source of
/// allowances, so a smuggled argv root widens nothing.
List<String> findUndeclaredReads(
  List<String> lines,
  Set<String> declared,
  Set<String> extraAllowed,
) => findUndeclaredReadsWithMirrorRoots(
  lines,
  declared,
  extraAllowed,
  const [],
);

/// [findUndeclaredReads] with an additional test-only allowance: a read from
/// outside the working directory is excused when it sits strictly under one
/// of [mirrorRoots].
///
/// Only the differential test harness calls this, to accept the mirrored tree
/// it links the way the build stages created libraries — a re-analysis would
/// declare and stage the same files. Production ([runFiltered] and the
/// incremental worker) never passes anything but `const []`: allowances come
/// only from the manifest, so no argv flag, environment variable or manifest
/// field a build can set reaches [mirrorRoots]. Reads outside every mirror
/// root (absolute `file:` imports, package-config escapes) are still refused,
/// as are `..` escapes, which resolve before the prefix check and so name a
/// path outside the root.
List<String> findUndeclaredReadsWithMirrorRoots(
  List<String> lines,
  Set<String> declared,
  Set<String> extraAllowed,
  List<String> mirrorRoots,
) {
  final undeclared = <String>[];
  for (final line in lines) {
    final String? rel = dependencyExecPath(line);
    if (rel != null) {
      if (!declared.contains(rel) && !extraAllowed.contains(rel)) {
        undeclared.add(line);
      }
      continue;
    }
    if (!_readUnderRoot(line, mirrorRoots)) {
      undeclared.add(line);
    }
  }
  return undeclared;
}

/// Whether a `+uri` dependency [line] from outside the working directory
/// names a file strictly under one of the test-harness [mirrorRoots].
///
/// The check is structural on purpose: the mirrored roots stage exactly the
/// declared inputs, so a read under a root is a declared file re-spelt at
/// its mirrored location. Production never reaches this branch — it calls
/// [findUndeclaredReads], which passes no roots — and the differential
/// harness reaches it only through [findUndeclaredReadsWithMirrorRoots].
/// Reads outside every root (absolute `file:` imports, package-config
/// escapes: the RT8/RT10 cases) are still refused, as are `..` escapes,
/// which resolve before the prefix check and so name a path outside the
/// root.
bool _readUnderRoot(String line, List<String> mirrorRoots) {
  if (mirrorRoots.isEmpty) return false;
  final String? abs = dependencyAbsolutePath(line);
  if (abs == null) return false;
  final String cwd = Directory.current.path.replaceAll(r'\', '/');
  for (final rawRoot in mirrorRoots) {
    if (abs.startsWith('${_absoluteRoot(rawRoot, cwd)}/')) return true;
  }
  return false;
}

/// [root] as an absolute slash path: a relative root resolves against [cwd].
String _absoluteRoot(String root, String cwd) {
  String path = root.replaceAll(r'\', '/');
  while (path.endsWith('/') && path.length > 1) {
    path = path.substring(0, path.length - 1);
  }
  if (!path.startsWith('/') && !RegExp(r'^[a-zA-Z]:').hasMatch(path)) {
    path = '$cwd/$path';
  }
  return path;
}

/// The compile argv with the dependency report forced on.
///
/// Returns [cmdArgs] with `--print-incremental-dependencies` inserted after
/// the caller's flags, immediately before the final entrypoint argument (the
/// entrypoint closes the `frontend_server` argv, so a flag appended after it
/// would not parse as a flag). `frontend_server` parses flags with
/// `package:args`, where the last occurrence of a boolean flag wins, so the
/// tool's occurrence overrides any caller spelling that analysis did not
/// already refuse.
List<String> withForcedDependencyReport(List<String> cmdArgs) {
  const forced = '--print-incremental-dependencies';
  if (cmdArgs.length < 2) return [...cmdArgs, forced];
  return [...cmdArgs.sublist(0, cmdArgs.length - 1), forced, cmdArgs.last];
}

/// The compile's declared inputs, read from a `--declared-inputs` manifest.
///
/// The manifest lists one exec-root-relative path per line in sections: the
/// declared sources, then a `# staged` marker with the staging root's
/// symlinks to the generated inputs, then `# allowed-reads` with every other
/// file the compiler may read (the package config, the platform dill, the
/// summary dills, the native-assets manifest), then `# filesystem-roots` with
/// the mounted roots the directive guard resolves through, then
/// `# entrypoint` with the entrypoint's declared spellings (its exec path,
/// plus its stage twin when staged), then `# output` with the output dill.
/// Written by `flutter_kernel_compile_action` from its Starlark `File`
/// objects. Shared with the incremental worker, which guards and verifies
/// against the same manifest.
typedef KernelInputsManifest = ({
  /// Every path in the manifest's sources section, in order.
  List<String> sources,

  /// The sources plus the staged spellings: what the compiler may read as
  /// program inputs.
  Set<String> declared,

  /// The manifest's `allowed-reads` section (never the compile argv).
  Set<String> extraAllowed,

  /// The manifest's `filesystem-roots` section.
  List<String> fsRoots,

  /// The manifest's `entrypoint` section: the entrypoint's declared
  /// spellings. Empty when the manifest predates the section; callers fall
  /// back to the sources section's first entry (Starlark writes main first).
  List<String> entrypoint,

  /// The manifest's `# output` entry, or null when absent.
  String? outputDill,
});

/// Reads the `--declared-inputs` manifest at [manifestPath].
KernelInputsManifest readKernelInputsManifest(String manifestPath) {
  final sources = <String>[];
  final declared = <String>{};
  final extraAllowed = <String>{};
  final fsRoots = <String>[];
  final entrypoint = <String>[];
  String? outputDill;
  var section = 'sources';
  for (final String line in File(manifestPath).readAsLinesSync()) {
    final String path = line.trim().replaceAll(r'\', '/');
    if (path.isEmpty) continue;
    if (path.startsWith('#')) {
      section = switch (path) {
        '# staged' => 'staged',
        '# allowed-reads' => 'reads',
        '# filesystem-roots' => 'roots',
        '# entrypoint' => 'entry',
        '# output' => 'output',
        _ => 'unknown',
      };
      continue;
    }
    switch (section) {
      case 'sources':
        sources.add(path);
        declared.add(path);
      case 'staged':
        declared.add(path);
      case 'reads':
        extraAllowed.add(path);
      case 'roots':
        fsRoots.add(path);
      case 'entry':
        entrypoint.add(path);
      case 'output':
        outputDill ??= path;
      case 'unknown':
        break;
    }
  }
  return (
    sources: sources,
    declared: declared,
    extraAllowed: extraAllowed,
    fsRoots: fsRoots,
    entrypoint: entrypoint,
    outputDill: outputDill,
  );
}

/// The refusal for a compiler read of a file the manifest does not name.
/// Shared with the incremental worker so both paths refuse with the same
/// message.
String undeclaredReadMessage(String line) =>
    'flutter: the compiler read $line, which is not a declared input of '
    'this compile. Declare the file in `srcs` (typically '
    '`glob(["lib/**/*.dart"])`) or stop importing it.';

/// The failure when a successful compile reports no dependency reads at all:
/// a real compile reads at least its entrypoint, so zero reads means the
/// report was silenced and the read-set check has nothing to verify. Shared
/// with the incremental worker so both paths fail closed with the same
/// message.
String noDependencyReadsMessage() =>
    'flutter: the compiler reported no dependency reads, so the read-set '
    'check has nothing to verify. A real compile reads at least its '
    'entrypoint: the report was silenced, and the compile controls '
    '`--print-incremental-dependencies` itself. Remove any silencer from '
    '`extra_flags` and rebuild.';

/// The failure when a successful compile's report names no declared source:
/// every read is an allowed non-source read, so the check has verified no
/// program input. Shared with the incremental worker so both paths fail
/// closed with the same message.
String noDeclaredSourceReadsMessage() =>
    'flutter: the compiler reported reads, but none names a declared source '
    'of this compile, so the read-set check has verified no program input. '
    'A real compile reads at least its entrypoint: the report is incomplete, '
    'and the compile controls `--print-incremental-dependencies` itself. '
    'Remove any silencer from `extra_flags` and rebuild.';

/// The failure when a successful compile's report names the entrypoint under
/// no declared spelling. Shared with the incremental worker so both paths
/// fail closed with the same message.
String missingEntrypointReadMessage(String entry) =>
    'flutter: the compiler reported reads, but none names the entrypoint '
    '$entry, so the read-set check has not seen the root library. A real '
    'compile reads its entrypoint: the report is incomplete, and the compile '
    'controls `--print-incremental-dependencies` itself. Remove any silencer '
    'from `extra_flags` and rebuild.';

/// The entrypoint's declared spellings from [manifest]: the explicit
/// `# entrypoint` section, else the sources section's first entry (Starlark
/// writes main first). Shared with the incremental worker so both paths
/// require the same spellings.
List<String> entrypointSpellingCandidates(KernelInputsManifest manifest) {
  if (manifest.entrypoint.isNotEmpty) return manifest.entrypoint;
  if (manifest.sources.isNotEmpty) return [manifest.sources.first];
  return const [];
}

/// The refusal when none of the report's [lines] names a declared source, or
/// null when at least one does. Entries naming no file under the compile's
/// working directory fail the undeclared-read check first; this sees only
/// what that check accepted. Shared with the incremental worker.
String? checkNoDeclaredSourceReads(
  List<String> lines,
  Set<String> declared,
) {
  for (final line in lines) {
    final String? rel = dependencyExecPath(line);
    if (rel != null && declared.contains(rel)) return null;
  }
  return noDeclaredSourceReadsMessage();
}

/// The refusal when none of the report's [lines] names one of the
/// entrypoint's declared [candidates], or null when one does. Shared with
/// the incremental worker.
String? checkMissingEntrypointRead(
  List<String> lines,
  List<String> candidates,
) {
  if (candidates.isEmpty) {
    return missingEntrypointReadMessage('the entrypoint');
  }
  for (final line in lines) {
    final String? rel = dependencyExecPath(line);
    if (rel != null && candidates.contains(rel)) return null;
  }
  return missingEntrypointReadMessage(candidates.first);
}

Future<void> main(List<String> argv) async {
  exit(await runFiltered(argv, stdout, stderr));
}

/// Parses the tool flags before `--`: the manifest path plus the compiler
/// argv.
///
/// Returns null after describing the usage error on [err].
({String manifestPath, String executable, List<String> cmdArgs})?
_splitFilterArgv(List<String> argv, StringSink err) {
  final int i = argv.indexOf('--');
  if (i < 0 || i + 1 >= argv.length) {
    err.writeln(
      'Usage: dart kernel_filter.dart --declared-inputs <manifest> -- <executable> <arguments>',
    );
    return null;
  }
  String? manifestPath;
  for (var j = 0; j < i; j++) {
    if (argv[j] == '--declared-inputs' && j + 1 < i) {
      manifestPath = argv[++j];
    } else {
      err.writeln('kernel_filter: unexpected argument ${argv[j]}.');
      return null;
    }
  }
  if (manifestPath == null) {
    err.writeln(
      'kernel_filter: missing required --declared-inputs <manifest>.',
    );
    return null;
  }
  return (
    manifestPath: manifestPath,
    executable: argv[i + 1],
    cmdArgs: argv.sublist(i + 2),
  );
}

/// Refuses declared sources whose directives name no declared input.
///
/// Returns 1 after writing each refusal on [err], or null to keep going.
int? _refuseDisallowedDirectives(
  List<String> sources,
  List<String> fsRoots,
  StringSink err,
) {
  final List<String> guardErrors = findDisallowedFlutterDirectives(
    sources,
    fsRoots,
    tool: 'flutter',
  );
  if (guardErrors.isEmpty) return null;
  for (final error in guardErrors) {
    err.writeln(error);
  }
  return 1;
}

/// Deletes a refused compile's output dill when it exists.
void _deleteRefusedOutput(String? outputDill) {
  if (outputDill == null) return;
  try {
    File(outputDill).deleteSync();
  } on FileSystemException {
    // Already gone; the nonzero exit fails the action either way.
  }
}

/// Reports a failed compile: its dependency lines are dropped while every
/// other line, both streams and the exit code pass through. A missing
/// platform plugin gets the hint instead of a silent pass-through.
int _reportCompilerFailure(
  ProcessResult result,
  StringSink out,
  StringSink err,
) {
  final ({List<String> reads, String rest}) split = splitDependencyLines(
    result.stdout as String,
  );
  out.write(split.rest);
  err.write(result.stderr as String);
  if ('${result.stdout}${result.stderr}'.contains(
    'is not available on this platform.',
  )) {
    err.writeln(
      'flutter: this compile imports a plugin that is not available on the '
      'compiled platform. Remove the dependency or add a platform '
      "implementation; the build fails instead of shipping without the "
      "plugin's registration.",
    );
  }
  return result.exitCode;
}

/// Verifies a successful compile's dependency report against the manifest.
///
/// The report is mandatory and fails closed: zero reads, a read of a file
/// the manifest does not name, no read of a declared source, or no read of
/// the entrypoint under a declared spelling each fail the build. Returns 1
/// after writing each refusal on [err] — deleting only the manifest's
/// output, never a path the argv names — or null when every read is declared
/// and the caller should print the filtered output.
int? _refuseUndeclaredReads(
  ({List<String> reads, String rest}) split,
  KernelInputsManifest manifest,
  StringSink err,
) {
  if (split.reads.isEmpty) {
    err.writeln(noDependencyReadsMessage());
    _deleteRefusedOutput(manifest.outputDill);
    return 1;
  }
  final List<String> undeclared = findUndeclaredReads(
    split.reads,
    manifest.declared,
    manifest.extraAllowed,
  );
  if (undeclared.isNotEmpty) {
    for (final line in undeclared) {
      err.writeln(undeclaredReadMessage(line));
    }
    // Delete only the manifest's output: an `--output-dill` smuggled into
    // the argv names no file here, so the refusal cannot be redirected at
    // (or away from) another path.
    _deleteRefusedOutput(manifest.outputDill);
    return 1;
  }
  final String? noSource = checkNoDeclaredSourceReads(
    split.reads,
    manifest.declared,
  );
  if (noSource != null) {
    err.writeln(noSource);
    _deleteRefusedOutput(manifest.outputDill);
    return 1;
  }
  final String? noEntry = checkMissingEntrypointRead(
    split.reads,
    entrypointSpellingCandidates(manifest),
  );
  if (noEntry != null) {
    err.writeln(noEntry);
    _deleteRefusedOutput(manifest.outputDill);
    return 1;
  }
  return null;
}

/// Runs the command [argv] names after `--`, writing its output to [out] and
/// [err] without the protocol and dependency lines; returns its exit code.
///
/// The tool flags before `--` name the compile's declared inputs
/// (`--declared-inputs <manifest>`): the manifest lists one exec-root-relative
/// path per line in sections — the declared sources, then a `# staged`
/// marker, then the staging root's symlinks to the generated inputs, then
/// `# allowed-reads` (the package config, the platform dill, the summary
/// dills, the native-assets manifest), then `# filesystem-roots` (the mounted
/// roots the directive guard resolves through), then `# entrypoint` with the
/// entrypoint's declared spellings, then `# output` with the output dill —
/// written by `flutter_kernel_compile_action` from its Starlark `File`
/// objects. The sources' directives are refused before the compiler runs
/// when they name an undeclared file, and the compiler's own read set is
/// verified against the manifest after it runs — including that it names a
/// declared source and the entrypoint. Nothing is read from the compile
/// argv for allowances: flags after `--` run the compiler unchanged, except
/// that `@<file>` arguments are expanded as define flagfiles first and never
/// widen what it may read.
Future<int> runFiltered(
  List<String> argv,
  StringSink out,
  StringSink err,
) async {
  final ({List<String> cmdArgs, String executable, String manifestPath})?
  parsed = _splitFilterArgv(argv, err);
  if (parsed == null) return 2;
  final String manifestPath = parsed.manifestPath;
  if (!File(manifestPath).existsSync()) {
    err.writeln(
      'kernel_filter: declared-inputs manifest $manifestPath does not exist.',
    );
    return 2;
  }
  // The manifest lists the declared sources, then `# staged` with the
  // staging root's symlinks to the generated inputs, then `# allowed-reads`
  // with every other file the compiler may read, then `# filesystem-roots`,
  // then `# entrypoint` with the entrypoint's declared spellings, then
  // `# output` with the output dill. The guard scans the sources, while the
  // read set allows the source spellings, the staged spellings, and the
  // allowed reads — all of them manifest entries, never argv values.
  final KernelInputsManifest inputs = readKernelInputsManifest(manifestPath);
  final List<String> sources = [
    for (final path in inputs.sources)
      if (path.endsWith('.dart')) path,
  ];

  final List<String> cmdArgs;
  try {
    cmdArgs = expandDefineFlagfiles(parsed.cmdArgs);
  } on FormatException catch (e) {
    err.writeln('kernel_filter: ${e.message}');
    return 2;
  }

  final int? directiveRefusal = _refuseDisallowedDirectives(
    sources,
    inputs.fsRoots,
    err,
  );
  if (directiveRefusal != null) return directiveRefusal;

  final ProcessResult result = await Process.run(
    parsed.executable,
    withForcedDependencyReport(cmdArgs),
  );
  if (result.exitCode != 0) {
    return _reportCompilerFailure(result, out, err);
  }

  final ({List<String> reads, String rest}) split = splitDependencyLines(
    result.stdout as String,
  );
  final int? readsRefusal = _refuseUndeclaredReads(split, inputs, err);
  if (readsRefusal != null) return readsRefusal;
  out.write(split.rest);
  err.write(result.stderr as String);
  return result.exitCode;
}
