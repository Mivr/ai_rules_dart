// Rewrites URI-bearing arguments for `kernel_worker`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _kernelWorkerUriFlags = <String>{
  '--dart-sdk-summary',
  '--packages-file',
  '--libraries-file',
  '--multi-root',
  '--input-summary',
  '--input-linked',
  '--source',
  '--native-assets',
};

bool _isAsciiAlpha(int c) =>
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);

/// True when [s] starts with a Windows drive letter (`C:/...`, `d:\...`, `C:`).
bool isWindowsDrivePath(String s) =>
    s.length >= 2 &&
    _isAsciiAlpha(s.codeUnitAt(0)) &&
    s.codeUnitAt(1) == 0x3a &&
    (s.length == 2 || s.codeUnitAt(2) == 0x2f || s.codeUnitAt(2) == 0x5c);

/// Converts a Windows drive-letter or UNC file path to a `file://` URI string
/// for `kernel_worker` (`package:frontend_server/compute_kernel.dart`).
String kernelWorkerUri(String pathOrUri) {
  if (isWindowsDrivePath(pathOrUri) || pathOrUri.startsWith(r'\\')) {
    return Uri.file(pathOrUri, windows: true).toString();
  }
  return pathOrUri;
}

/// Converts [pathOrUri] to a local file system path if it is a `file://` URI,
/// or returns it unchanged.
String filePathOf(String pathOrUri) {
  if (pathOrUri.startsWith('file:///')) {
    final String rest = pathOrUri.substring('file:///'.length);
    if (isWindowsDrivePath(rest)) return rest;
  }
  if (pathOrUri.startsWith('file://')) {
    return Uri.parse(pathOrUri).toFilePath(windows: true);
  }
  return pathOrUri;
}

String _rewriteRedirectUri(String value) {
  final int sep = value.indexOf('|');
  if (sep < 0) return kernelWorkerUri(value);
  return '${kernelWorkerUri(value.substring(0, sep))}|'
      '${kernelWorkerUri(value.substring(sep + 1))}';
}

/// Rewrites Windows drive-letter and UNC paths in `kernel_worker` URI-bearing
/// flags to `file:///` URIs while leaving `--output` and other file-system
/// path flags unchanged.
List<String> kernelWorkerArgs(List<String> args) {
  final out = <String>[];
  for (var i = 0; i < args.length; i++) {
    final String arg = args[i];
    if (_kernelWorkerUriFlags.contains(arg) && i + 1 < args.length) {
      out
        ..add(arg)
        ..add(kernelWorkerUri(args[++i]));
      continue;
    }
    if (arg == '--redirect' && i + 1 < args.length) {
      out
        ..add(arg)
        ..add(_rewriteRedirectUri(args[++i]));
      continue;
    }
    if (arg.startsWith('--redirect=')) {
      final String raw = arg.substring('--redirect='.length);
      out.add('--redirect=${_rewriteRedirectUri(raw)}');
      continue;
    }
    var matchedEq = false;
    for (final String flag in _kernelWorkerUriFlags) {
      final prefix = '$flag=';
      if (arg.startsWith(prefix)) {
        out.add('$flag=${kernelWorkerUri(arg.substring(prefix.length))}');
        matchedEq = true;
        break;
      }
    }
    if (!matchedEq) {
      out.add(arg);
    }
  }
  return out;
}

/// Precomputed canonical summary-to-key and root-to-module index for one
/// unused-inputs calculation, replacing per-(module, summary) linear scans.
typedef KmodRootIndex = ({
  Map<String, Set<String>> keysOfDill,
  String Function(String path) canon,
  Set<String> Function(String dir) definedKeysOf,
  Set<int> Function(String canonPath) ownerIndicesOf,
  String? Function(String canonPath) firstOwnerOf,
});

