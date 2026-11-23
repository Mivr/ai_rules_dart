/// The `frontend_server` incremental session behind the incremental worker.
///
/// A [CompilerSession] speaks the server's line protocol: `compile`,
/// `recompile` (a delta, then `accept`), and the two-phase `reset` plus an
/// empty `recompile` whose full dill carries no history (rule F). A failed
/// compile is `reject`ed so the server stays at its last accepted state.
/// [FrontendServerSession] is the real process; tests substitute a fake.
///
/// Change classification ([classifyChanged]) and URI mapping ([uriOfStaged])
/// are pure and shared by the worker and its tests.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'kernel_filter.dart';

/// The multi-root scheme a staged file is compiled under.
const incrAppSchemeRoot = 'org-dartlang-app:///';

/// The flag making the server write one component instead of one per package.
const noIncrementalSerialization = '--no-incremental-serialization';

/// The argv marker the rule adds when `//flutter:dev_incremental_serialization`
/// is on. The worker consumes it; `frontend_server` never sees it.
const devIncrementalSerializationMarker = '--dev-incremental-serialization';

/// The outcome of one `compile` or `recompile` command.
typedef CompileResult = ({
  int errors,
  List<String> diagnostics,
  List<String> depLines,
});

/// The `frontend_server` arguments (after the executable) for [flags], whose
/// first element is the executable and whose output is already redirected.
///
/// The server runs with `--incremental` and, unless [devIncremental],
/// `--no-incremental-serialization`; the dev mode keeps the server's
/// incremental serialization, so its dill is not byte-identical to a one-shot
/// compile.
List<String> frontendServerSpawnArgs(
  List<String> flags,
  String incrementalDill, {
  bool devIncremental = false,
}) {
  final int insertAt = incrementalFlagIndex(flags);
  return [
    ...flags.sublist(1, insertAt + 1),
    '--incremental',
    if (!devIncremental) noIncrementalSerialization,
    '--output-incremental-dill',
    incrementalDill,
    ...flags.sublist(insertAt + 1),
    // The worker verifies the compiler's read set against the
    // declared-inputs manifest; the report cannot be left off. Appended
    // after the caller's flags so it wins `package:args`' last occurrence.
    '--print-incremental-dependencies',
  ];
}

/// One warm `frontend_server`: `compile` once, then deltas.
///
/// The two-phase protocol always finishes with `reset` plus an empty
/// `recompile`, so the full dill is written by a compile that compiled
/// nothing and carries no per-library history.
abstract class CompilerSession {
  Future<CompileResult> compile(String entry);
  Future<CompileResult> recompile(
    String entry,
    List<String> uris, {
    bool resetFirst = false,
  });
  Future<void> accept();
  Future<void> reject();
  Future<void> close();
  bool get alive;
}

/// Drops a leading tool path (`argv[0]`): `kernel_filter`'s argv after
/// `argv[0]` starts with `--declared-inputs` or an `@flagfile`, so a first
/// argument that is neither can only be the tool itself. The harness sends
/// the full argv with the worker at `argv[0]`; Bazel's worker protocol and
/// `main` omit it, so stripping is a no-op there.
/// ([argv] is already flagfile-expanded or not; the tool path is never a
/// flag or a flagfile, so this runs the same before or after expansion.)
List<String> stripWorkerArgv0(List<String> argv) {
  if (argv.isNotEmpty &&
      !argv.first.startsWith('-') &&
      !argv.first.startsWith('@')) {
    return argv.sublist(1);
  }
  return argv;
}