/// Indexes [dirs] and [graphEntries] using [canonicalize] for realpaths.
KmodRootIndex buildKmodRootIndex({
  required List<String> dirs,
  required Iterable<({String key, String dill})> graphEntries,
  required String Function(String path) canonicalize,
}) {
  final canonMemo = <String, String>{};
  String canon(String path) =>
      canonMemo.putIfAbsent(path, () => canonicalize(path));
  final keysOfDill = <String, Set<String>>{};
  final dillsUnderSlash = <String, Set<String>>{};
  for (final entry in graphEntries) {
    if (!canonMemo.containsKey(entry.dill)) {
      _indexSlashPrefixes(entry.dill, canon(entry.dill), dillsUnderSlash);
    }
    (keysOfDill[canon(entry.dill)] ??= <String>{}).add(entry.key);
  }
  final Map<String, List<int>> ownersByRoot = _buildOwnersByRoot(
    dirs,
    canon,
    dillsUnderSlash,
  );
  Set<int> ownerIndicesOf(String canonPath) =>
      _ownerIndicesIn(ownersByRoot, canonPath);
  final keysByDir = <String, Set<String>>{};
  keysOfDill.forEach((String dill, Set<String> keys) {
    for (final int idx in ownerIndicesOf(dill)) {
      (keysByDir[dirs[idx]] ??= <String>{}).addAll(keys);
    }
  });
  return (
    keysOfDill: keysOfDill,
    canon: canon,
    definedKeysOf: (String dir) => keysByDir[dir] ?? const <String>{},
    ownerIndicesOf: ownerIndicesOf,
    firstOwnerOf: (String canonPath) =>
        _firstOwnerIn(dirs, ownersByRoot, canonPath),
  );
}

Map<String, List<int>> _buildOwnersByRoot(
  List<String> dirs,
  String Function(String path) canon,
  Map<String, Set<String>> dillsUnderSlash,
) {
  const suffix = '/index.json';
  final ownersByRoot = <String, List<int>>{};
  for (var i = 0; i < dirs.length; i++) {
    final String dir = dirs[i];
    final String index = canon('$dir$suffix');
    final roots = <String>{
      canon(dir),
      if (index.endsWith(suffix))
        index.substring(0, index.length - suffix.length),
      ...?dillsUnderSlash['$dir/'],
    };
    for (final root in roots) {
      (ownersByRoot[root] ??= <int>[]).add(i);
    }
  }
  return ownersByRoot;
}

Set<int> _ownerIndicesIn(Map<String, List<int>> ownersByRoot, String path) {
  final matched = <int>{};
  final List<int>? exact = ownersByRoot[path];
  if (exact != null) matched.addAll(exact);
  for (var i = 0; i < path.length; i++) {
    if (path.codeUnitAt(i) != 0x2f) continue;
    final List<int>? atPrefix = ownersByRoot[path.substring(0, i)];
    if (atPrefix != null) matched.addAll(atPrefix);
  }
  return matched;
}

String? _firstOwnerIn(
  List<String> dirs,
  Map<String, List<int>> ownersByRoot,
  String path,
) {
  int? best;
  for (final int idx in _ownerIndicesIn(ownersByRoot, path)) {
    if (best == null || idx < best) best = idx;
  }
  return best == null ? null : dirs[best];
}

void _indexSlashPrefixes(
  String dill,
  String canonDill,
  Map<String, Set<String>> out,
) {
  for (var i = 0; i < dill.length; i++) {
    if (dill.codeUnitAt(i) == 0x2f) {
      (out[dill.substring(0, i + 1)] ??= <String>{}).add(canonDill);
    }
  }
}

/// Startup flag naming the phase-timing log; see the header of `kernel_module.dart`.
const phaseTimingFlag = '--phase-timing-log=';

/// The `--phase-timing-log` path, or null when the flag was not given.
String? phaseTimingLog;

/// Requests this process has timed, the next request's `request` counter.
var _timedRequests = 0;

/// Whether a failed timing-log write was already reported on stderr.
var _timingLogFailureReported = false;

/// The zone key under which a request's [PhaseTimer] travels, so the code
/// that does the work records into its own request when requests overlap.
final Object phaseTimerKey = Object();

/// The running request's timer, or null when timing is off.
PhaseTimer? get phaseTimer => Zone.current[phaseTimerKey] as PhaseTimer?;

/// Wall times of one request, written by [compileTimed] as one JSON line.
class PhaseTimer {
  /// The phases a line reports, in order.
  static const List<String> phases = [
    'prepare',
    'plan',
    'compile',
    'outline',
    'write',
  ];

  final int request = _timedRequests++;
  final _total = Stopwatch()..start();
  final _micros = <String, int>{};
  final _cache = <({String path, bool hit})>[];

  /// Microseconds claimed by finished `timed` blocks, so an enclosing block
  /// reports only its own time.
  int claimed = 0;
  String? output;
  final _trips = <int>[];
  final _sameSummaries = <bool>[];
  int? childPid;
  int? childServedBefore;

  /// Adds [micros] to [phase]; a `compile` block is one round trip, kept
  /// apart so a fresh child's first one shows against its later ones.
  void add(String phase, int micros) {
    _micros[phase] = (_micros[phase] ?? 0) + micros;
    if (phase == 'compile') _trips.add(micros);
  }

  void noteCache(String path, {required bool hit}) =>
      _cache.add((path: path, hit: hit));

  /// Records the child a round trip goes to; the first round trip fixes how
  /// many requests that child had served before this request. [sameSummaries]
  /// is whether the trip names the `--input-summary` files of the child's
  /// previous trip.
  void noteChild(int pid, int served, bool sameSummaries) {
    childPid = pid;
    childServedBefore ??= served;
    _sameSummaries.add(sameSummaries);
  }

  /// The JSON line for a request that ended with [exitCode].
  String line(int exitCode) => jsonEncode({
    'output': output,
    'worker_pid': pid,
    'request': request,
    'child_pid': childPid,
    'child_served_before': childServedBefore,
    'exit_code': exitCode,
    for (final phase in phases) '${phase}_us': _micros[phase] ?? 0,
    'compile_round_trips': _trips.length,
    'compile_trips_us': _trips,
    'compile_trips_same_summaries': _sameSummaries,
    'total_us': _total.elapsedMicroseconds,
    'cache': [
      for (final entry in _cache) {'entry': entry.path, 'hit': entry.hit},
    ],
  });
}

/// Runs [body], and with `--phase-timing-log` appends the request's timing
/// line to the log after it, whatever the outcome.
Future<int> compileTimed(Future<int> Function() body) {
  final String? path = phaseTimingLog;
  return path == null ? body() : _compileLogged(path, body);
}

Future<int> _compileLogged(String path, Future<int> Function() body) async {
  final timer = PhaseTimer();
  var code = 1;
  try {
    return code = await runZoned(body, zoneValues: {phaseTimerKey: timer});
  } finally {
    _appendTimingLine(path, timer.line(code));
  }
}

/// Appends [line] to the log at [path] in one write. A failure is reported
/// once on stderr and never fails the request.
void _appendTimingLine(String path, String line) {
  try {
    File(path).writeAsStringSync('$line\n', mode: FileMode.append);
  } on FileSystemException catch (error) {
    if (_timingLogFailureReported) return;
    _timingLogFailureReported = true;
    stderr.writeln(
      'kernel_module: cannot write $phaseTimingFlag$path: '
      '${error.osError?.message ?? error.message}',
    );
  }
}

/// Runs [body], adding its own wall time to [phase] when timing is on.
Future<T> timed<T>(String phase, Future<T> Function() body) {
  final PhaseTimer? timer = phaseTimer;
  return timer == null ? body() : _timedBy(timer, phase, body);
}

Future<T> _timedBy<T>(
  PhaseTimer timer,
  String phase,
  Future<T> Function() body,
) async {
  final void Function(String) end = _beginSpan(timer);
  try {
    return await body();
  } finally {
    end(phase);
  }
}

/// `timed` for a synchronous [body].
T timedSync<T>(String phase, T Function() body) {
  final PhaseTimer? timer = phaseTimer;
  if (timer == null) return body();
  final void Function(String) end = _beginSpan(timer);
  try {
    return body();
  } finally {
    end(phase);
  }
}