/// Splits [argvWithMarker] around `--`: the manifest flag and path before it,
/// the compiler command after it, consuming the dev-serialization marker. Throws [FormatException] when malformed.
({String manifestPath, List<String> command, bool devIncremental})
splitWorkerArgv(List<String> argvWithMarker) {
  final bool devIncremental = argvWithMarker.contains(
    devIncrementalSerializationMarker,
  );
  final List<String> argv = [
    for (final a in argvWithMarker)
      if (a != devIncrementalSerializationMarker) a,
  ];
  final int i = argv.indexOf('--declared-inputs');
  if (i < 0 || i + 1 >= argv.length) {
    throw const FormatException(
      'incr_fkc_worker: missing required --declared-inputs <manifest>.',
    );
  }
  final String manifestPath = argv[i + 1];
  final int j = argv.indexOf('--');
  if (j < 0 || j + 1 >= argv.length || j < i) {
    throw const FormatException(
      'Usage: incr_fkc_worker --declared-inputs <manifest> -- <executable> <arguments>',
    );
  }
  for (var k = 0; k < j; k++) {
    if (k == i || k == i + 1) continue;
    throw FormatException(
      'incr_fkc_worker: unexpected argument ${argv[k]}.',
    );
  }
  return (
    manifestPath: manifestPath,
    command: argv.sublist(j + 1),
    devIncremental: devIncremental,
  );
}

/// Expands the outer Bazel parameter-file entries in [argv], then every
/// define flagfile those entries name.
///
/// The outer `@<file>` is the parameter file Bazel hands the worker: each
/// non-empty line is one argument, in order. Multiline Bazel parameter files
/// shell-quote arguments holding whitespace with single quotes, so a line
/// wrapped in exactly one pair of quotes unwraps; anything else passes through
/// untouched. An expanded entry naming another `@<file>` is a define flagfile:
/// it expands recursively under [expandDefineFlagfile]'s rules, so a line that
/// is not a `-D` argument, a missing or unreadable file and a cycle all fail
/// with the file chain and, for a bad line, its 1-based line number.
///
/// [readFile] reads a flagfile's lines; it takes the working directory so
/// tests can substitute a fake filesystem.
List<String> expandWorkerFlagfiles(
  List<String> argv, {
  FlagfileReader? readFile,
}) {
  final List<String> Function(String path) read = readFile ?? readFlagfileLines;
  final out = <String>[];
  for (final a in argv) {
    if (!a.startsWith('@')) {
      out.add(a);
      continue;
    }
    final String outerPath = a.substring(1);
    final List<String> lines = _readOuterParamFile(outerPath, read);
    for (final line in lines) {
      if (line.isEmpty) continue;
      final String arg = _unquoteParamLine(line);
      if (arg.startsWith('@')) {
        out.addAll(
          expandDefineFlagfile(
            arg.substring(1),
            readFile: read,
            chain: [outerPath],
          ),
        );
      } else {
        out.add(arg);
      }
    }
  }
  return out;
}

List<String> _readOuterParamFile(String path, FlagfileReader read) {
  try {
    return read(path);
  } on FileSystemException catch (e) {
    throw FormatException(
      'Bazel parameter file $path: cannot read it: ${e.message}',
    );
  }
}

/// Strips one pair of surrounding single quotes when the inside holds no
/// quote of its own; every other line is already a literal argument.
String _unquoteParamLine(String line) {
  if (line.length >= 2 &&
      line.startsWith("'") &&
      line.endsWith("'") &&
      !line.substring(1, line.length - 1).contains("'")) {
    return line.substring(1, line.length - 1);
  }
  return line;
}