/// Starts one timed block. The returned function ends it and adds the block's
/// own wall time, what remains after the blocks nested in it, to a phase.
void Function(String phase) _beginSpan(PhaseTimer timer) {
  final int before = timer.claimed;
  final watch = Stopwatch()..start();
  return (String phase) {
    final int elapsed = watch.elapsedMicroseconds;
    timer.add(phase, elapsed - (timer.claimed - before));
    timer.claimed = before + elapsed;
  };
}

/// The `kernel_worker` flag naming the package config.
const packagesFlag = '--packages-file';

/// The `kernel_worker` flag adding a multi-root directory.
const multiRootFlag = '--multi-root';

/// The `kernel_worker` flag naming the multi-root URI scheme.
const multiRootSchemeFlag = '--multi-root-scheme';

/// The command-line options of one `compileModule` run.
class ModuleOptions {
  final List<String> base = <String>[];

  /// How many leading [base] arguments came from `--define-file`: the next
  /// defines file's go after them, and every other `-D` after all of them.
  int defineFileArgs = 0;
  final List<String> sources = <String>[];
  final List<String> inputSources = <String>[];
  final List<String> ownSourceFiles = <String>[];
  final List<String> multiRoots = <String>[];
  final List<String> closureExcluded = <String>[];
  final List<String> inputKmods = <String>[];
  final List<String> extraLibraries = <String>[];
  String? excludedPath;
  String? unusedInputsPath;
  String? output;
  String? outputOutline;
  String? packagesFile;
  String? librariesJson;
  String librariesPlatform = 'vm';
  String multiRootPrefix = 'org-dartlang-root:///';
  bool noDrop = false;
  bool checkImports = false;
  String? targetLabel;
  final Set<String> ownPackages = <String>{};
  final Set<String> directPackages = <String>{};
}

/// Parses an import-check flag at [i] into [options], returning the next index,
/// or null if [rawArgs] at [i] is not an import-check flag.
int? parseImportCheckArg(List<String> rawArgs, int i, ModuleOptions options) {
  final String arg = rawArgs[i];
  if (arg == '--check-imports') {
    options.checkImports = true;
    return i + 1;
  }
  if (i + 1 >= rawArgs.length) return null;
  final String next = rawArgs[i + 1];
  switch (arg) {
    case '--target-label':
      options.targetLabel = next;
      return i + 2;
    case '--own-package':
      options.ownPackages.add(next);
      return i + 2;
    case '--direct-package':
      options.directPackages.add(next);
      return i + 2;
    default:
      return null;
  }
}

/// Parses a compiler pass-through argument at [i] into [options].
void parseBaseArg(List<String> rawArgs, int i, ModuleOptions options) {
  final String arg = rawArgs[i];
  if (arg == packagesFlag) {
    options.packagesFile = rawArgs[i + 1];
  } else if (arg.startsWith('$packagesFlag=')) {
    options.packagesFile = arg.substring(packagesFlag.length + 1);
  } else if (arg == multiRootFlag) {
    options.multiRoots.add(rawArgs[i + 1]);
  } else if (arg.startsWith('$multiRootFlag=')) {
    options.multiRoots.add(arg.substring(multiRootFlag.length + 1));
  } else if (arg == multiRootSchemeFlag) {
    options.multiRootPrefix = '${rawArgs[i + 1]}:///';
  } else if (arg.startsWith('$multiRootSchemeFlag=')) {
    options.multiRootPrefix =
        '${arg.substring(multiRootSchemeFlag.length + 1)}:///';
  }
  options.base.add(arg);
}

/// Expands `@params` arguments in one-shot mode, one argument per line.
Future<List<String>> expandOneShotParamFiles(List<String> args) async {
  final out = <String>[];
  for (final arg in args) {
    if (arg.startsWith('@') && File(arg.substring(1)).existsSync()) {
      final List<String> lines = await File(arg.substring(1)).readAsLines();
      out.addAll(lines);
    } else {
      out.add(arg);
    }
  }
  return out;
}