/// Normalizes an exec-root-relative path for prefix comparison: `/`
/// separators, no trailing slashes, no leading `./` segments.
String normalizeWorkerPath(String path) {
  String slash = path.replaceAll(r'\', '/');
  slash = slash.replaceFirst(RegExp(r'/+$'), '');
  return slash.replaceFirst(RegExp(r'^(?:\./)+'), '');
}

/// Whether [roots] mount the exec root: a `.` (or empty) root resolves every
/// exec-root-relative path under the app scheme, so sources read in place
/// have a delta URI.
bool mountsExecRoot(List<String> roots) {
  for (final rawRoot in roots) {
    final String r = normalizeWorkerPath(rawRoot);
    if (r.isEmpty || r == '.') return true;
  }
  return false;
}

/// The app-scheme key of an in-place exec-root-relative path: workspace paths
/// keep their spelling, while a generated file's `bazel-out/<config>/bin/`
/// prefix strips to the workspace-relative path it is staged at — the same
/// key its staged twin maps to, so the two spellings dedupe to one URI.
String inPlaceSourceKey(String path) {
  final RegExpMatch? bin = RegExp('^bazel-out/[^/]+/bin/').firstMatch(path);
  if (bin != null) return path.substring(bin[0]!.length);
  return path;
}

/// Whether [path] can name a file under the exec root: relative, non-empty,
/// and climbing nowhere above it. Anything else maps to no URI, so the
/// server restarts cold rather than recompiling a URI the compiler may not
/// know.
bool isInPlacePath(String path) {
  if (path.isEmpty || path == '.') return false;
  if (path.startsWith('/') || RegExp(r'^[a-zA-Z]:').hasMatch(path)) {
    return false;
  }
  return !path.split('/').any((s) => s == '..');
}

/// The multi-root URI the compiler knows the file [path] by, or null when it
/// names no file the compiler resolves.
///
/// A file under a filesystem [roots] entry maps through that root's prefix.
/// Otherwise, when [roots] mount the exec root (`.`), an in-place
/// exec-root-relative path maps to its app-scheme key: sources are declared
/// as themselves and read in place, so a changed source carries its own URI
/// with no staged twin.
String? uriOfStaged(String path, List<String> roots) {
  final String p = normalizeWorkerPath(path);
  for (final rawRoot in roots) {
    final String r = normalizeWorkerPath(rawRoot);
    if (r.isEmpty || r == '.') continue;
    if (p.startsWith('$r/')) {
      return incrAppSchemeRoot + p.substring(r.length + 1);
    }
  }
  if (!mountsExecRoot(roots) || !isInPlacePath(p)) return null;
  return incrAppSchemeRoot + inPlaceSourceKey(p);
}

/// How the worker reaches the changed inputs of one request.
typedef ChangedInputs = ({
  /// Staged `.dart` files to recompile through their multi-root URIs.
  List<String> uris,

  /// When non-null, a changed input no delta can carry: the server must
  /// restart cold. Names the reason (the offending path).
  String? restartReason,
});

/// Sorts [changed] exec-root-relative paths into a delta or a cold restart.
///
/// Changed `.dart` files recompile through their multi-root URIs: staged
/// files through their stage root, and — when the roots mount the exec root
/// (`.`) — sources read in place through their app-scheme key, with no
/// staged twin. A generated file changed in place keys the same URI as its
/// staged twin, so the pair dedupes to one recompile. Any other changed
/// input (the package config, the platform dill, the flags, a non-`.dart`
/// file, a `.dart` file under no root and in no manifest section) restarts
/// the server cold, as does a manifest source that maps to no URI while the
/// exec root stays unmounted — the legacy staged-twin world, where its twin
/// carries the URI. [manifestSources] holds the manifest's sources section.
ChangedInputs classifyChanged(
  List<String> changed,
  List<String> roots,
  Set<String> manifestSources,
) {
  final uris = <String>[];
  final seenUris = <String>{};
  for (final p in changed) {
    if (p.endsWith('.dart')) {
      final String? uri = uriOfStaged(p, roots);
      if (uri != null) {
        if (seenUris.add(uri)) uris.add(uri);
        continue;
      }
      if (!mountsExecRoot(roots) && manifestSources.contains(p)) {
        // The source behind a staged symlink: its staged twin carries the
        // URI.
        continue;
      }
    }
    return (uris: const [], restartReason: p);
  }
  return (uris: uris, restartReason: null);
}

/// Folds one compile's `+uri`/`-uri` dependency [lines] into [current], the
/// cumulative read set: additions join it, removals leave it.
void foldDepLines(Set<String> current, List<String> lines) {
  for (final d in lines) {
    if (d.startsWith('+')) {
      current.add(d.substring(1));
    } else if (d.startsWith('-')) {
      current.remove(d.substring(1));
    }
  }
}

/// A [CompilerSession] over a real `frontend_server` child process.
///
/// [fs] is the compiler command from the action argv (`dartaotruntime`, VM
/// flags, the snapshot, flags, entrypoint last). The server runs with
/// `--incremental` and `--no-incremental-serialization`, writing its full
/// dill to [fullDill] (a private path, never the action output) and deltas
/// to [incrementalDill]. The dependency report is forced on so the worker
/// can verify the read set.
class FrontendServerSession implements CompilerSession {
  new _(
    this._process,
    this._lines,
    this.roots,
    this.entry,
  ) {
    _process.exitCode.then((_) => _exited = true);
  }

  final Process _process;
  final StreamIterator<String> _lines;
  final List<String> roots;
  final String entry;
  bool _exited = false;

  /// Starts the server for [fs] in [cwd], deleting any stale private output
  /// first: `frontend_server` initializes from `--output-dill` when that file
  /// exists, so a restarted server must not see the old output.
  static Future<FrontendServerSession> start(
    List<String> fs,
    String fullDill,
    String incrementalDill, {
    required String cwd,
    bool devIncremental = false,
  }) async {
    final List<String> flags = [...fs.sublist(0, fs.length - 1)];
    final String entry = fs.last;
    final int outI = flags.indexOf('--output-dill');
    if (outI < 0 || outI + 1 >= flags.length) {
      throw const FormatException(
        'incr_fkc_worker: compiler argv has no --output-dill.',
      );
    }
    for (final p in [fullDill, incrementalDill]) {
      try {
        File(p).deleteSync();
      } on FileSystemException {
        // Absent; the fresh server starts clean either way.
      }
    }
    flags[outI + 1] = fullDill;
    final List<String> spawnArgs = frontendServerSpawnArgs(
      flags,
      incrementalDill,
      devIncremental: devIncremental,
    );
    final roots = <String>[];
    for (var k = 0; k < flags.length - 1; k++) {
      if (flags[k] == '--filesystem-root') roots.add(flags[k + 1]);
    }
    final Process process = await Process.start(
      flags[0],
      spawnArgs,
      workingDirectory: cwd,
    );
    final StreamIterator<String> lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    return FrontendServerSession._(process, lines, roots, entry);
  }

  Future<void> _send(String text) async {
    _process.stdin.writeln(text);
    await _process.stdin.flush();
  }

  Future<CompileResult> _readResult() async {
    if (!await _lines.moveNext()) {
      throw const FormatException(
        'incr_fkc_worker: frontend_server exited before its result line.',
      );
    }
    final String first = _lines.current;
    if (!first.startsWith('result ')) {
      throw FormatException(
        'incr_fkc_worker: expected a result line, got "$first".',
      );
    }
    final String key = first.split(' ')[1];
    final diagnostics = <String>[];
    final deps = <String>[];
    while (await _lines.moveNext()) {
      final String s = _lines.current;
      if (s == key) continue;
      if (s.startsWith('$key ')) {
        final List<String> parts = s.split(' ');
        final int errors = parts.length > 2 ? int.parse(parts.last) : 1;
        return (errors: errors, diagnostics: diagnostics, depLines: deps);
      }
      if ((s.startsWith('+') || s.startsWith('-')) && s.contains('://')) {
        deps.add(s);
      } else {
        diagnostics.add(s);
      }
    }
    throw const FormatException(
      'incr_fkc_worker: frontend_server exited mid-compile.',
    );
  }

  @override
  Future<CompileResult> compile(String entry) async {
    await _send('compile $entry');
    return _readResult();
  }

  @override
  Future<CompileResult> recompile(
    String entry,
    List<String> uris, {
    bool resetFirst = false,
  }) async {
    if (resetFirst) await _send('reset');
    final String urisBlock = uris.map((u) => '$u\n').join();
    await _send('recompile $entry kk\n${urisBlock}kk');
    return _readResult();
  }

  @override
  Future<void> accept() async => _send('accept');

  @override
  Future<void> reject() async {
    await _send('reject');
    // The rejection acknowledgement is two lines; they carry no content the
    // worker uses.
    await _lines.moveNext();
    await _lines.moveNext();
  }

  @override
  bool get alive => !_exited;

  /// How long `close` waits for the server to leave on `quit`, and then for
  /// a SIGKILLed server to be reaped, before giving up on that wait. Short
  /// enough that a persistent worker exits within a few seconds of stdin
  /// EOF; quitting is a trivial command, so a healthy server is long gone.
  static const _quitGrace = Duration(seconds: 5);

  /// Whether the process pipes were already released.
  bool _released = false;

  /// Stops the server and releases every process handle: the stdout
  /// subscription, whose lingering keeps the worker process alive after
  /// stdin EOF, and the stdin pipe. A server that ignores `quit` is
  /// SIGKILLed, so no `frontend_server` of ours is left running.
  @override
  Future<void> close() async {
    if (alive) {
      await _quitGracefully();
    }
    await _releaseHandles();
  }

  /// Asks the server to quit, SIGKILLing it when it does not leave in time.
  /// Never throws: every pipe error below means the server is already gone.
  Future<void> _quitGracefully() async {
    try {
      await _send('quit');
      await _process.exitCode.timeout(_quitGrace);
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
      try {
        await _process.exitCode.timeout(_quitGrace);
      } on TimeoutException {
        // Unkillable; the pipes are still released below.
      }
    } on StateError {
      // Already gone (stdin closed under us); the exit handler marks it.
    } on SocketException {
      // The stdin pipe broke under us; the server is already gone.
    }
  }

  /// Cancels the stdout subscription and closes the stdin pipe. Runs on
  /// every close, even when the server is already dead: its idle
  /// subscription is what kept served workers from exiting on stdin EOF.
  /// Idempotent and never throws.
  Future<void> _releaseHandles() async {
    if (_released) return;
    _released = true;
    try {
      await _lines.cancel();
    } on StateError {
      // Already cancelled; nothing left to release.
    }
    try {
      await _process.stdin.close();
    } on StateError {
      // Already closed; nothing left to release.
    } on SocketException {
      // The stdin pipe broke under us; the server is already gone.
    }
  }
}

/// Where the server's own flags go in the compiler command [flags]: after
/// the frontend_server snapshot when one is named, else after the first
/// non-flag argument past the executable (a script path in tests).
int incrementalFlagIndex(List<String> flags) {
  final int snap = flags.indexWhere((a) => a.endsWith('.snapshot'));
  if (snap >= 0) return snap;
  final int script = flags.indexWhere(
    (a) => !a.startsWith('-'),
    1,
  );
  return script < 0 ? 0 : script;
}

/// Builds the compiler command for one request: [fs] with `--output-dill`
/// pointed at the private [fullDill].
List<String> redirectOutputDill(List<String> fs, String fullDill) {
  final flags = [...fs];
  final int outI = flags.indexOf('--output-dill');
  if (outI < 0 || outI + 1 >= flags.length) {
    throw const FormatException(
      'incr_fkc_worker: compiler argv has no --output-dill.',
    );
  }
  flags[outI + 1] = fullDill;
  return flags;
}

/// The configuration key of one compiler command: the argv minus the output
/// path, so requests that differ only in where the dill lands share a warm
/// server.
String configurationKey(List<String> fs, String Function(List<int>) hash) {
  final List<String> flags = redirectOutputDill(fs, '<out>');
  return hash(utf8.encode(flags.join('\x00'))).substring(0, 16);
}
