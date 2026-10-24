// Trains an app-JIT snapshot, so that the snapshot does not depend on where or
// how it was built.
//
// Two rules use it: `dart_binary` in `jit-snapshot` mode, which trains on the
// program itself, and `dart_test_runner_snapshot`, which trains the
// `package:test` runner on one real test. It is pure Dart (no shell), so it
// runs on any host the rules support. The exec SDK's `dart` runs it from
// source, so it needs no build of its own.
//
// Usage:
//   dart app_jit_snapshot.dart --dart=<dart> --snapshot=<out> \
//       [--dartvm=<dartvm>] [--enable-asserts] [--fallback-allowed] \
//       [--train-key=<key>] [--lock-timeout=<seconds>] \
//       [--env=KEY=VALUE]... [--copy=DEST=SOURCE]... [--copy-tree=DEST=DIR]... \
//       -- <dart arguments>
//
// `<key>` selects the keyed training paths (see [trainDirForKey]): both
// snapshot actions pass the deterministic key of the declared output, so two
// different targets train in parallel and only concurrent trainings of one
// output contend. `<seconds>` bounds the wait for the training lock (see
// [_openConstantLock]); both snapshot actions pass it only when it differs
// from [defaultLockTimeoutSecs], so the action key follows a non-default
// deadline.
//
// The `<dart arguments>` are what `dart` runs in the training: the script
// first, then its own arguments. Each `--copy` and `--copy-tree` places its
// files under the training directory, and the tool rewrites the script and the
// staged-tree paths among the dart arguments to absolute ones before spawning
// the training run (see [stageTrainingArgs]); a program argument that merely
// names a staged file stays relative for the program to resolve itself.
//
// The snapshot should not depend on how it was built. Three things do that:
//  * `--deterministic` makes the VM's own choices repeat, so one training run
//    and the next write the same bytes. `--no-background-compilation` keeps
//    optimizing compiles on the training thread.
//  * The training is passed no `--packages` option, and every path the
//    training VM resolves is byte-identical on every build of one target. On
//    POSIX each output trains at its own keyed path
//    `/tmp/rules_dart_jit-<key>` (see [trainDirForKey]), where `<key>` is 16
//    lowercase hex characters of a deterministic digest of the declared
//    output's root-relative path: the working directory, the training VM
//    copy, the staged inputs, `HOME`, `TMPDIR`, the script, and the
//    `--snapshot` output all read the same whatever output root or sandbox
//    the build runs in, so no interned path string can name the build.
//    Concurrent trainings of one output serialize on the keyed lock
//    `/tmp/rules_dart_jit-<key>.lock`; trainings of different outputs hold
//    different locks and run in parallel. A JIT-heavy program (hot loops,
//    many small classes, string-keyed maps, closures) trains identical bytes
//    across output roots and strategies at its keyed path; training the
//    same inputs in varying directories trains different bytes from the same
//    inputs (see the layout property test). The one relative path left, the
//    runner's test path, is constant across builds by construction (it is
//    joined onto the absolute `--precompiled` directory by the runner
//    itself).
//  * The training VM runs from a copy of the SDK's `dart` (and `dartvm`)
//    inside the training directory, so every build of one target trains with
//    the binary at one path, whatever SDK install it came from.
//
// The training runs with the training directory as its working directory:
// the runner only runs a test path naming a file under the working
// directory, so the working directory must hold the staged test. `package:test`
// derives heap strings from the training run's own paths at startup, but at
// the keyed path those read the same on every build, so the runner
// snapshot is byte-identical across builds too, and its action carries no
// `no-remote-cache` requirement: the first machine's snapshot is reused, and
// every dependant keeps one action key.
//
// Where the keyed directory is unavailable the action fails instead of
// training elsewhere: a private-scratch training emits different bytes under
// the same action key, and both actions are remote-cacheable, so one host's
// state would leak into shared outputs. A stale entry of our own is removed
// first, whatever its type (a regular file, a symlink, a FIFO, a socket, or a
// directory, removed recursively): nothing that was there is ever read or
// followed, so a symlink's target is untouched. A directory we own is made
// writable before it is listed, so a read-only tree a crashed training left
// behind still clears. The lock opens by file descriptor for every user (see
// `jit_lock.dart`): an existing lock opens read-write with O_NOFOLLOW and
// without O_CREAT, so a second user opens the first user's 0666 lock even
// under `fs.protected_regular`; a missing lock is published at 0666 through a
// uniquely named temporary linked over the lock path, so it never exists at a
// narrower mode whatever the umask or the scheduling. Only a regular file with
// link count 1 is kept (never written and never chmodded); a symlink,
// directory, FIFO, hard link or other entry at the lock path is never followed
// and never created through, and fails the action instead — a shared lock
// would let two trainings hold it at once, and the second would delete the
// first's live training directory as its own. A taken lock is re-checked
// against its path before it is trusted (a /tmp cleaner may have deleted or
// replaced it while it was taken) and reopened on a mismatch. A lock held
// past the deadline fails the
// action the same way (see [_openConstantLock]): the failure names the lock,
// the holder's PID, the deadline, and the remedies. Either failure names the path, the
// entry's type and its owner (the uid, plus the user name where the host
// resolves it): have the lock's owner make it world-writable or remove it
// where its mode is what denies us, have its owner (or root) remove it for
// anything else, pass
// `--@rules_dart//dart:jit_snapshot_fallback=true` to allow the
// private-scratch fallback (whose bytes are not reproducible, so builds that
// allow it and builds that do not have different action keys), or, for the
// runner snapshot, `--@rules_dart//dart:test_runner_snapshot=false` to run
// the kernel instead. Windows keeps the private scratch directory beside the
// output with the one notice below. Under linux-sandbox with a hermetic
// `/tmp` (the default on CI Linux runners) the path is private per action, so
// host state cannot block it there; that sandbox was not executed while
// making this change (the machine has no user namespaces), so the claim is
// the sandbox's documented `/tmp` namespacing, not a local measurement.
//
// The training input must be a kernel file whose library URIs are already
// resolved (as the `jit-snapshot` action's compiled dill is): with no
// `--packages` value a runtime `package:` import cannot resolve. A program
// whose own training run is not deterministic (it reads the clock, random
// numbers, `Directory.current`, or files outside the build) yields a
// snapshot that differs between builds, whatever this tool does.
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../guard/lib/directive_guard.dart';
import 'comma_patch.dart';
import 'dill_reader.dart';
import 'jit_lock.dart';

void main(List<String> argv) {
  if (argv.isNotEmpty && argv.first == '--aot') {
    _runAot(argv.sublist(1));
    return;
  }
  if (argv.isNotEmpty && argv.first == '--gen-kernel') {
    _runGenKernel(argv.sublist(1));
    return;
  }
  _trainFromArgs(_parseTrainArgs(argv));
}

/// The parsed training arguments: everything the snapshot training carries
/// from `main` into [_trainFromArgs] (see [_parseTrainArgs]). Nullable fields
/// are required options `main` has not validated yet; [_trainFromArgs] exits
/// unless they are present.
typedef _TrainingJob = ({
  String? dart,
  String? dartvm,
  String? snapshot,
  String? trainKey,
  int lockTimeout,
  List<String> dartArgs,
  bool enableAsserts,
  bool fallbackAllowed,
  Map<String, String> env,
  List<_Pair> copies,
  List<_Pair> trees,
});

/// Parses the training arguments (the `main` parsing below the `--aot` and
/// `--gen-kernel` dispatches), returning them as a [_TrainingJob].
_TrainingJob _parseTrainArgs(List<String> argv) {
  String? dart;
  String? dartvm;
  String? snapshot;
  String? trainKey;
  var lockTimeout = defaultLockTimeoutSecs;
  var enableAsserts = false;
  var fallbackAllowed = false;
  final env = <String, String>{};
  final copies = <_Pair>[];
  final trees = <_Pair>[];

  var i = 0;
  for (; i < argv.length; i++) {
    final arg = argv[i];
    if (arg == '--') {
      i++;
      break;
    }
    if (arg == '--enable-asserts' || arg == '--fallback-allowed') {
      // `--fallback-allowed` opts into the private-scratch fallback when the
      // constant training path is unavailable (see [_trainInScratch]): set
      // from `--@rules_dart//dart:jit_snapshot_fallback=true`, which is part
      // of the snapshot actions' command lines, so builds that allow the
      // fallback and builds that do not have different action keys.
      if (arg == '--fallback-allowed') {
        fallbackAllowed = true;
      } else {
        enableAsserts = true;
      }
      continue;
    }
    final eq = arg.indexOf('=');
    if (eq < 0) _usage('unknown argument $arg');
    final name = arg.substring(0, eq);
    final value = arg.substring(eq + 1);
    switch (name) {
      case '--dart':
        dart = value;
      case '--dartvm':
        dartvm = value;
      case '--snapshot':
        snapshot = value;
      case '--train-key':
        // The keyed training paths (see [trainDirForKey]): 16 lowercase hex
        // characters of a deterministic digest of the declared output's
        // root-relative path, passed by both snapshot actions, so the key is
        // identical across output bases, strategies and machines.
        if (!_isTrainKey(value)) _usage('expected 16 lowercase hex in $arg');
        trainKey = value;
      case '--lock-timeout':
        // Seconds to wait for the training lock (see [_openConstantLock]):
        // passed by both snapshot actions only when it differs from
        // [defaultLockTimeoutSecs], so the action key follows the deadline.
        final secs = int.tryParse(value);
        if (secs == null || secs <= 0) {
          _usage('expected seconds above 0 in $arg');
        }
        lockTimeout = secs;
      case '--env':
        final pair = _Pair.parse(value, arg);
        env[pair.key] = pair.value;
      case '--copy':
        copies.add(_Pair.parse(value, arg));
      case '--copy-tree':
        trees.add(_Pair.parse(value, arg));
      default:
        _usage('unknown argument $arg');
    }
  }
  final dartArgs = argv.sublist(i);
  return (
    dart: dart,
    dartvm: dartvm,
    snapshot: snapshot,
    trainKey: trainKey,
    lockTimeout: lockTimeout,
    dartArgs: dartArgs,
    enableAsserts: enableAsserts,
    fallbackAllowed: fallbackAllowed,
    env: env,
    copies: copies,
    trees: trees,
  );
}

/// Trains the snapshot from parsed `main` arguments, exiting when required
/// arguments are missing, when the training fails, or when it writes no
/// snapshot (see [_trainInScratch]).
void _trainFromArgs(_TrainingJob job) {
  final dart = job.dart;
  final dartvm = job.dartvm;
  final snapshot = job.snapshot;
  final dartArgs = job.dartArgs;
  if (dart == null || snapshot == null || dartArgs.isEmpty) {
    _usage('--dart, --snapshot and the dart arguments are required');
  }
  trainKeyOverride = job.trainKey;
  lockTimeoutSecs = job.lockTimeout;

  final out = File(snapshot).absolute;
  final exitCode = _trainInScratch(
    job: (
      dart: File(dart).absolute.path,
      dartvm: dartvm == null ? null : File(dartvm).absolute.path,
      snapshot: snapshot,
      trainKey: job.trainKey,
      lockTimeout: job.lockTimeout,
      dartArgs: dartArgs,
      enableAsserts: job.enableAsserts,
      fallbackAllowed: job.fallbackAllowed,
      env: job.env,
      copies: [
        for (final c in job.copies) _Pair(c.key, File(c.value).absolute.path),
      ],
      trees: [
        for (final t in job.trees)
          _Pair(t.key, Directory(t.value).absolute.path),
      ],
    ),
    out: out,
  );
  if (exitCode != 0) exit(exitCode);
  if (!out.existsSync()) {
    stderr.writeln(
      'app_jit_snapshot: the training run of ${dartArgs.first} wrote no '
      'snapshot to ${out.path}',
    );
    exit(1);
  }
}

Never _usage(String problem) {
  stderr.writeln(
    'app_jit_snapshot: $problem\n'
    'usage: dart app_jit_snapshot.dart --dart=<dart> '
    '--snapshot=<out> [--dartvm=<dartvm>] [--enable-asserts] '
    '[--fallback-allowed] [--train-key=<key>] [--lock-timeout=<seconds>] '
    '[--env=K=V]... '
    '[--copy=D=S]... [--copy-tree=D=DIR]... -- <dart arguments>',
  );
  exit(64);
}

/// Whether [value] is a training key: 16 lowercase hex characters (see
/// [trainDirForKey]).
bool _isTrainKey(String value) {
  if (value.length != 16) return false;
  for (final c in value.codeUnits) {
    if ((c < 0x30 || c > 0x39) && (c < 0x61 || c > 0x66)) return false;
  }
  return true;
}

String? _adjacentDartvm(String dart, String exeExt) {
  final candidate = File('${File(dart).parent.path}/dartvm$exeExt');
  return candidate.existsSync() ? candidate.path : null;
}

/// Makes [target] an executable copy of [source], unless it is one already.
///
/// The copy is written under a name unique to this process, marked `0755`, then
/// renamed over [target]. A rename replaces the file in one step, so a reader
/// sees the old file or the new one, never a partial copy, and a process that
/// is running the old file keeps it.
void _installCopy(String source, String target) {
  final src = File(source);
  final dst = File(target);
  if (dst.existsSync() &&
      dst.lengthSync() == src.lengthSync() &&
      _sameBytes(src, dst)) {
    return;
  }
  final tmp = File('$target.$pid.${Random().nextInt(1 << 31)}.tmp');
  tmp.writeAsBytesSync(src.readAsBytesSync());
  chmodFile(tmp.path, 0x1ed);
  try {
    tmp.renameSync(target);
  } on FileSystemException {
    if (!dst.existsSync()) rethrow;
    try {
      tmp.deleteSync();
    } on FileSystemException {
      // Ignore cleanup errors.
    }
  }
}

bool _sameBytes(File a, File b) {
  final x = a.readAsBytesSync();
  final y = b.readAsBytesSync();
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

const _isolatedHomeEnvKeys = <String>{
  'HOME',
  'USERPROFILE',
  'LOCALAPPDATA',
  'APPDATA',
  'PUB_CACHE',
  'TEMP',
  'TMP',
  'TMPDIR',
  'XDG_CONFIG_HOME',
  'XDG_CACHE_HOME',
};

String? _lookupEnvCaseInsensitive(Map<String, String> env, String name) {
  final direct = env[name];
  if (direct != null && direct.isNotEmpty && !direct.contains('\x00')) {
    return direct;
  }
  final upper = name.toUpperCase();
  for (final entry in env.entries) {
    if (entry.key.toUpperCase() == upper &&
        entry.value.isNotEmpty &&
        !entry.value.contains('\x00')) {
      return entry.value;
    }
  }
  return null;
}

/// Builds a sanitized child-process environment isolated to [homeDir].
///
/// On Windows ([isWindows]), keeps the minimal system variables Windows needs
/// to start a process (`SystemRoot`, `WINDIR`, `SystemDrive`, `COMSPEC`,
/// `PATHEXT`, `PATH`, `NUMBER_OF_PROCESSORS`, `PROCESSOR_ARCHITECTURE`) from
/// [parentEnv] (falling back to `C:\Windows` for `SystemRoot` when absent),
/// and points the home, cache, and temporary directory variables
/// (`USERPROFILE`, `LOCALAPPDATA`, `APPDATA`, `HOME`, `PUB_CACHE`, `TEMP`,
/// `TMP`, `TMPDIR`) at [homeDir]. On other systems, inherits [parentEnv]
/// except the home and cache variables (pointed at [homeDir]) and `TMPDIR`
/// (pointed at [homeDir], so no child writes to the shared system temp
/// directory). Any entry with an empty name or `=` in the
/// name is omitted.
Map<String, String> buildChildEnvironment({
  required String homeDir,
  Map<String, String>? parentEnv,
  Map<String, String> overrides = const {},
  bool? isWindows,
  bool includeParent = true,
}) {
  final source = parentEnv ?? Platform.environment;
  final win = isWindows ?? Platform.isWindows;
  final env = _ChildEnvBuilder(win: win);
  if (win) {
    _applyWindowsChildEnv(env, source, homeDir, includeParent, overrides);
  } else {
    _applyPosixChildEnv(env, source, homeDir, includeParent, overrides);
  }
  return env.result;
}

/// A child-process environment under construction, with the case handling of
/// [buildChildEnvironment]: on Windows names compare case-insensitively, so
/// setting a name removes any existing spelling of it first.
final class _ChildEnvBuilder {
  _ChildEnvBuilder({required this.win});

  final bool win;
  final result = <String, String>{};

  bool isValidEntry(String key, String value) =>
      key.isNotEmpty &&
      !key.contains('=') &&
      !key.contains('\x00') &&
      !value.contains('\x00');

  void set(String key, String value) {
    if (!isValidEntry(key, value)) return;
    if (win) {
      final upper = key.toUpperCase();
      result.removeWhere(
        (existingKey, _) => existingKey.toUpperCase() == upper,
      );
    }
    result[key] = value;
  }
}

/// Applies the Windows branch of [buildChildEnvironment]: the minimal system
/// variables Windows needs to start a process, the home, cache, and temporary
/// directory variables pointed at [homeDir], then [overrides].
void _applyWindowsChildEnv(
  _ChildEnvBuilder env,
  Map<String, String> source,
  String homeDir,
  bool includeParent,
  Map<String, String> overrides,
) {
  final systemRoot =
      _lookupEnvCaseInsensitive(source, 'SystemRoot') ??
      _lookupEnvCaseInsensitive(source, 'WINDIR') ??
      r'C:\Windows';
  final systemDrive =
      _lookupEnvCaseInsensitive(source, 'SystemDrive') ??
      (systemRoot.length >= 2 && systemRoot[1] == ':'
          ? systemRoot.substring(0, 2)
          : 'C:');
  env.set('SystemRoot', systemRoot);
  env.set('WINDIR', _lookupEnvCaseInsensitive(source, 'WINDIR') ?? systemRoot);
  env.set('SystemDrive', systemDrive);
  env.set(
    'COMSPEC',
    _lookupEnvCaseInsensitive(source, 'COMSPEC') ??
        '$systemRoot\\System32\\cmd.exe',
  );
  env.set(
    'PATHEXT',
    _lookupEnvCaseInsensitive(source, 'PATHEXT') ?? '.COM;.EXE;.BAT;.CMD',
  );
  final parentPath = _lookupEnvCaseInsensitive(source, 'PATH');
  env.set(
    'PATH',
    (includeParent && parentPath != null)
        ? parentPath
        : '$systemRoot\\System32;$systemRoot',
  );
  for (final optionalKey in const [
    'NUMBER_OF_PROCESSORS',
    'PROCESSOR_ARCHITECTURE',
  ]) {
    final val = _lookupEnvCaseInsensitive(source, optionalKey);
    if (val != null) {
      env.set(optionalKey, val);
    }
  }
  for (final homeKey in const [
    'USERPROFILE',
    'LOCALAPPDATA',
    'APPDATA',
    'HOME',
    'PUB_CACHE',
    'TEMP',
    'TMP',
    'TMPDIR',
  ]) {
    env.set(homeKey, homeDir);
  }
  for (final entry in overrides.entries) {
    env.set(entry.key, entry.value);
  }
  if ((_lookupEnvCaseInsensitive(env.result, 'SystemRoot') ?? '').isEmpty) {
    env.set('SystemRoot', systemRoot);
  }
}

/// Applies the POSIX branch of [buildChildEnvironment]: [source] except the
/// home and cache variables (pointed at [homeDir]) and `TMPDIR` (pointed at
/// [homeDir], so no child writes to the shared system temp directory), then
/// [overrides].
void _applyPosixChildEnv(
  _ChildEnvBuilder env,
  Map<String, String> source,
  String homeDir,
  bool includeParent,
  Map<String, String> overrides,
) {
  if (includeParent) {
    for (final entry in source.entries) {
      if (_isolatedHomeEnvKeys.contains(entry.key.toUpperCase())) continue;
      env.set(entry.key, entry.value);
    }
    for (final homeKey in const [
      'HOME',
      'USERPROFILE',
      'LOCALAPPDATA',
      'APPDATA',
      'PUB_CACHE',
      // Pointed at the action-private directory, not inherited: a compile
      // must leave no file under the shared system temp directory, whatever
      // scratch `TMPDIR` names.
      'TMPDIR',
    ]) {
      env.set(homeKey, homeDir);
    }
  } else {
    env.set('HOME', homeDir);
    env.set('TMPDIR', homeDir);
  }
  for (final entry in overrides.entries) {
    env.set(entry.key, entry.value);
  }
}

/// A `KEY=VALUE` (or `DEST=SOURCE`) option value. Splits at the first `=`.
class _Pair {
  const _Pair(this.key, this.value);

  final String key;
  final String value;

  static _Pair parse(String text, String arg) {
    final eq = text.indexOf('=');
    if (eq < 0) _usage('expected KEY=VALUE in $arg');
    return _Pair(text.substring(0, eq), text.substring(eq + 1));
  }
}

/// The default seconds a training waits for its training lock before treating
/// the keyed path as unavailable (see [_openConstantLock]). Mirrors the
/// `//dart:jit_snapshot_lock_timeout` build setting's default: both snapshot
/// actions pass `--lock-timeout=` only when set differently, so the default
/// here and the setting's default must stay equal.
const defaultLockTimeoutSecs = 300;

/// The training key selecting the keyed training paths (see [trainDirForKey]):
/// 16 lowercase hex characters of a deterministic digest of the declared
/// output's root-relative path, passed by both snapshot actions on argv as
/// `--train-key=`. Null where the caller passed none (unit tests training at
/// injected paths): the legacy host-wide paths below apply.
///
/// Public so tests pin the keyed routing without touching the real paths.
String? trainKeyOverride;

/// Seconds a training waits for the training lock (see [_openConstantLock]),
/// from `--lock-timeout=`, or [defaultLockTimeoutSecs] where none was passed.
///
/// Public so tests bound the wait without touching the real paths.
int lockTimeoutSecs = defaultLockTimeoutSecs;

/// The keyed training directory for [key]: one absolute path per declared
/// output, so two different targets train in parallel and only concurrent
/// trainings of one output contend for the lock. The key depends only on the
/// output's root-relative path, so it is identical across output bases,
/// strategies and machines.
///
/// Public so tests pin the routing both snapshot actions rely on.
String trainDirForKey(String key) => '/tmp/rules_dart_jit-$key';

/// The lock serializing trainings at [trainDirForKey] for [key] (see
/// [_openConstantLock]).
///
/// Public so tests pin the routing both snapshot actions rely on.
String trainLockForKey(String key) => '/tmp/rules_dart_jit-$key.lock';

/// The legacy host-wide training path, used only where no `--train-key=` was
/// passed. Every production training passes a key; the legacy path stays so
/// keyless runs (older actions, direct tool runs) keep training somewhere the
/// bytes never name the build.
const _defaultTrainDir = '/tmp/rules_dart_jit';

/// The legacy host-wide lock, used only where no `--train-key=` was passed
/// (see [_defaultTrainDir]).
const _defaultTrainLock = '/tmp/rules_dart_jit.lock';

/// Overrides for the constant training paths, for tests.
///
/// Unit tests set these to directories under `TEST_TMPDIR`: other builds on
/// the host train at the real paths concurrently, and a planted test entry
/// would change their bytes. A subprocess run of this tool (see `stageTool`
/// in the test) inherits the same overrides through
/// `RULES_DART_JIT_TRAIN_DIR` and `RULES_DART_JIT_TRAIN_LOCK` instead, since
/// it cannot see these variables. Production code never sets either; the
/// variables exist so tests never touch the real paths.
String? trainDirOverride;
String? trainLockOverride;

/// The one absolute path every POSIX training runs in (see [trainDirForKey]
/// for why), or the test override where one is set.
String get constantTrainDir =>
    trainDirOverride ??
    Platform.environment['RULES_DART_JIT_TRAIN_DIR'] ??
    (trainKeyOverride != null
        ? trainDirForKey(trainKeyOverride!)
        : _defaultTrainDir);

/// The lock serializing trainings at [constantTrainDir], or the test override
/// where one is set.
String get constantTrainLock =>
    trainLockOverride ??
    Platform.environment['RULES_DART_JIT_TRAIN_LOCK'] ??
    (trainKeyOverride != null
        ? trainLockForKey(trainKeyOverride!)
        : _defaultTrainLock);

bool _fallbackWarned = false;

/// Prints the one fallback notice: without the constant training directory
/// the snapshot may name this build's paths.
void _warnFallback() {
  if (_fallbackWarned) return;
  _fallbackWarned = true;
  stderr.writeln(
    'app_jit_snapshot: cannot train in $constantTrainDir on this host; '
    'the snapshot may not be reproducible',
  );
}

/// Why the last [_acquireConstantDir] call found the constant directory
/// unavailable: a sentence naming the blocker for the fail-closed error.
/// Only meaningful after a null return.
String _constantDirUnavailable = '';

/// Whether [_constantDirUnavailable] names the lock file rather than the
/// training directory: a lock owned by another user cannot be removed by us,
/// so the error names the lock's own remedies. Reset on every
/// [_acquireConstantDir] call, like [_constantDirUnavailable] itself.
bool _constantLockUnavailable = false;

/// Whether the training-directory entry the last [_acquireConstantDir] call
/// failed on is ours: only then can we remove it ourselves, so only then does
/// the error say "Remove the entry". Another user's entry wants its owner (or
/// root) to remove it, as with a foreign lock. False where the entry cannot
/// be statted: not known to be ours. Only meaningful after a null return
/// without a lock failure; reset on every call.
bool _constantDirOwnEntry = false;

/// Whether the last [_openConstantLock] call ran past its deadline: the lock
/// was contended for the whole wait. Only meaningful after a null return;
/// reset on every call, like [_constantDirUnavailable] itself.
bool _lockWaitTimedOut = false;

/// The holder's PID at the last deadline, for the fail-closed error. Null
/// where it could not be read; the error then says "unknown".
int? _lockHolderPidAtDeadline;

/// The deadline seconds the last [_openConstantLock] call waited, for the
/// fail-closed error.
int _lockDeadlineSecs = defaultLockTimeoutSecs;

/// The entry the last [_openConstantLock] call failed on, for the fail-closed
/// error: its type and owner (see [jitDescribeEntry]). Only meaningful after
/// a null return without a deadline.
String _lockDetail = '';

/// Whether the last [_openConstantLock] failure wants the `chmod 0666`
/// remedy: the lock's own mode is what denies us access. Anything else wants
/// the entry removed (see [_writeUnavailableError]).
bool _lockChmodRemedy = false;

/// Whether the entry the last [_openConstantLock] call failed on is ours:
/// the mode-denied remedy names us rather than "its owner".
bool _lockOwnEntry = false;

/// How many times [_openConstantLock] opens the lock per call: the first open
/// plus reopenings when the held lock no longer names the lock path (see
/// [jitFdMatchesPath]). A mismatch is all but impossible (only a concurrent
/// delete-and-recreate of the lock path causes one); giving up still fails
/// closed.
const _lockOpenAttempts = 3;

/// Opens the lock serializing trainings at [constantTrainDir] and takes it
/// exclusively, returning the held lock's file descriptor.
///
/// The lock opens by descriptor (see [jitOpenLock]), never by a path-based
/// check-then-use: an existing lock opens read-write with O_NOFOLLOW and
/// without O_CREAT, so a second user on a host with `fs.protected_regular`
/// opens the first user's 0666 lock; a missing lock is published at 0666
/// through a uniquely named temporary linked over the lock path, whatever the
/// umask or the scheduling. Only a regular
/// file with link count 1 is kept (never written and never chmodded: a
/// pre-existing lock keeps its content and its mode). Null when the
/// lock cannot be opened or is not a regular file; the failure detail and its
/// remedy stay in [_lockDetail], [_lockChmodRemedy] and [_lockOwnEntry] for
/// the fail-closed error (see [_acquireConstantDir]).
///
/// A taken lock is re-checked against its path before it is trusted (see
/// [jitFdMatchesPath]): the lock may have been deleted or replaced while it
/// was taken (a /tmp cleaner, another publisher), and a descriptor that no
/// longer names the entry at the path serializes nothing. On a mismatch the
/// descriptor is dropped and the lock reopened, up to [_lockOpenAttempts]
/// opens; giving up fails closed with the entry the path names then.
///
/// A contended lock never blocks forever: the exclusive take is a
/// non-blocking `fcntl` try-lock (see [jitTryExclusiveLock]), polled with
/// sleeps backing off from 50 ms to 1 s until [lockTimeoutSecs] seconds pass.
/// After 10 s of waiting, and then every 60 s, one notice names the lock path
/// and the holder's PID (see [jitLockHolderPid]), or "unknown" where it cannot
/// be read. At the deadline the path counts as unavailable: null is returned
/// with [_lockWaitTimedOut] set, and the caller fails the action (or falls
/// back where allowed), naming the lock, the holder and the deadline.
int? _openConstantLock() {
  _lockWaitTimedOut = false;
  _lockHolderPidAtDeadline = null;
  _lockDeadlineSecs = lockTimeoutSecs;
  _lockDetail = '';
  _lockChmodRemedy = false;
  _lockOwnEntry = false;
  for (var attempt = 0; attempt < _lockOpenAttempts; attempt++) {
    final opened = jitOpenLock(constantTrainLock);
    if (opened.fd < 0) {
      _lockDetail = opened.detail;
      _lockChmodRemedy = opened.chmodRemedy;
      _lockOwnEntry = opened.ownEntry;
      return null;
    }
    final fd = opened.fd;
    if (!_waitExclusive(fd)) {
      _lockWaitTimedOut = true;
      _lockHolderPidAtDeadline = jitLockHolderPid(constantTrainLock);
      jitUnlockAndClose(fd);
      return null;
    }
    // The lock may have been deleted or replaced while it was taken: a
    // descriptor that no longer names the entry at the path serializes
    // nothing, and the directory claimed under it could be another training's
    // live one. Drop it and reopen on a mismatch.
    if (jitFdMatchesPath(fd, constantTrainLock)) return fd;
    jitUnlockAndClose(fd);
  }
  _lockDetail = jitDescribeEntry(constantTrainLock);
  _lockChmodRemedy = false;
  _lockOwnEntry = false;
  return null;
}

/// Takes the exclusive lock on [fd] (see [_openConstantLock]): a non-blocking
/// `fcntl` try-lock polled with sleeps backing off from 50 ms to 1 s until
/// [lockTimeoutSecs] seconds pass. After 10 s of waiting, and then every 60 s,
/// one notice names the lock path and the holder's PID (or "unknown" where it
/// cannot be read). True when [fd] now holds the lock.
bool _waitExclusive(int fd) {
  if (jitTryExclusiveLock(fd)) return true;
  final stopwatch = Stopwatch()..start();
  final deadline = Duration(seconds: lockTimeoutSecs);
  var sleepMs = 50;
  var nextNotice = const Duration(seconds: 10);
  for (;;) {
    final remaining = deadline - stopwatch.elapsed;
    if (remaining <= Duration.zero) return false;
    sleep(
      remaining < Duration(milliseconds: sleepMs)
          ? remaining
          : Duration(milliseconds: sleepMs),
    );
    if (jitTryExclusiveLock(fd)) return true;
    sleepMs = sleepMs >= 500 ? 1000 : sleepMs * 2;
    if (stopwatch.elapsed >= nextNotice) {
      final holder = jitLockHolderPid(constantTrainLock);
      stderr.writeln(
        'app_jit_snapshot: waiting for $constantTrainLock'
        '${holder == null ? ' held by process unknown' : ' held by process $holder'}...',
      );
      nextNotice += const Duration(seconds: 60);
    }
  }
}

/// Deletes any stale entry at [path] without reading its content or following
/// a link, returning true when [path] is now absent.
///
/// A symlink is unlinked as a link, so its target is untouched; a directory
/// is removed recursively without following links (see [_deleteTreeNoFollow]);
/// anything else (a regular file, a FIFO, a socket) is unlinked, which never
/// blocks. False means the entry is not ours to remove (another user's entry
/// under `/tmp`'s sticky bit): the caller fails the action instead of
/// training elsewhere under the same action key.
bool _unlinkStaleEntry(String path) {
  FileSystemEntityType type;
  try {
    type = FileSystemEntity.typeSync(path, followLinks: false);
  } on FileSystemException {
    // An entry Dart cannot classify: unlink blindly, which never follows a
    // link, and report whether the path is now absent.
    try {
      File(path).deleteSync();
    } on FileSystemException {
      return false;
    }
    return _entryAbsent(path);
  }
  try {
    if (type == FileSystemEntityType.notFound) return true;
    if (type == FileSystemEntityType.directory) {
      _deleteTreeNoFollow(path);
    } else if (type == FileSystemEntityType.link) {
      Link(path).deleteSync();
    } else {
      File(path).deleteSync();
    }
  } on FileSystemException {
    return false;
  }
  return _entryAbsent(path);
}

/// Whether [path] currently names no entry.
bool _entryAbsent(String path) {
  try {
    return FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound;
  } on FileSystemException {
    return false;
  }
}

/// Removes any stale entry at the constant training path (see
/// [_unlinkStaleEntry]).
///
/// A variable so tests can make the entry unremovable and pin the fail-closed
/// error; production code never reassigns it.
bool Function(String path) removeStaleEntry = _unlinkStaleEntry;

/// Our uid, for telling our own training-directory entries (which the tool
/// removes itself) from another user's (whose owner or root must remove
/// them, since we cannot under `/tmp`'s sticky bit). A variable so tests can
/// stand in for another user; production code never reassigns it.
int Function() ownUid = jitOwnUid;

/// Removes the directory at [path] without following symlinks: links inside
/// are unlinked as links, subdirectories are removed the same way, and only
/// then is the directory itself removed. A link swapped in for a directory
/// mid-removal fails the final remove, so the caller fails closed rather than
/// training in a directory it does not own.
///
/// A crashed training can leave a read-only tree (Bazel inputs and outputs
/// are read-only and copies keep modes): a real directory owned by us gets
/// owner access back before it is listed, so our own stale trees clear.
/// Only such a directory is chmodded, never a link and never through one,
/// and never what another user owns: anything else is deleted as found, and
/// the OS refuses what is not ours to remove.
void _deleteTreeNoFollow(String path) {
  if (!FileSystemEntity.isLinkSync(path)) {
    final info = jitStatEntry(path);
    if (info != null && info.kind == 'directory' && info.uid == jitOwnUid()) {
      chmodFile(path, 0x1c0);
    }
  }
  for (final entity in Directory(
    path,
  ).listSync(recursive: false, followLinks: false)) {
    if (entity is Link) {
      entity.deleteSync();
    } else if (entity is Directory) {
      _deleteTreeNoFollow(entity.path);
    } else {
      File(entity.path).deleteSync();
    }
  }
  Directory(path).deleteSync();
}

/// Takes the exclusive training lock and claims [constantTrainDir] as an
/// empty directory with mode 0700, returning it with the held lock.
///
/// Any stale entry at the training path is removed first, whatever its type
/// (see [removeStaleEntry]): only our own entries can be removed under
/// `/tmp`'s sticky bit, and nothing that was there is ever read or followed.
/// The cleared path is then claimed with [mkdirExclusive], which succeeds
/// only when this call creates the directory: another local user winning the
/// delete-to-create race reads as `EEXIST` and fails the action (see
/// [_trainInScratch]), so the training VM copy never lands in a directory
/// they own, where a swapped binary would run as us. A link swapped in after
/// the claim is removed as a link only, never followed. Returns null on
/// Windows and on any failure, recording the blocker in
/// [_constantDirUnavailable] for the fail-closed error; the caller deletes
/// the directory before releasing the lock, also on failure.
({Directory dir, int lock})? _acquireConstantDir() {
  if (Platform.isWindows) return null;
  _constantLockUnavailable = false;
  _constantDirOwnEntry = false;
  final int? lock = _openConstantLock();
  if (lock == null) {
    if (_lockWaitTimedOut) {
      final holder = _lockHolderPidAtDeadline == null
          ? 'process unknown'
          : 'process ${_lockHolderPidAtDeadline}';
      _constantDirUnavailable =
          'the lock file $constantTrainLock is still held by $holder '
          'after waiting $_lockDeadlineSecs seconds';
    } else {
      _constantDirUnavailable =
          'the lock file $_lockDetail cannot be opened for writing';
    }
    _constantLockUnavailable = true;
    return null;
  }
  ({Directory dir, int lock})? fail(String reason) {
    _constantDirUnavailable = reason;
    // Only our own entry is ours to remove (see [_constantDirOwnEntry]):
    // another user's leftover under `/tmp`'s sticky bit is not.
    final info = jitStatEntry(constantTrainDir);
    _constantDirOwnEntry = info != null && info.uid == ownUid();
    jitUnlockAndClose(lock);
    return null;
  }

  try {
    if (!removeStaleEntry(constantTrainDir)) {
      return fail(
        'the ${jitDescribeEntry(constantTrainDir)} cannot be removed',
      );
    }
    // Claim the cleared path atomically: [mkdirExclusive] succeeds only when
    // this call creates the directory, so another local user winning the
    // delete-to-create race (or any other error) fails instead of training in
    // a directory they own. `Directory.createSync` cannot claim: it silently
    // succeeds when the path already exists, and a later chmod cannot prove
    // ownership.
    // 0700: only our uid trains here.
    if (mkdirExclusive(constantTrainDir, 0x1c0) != 0) {
      return fail(
        'the ${jitDescribeEntry(constantTrainDir)} cannot be claimed',
      );
    }
    if (FileSystemEntity.isLinkSync(constantTrainDir)) {
      // Swapped under us after the claim: remove only the link itself.
      try {
        Link(constantTrainDir).deleteSync();
      } on FileSystemException {
        // Ignore cleanup errors.
      }
      return fail(
        'the ${jitDescribeEntry(constantTrainDir)} cannot be claimed',
      );
    }
  } on FileSystemException {
    return fail('the ${jitDescribeEntry(constantTrainDir)} cannot be claimed');
  }
  return (dir: Directory(constantTrainDir), lock: lock);
}

/// Writes the fail-closed error for a null [_acquireConstantDir]: the
/// blocker in [_constantDirUnavailable] and its remedies. A lock that stayed
/// held past its deadline names stopping the holder and waiting longer. Any
/// other blocked lock names the lock's own remedies: where the lock's own
/// mode is what denies us access the owner makes it world-writable or removes
/// it, and where anything else blocks it — a symlink, directory, FIFO or
/// other entry — its owner (or root) must remove it, since we cannot remove
/// another user's lock. A blocked training directory of our own names removing
/// the entry; another user's names its owner (or root) removing it, since we
/// cannot under `/tmp`'s sticky bit.
void _writeUnavailableError() {
  final String remedy;
  if (_lockWaitTimedOut) {
    final holder = _lockHolderPidAtDeadline == null
        ? 'process unknown'
        : 'process ${_lockHolderPidAtDeadline}';
    remedy =
        'Stop the holder ($holder), raise `--@rules_dart//dart:jit_snapshot_lock_timeout` '
        'above $_lockDeadlineSecs, or pass ';
  } else if (_constantLockUnavailable) {
    // The `chmod 0666` remedy only where the lock's own mode denies us (see
    // [_lockChmodRemedy]); anything else wants the entry removed.
    remedy = _lockChmodRemedy
        ? (_lockOwnEntry
              ? 'Run `chmod 0666 $constantTrainLock` or remove it, or pass '
              : 'Have its owner run `chmod 0666 $constantTrainLock` or remove it, or pass ')
        : 'Have its owner (or root) remove it, or pass ';
  } else {
    remedy = _constantDirOwnEntry
        ? 'Remove the entry, or pass '
        : 'Have its owner (or root) remove it, or pass ';
  }
  stderr.writeln(
    'app_jit_snapshot: cannot train in $constantTrainDir on this host: '
    '$_constantDirUnavailable. $remedy'
    '`--@rules_dart//dart:jit_snapshot_fallback=true`, which allows the '
    'private-scratch fallback whose bytes are not reproducible, or, for '
    'tests, `--@rules_dart//dart:test_runner_snapshot=false` to run the '
    "runner's kernel instead of its snapshot",
  );
}

/// Trains the snapshot and copies it to [out], at the constant training path
/// where one can be claimed. Returns the training run's exit code.
///
/// Every build of one target trains at one constant absolute path (see
/// [constantTrainDir]), so the bytes never name the build's output root or
/// sandbox. The exclusive lock serializes concurrent trainings on one host.
/// On Windows the training uses a private directory per run under the
/// declared output's directory, as documented. On POSIX, when the constant
/// directory is unavailable the action fails by default: the failure names
/// the blocker and its remedies (see [_acquireConstantDir]). Only with
/// [fallbackAllowed] (from `--fallback-allowed`, set by
/// `--@rules_dart//dart:jit_snapshot_fallback=true`) does the training fall
/// back to a private directory per run under the declared output's directory
/// (with the notice from [_warnFallback]), whose bytes are not reproducible.
/// Either way no compile reads or writes the shared system temp directory,
/// and concurrent actions (each with its own output) cannot collide. The
/// training runs with the training directory as its working directory (see
/// below), so the runner's relative test path resolves into the staged tree;
/// no padding is needed (an empty pad component once trained a stray `//`
/// into snapshots).
/// `exit` is not called in here: it would skip the cleanup. Any exception the
/// constant-dir training throws falls back to the private scratch where
/// allowed (see [_trainInFallback]); otherwise the run fails closed: the
/// training directory is still deleted, the lock still released, and the tool
/// reports the cause and returns 1 rather than a raw stack trace (see
/// [_failTraining]).
int _trainInScratch({required _TrainingJob job, required File out}) {
  out.parent.createSync(recursive: true);
  final ({Directory dir, int lock})? constant;
  try {
    constant = Platform.isWindows ? null : _acquireConstantDir();
  } catch (error) {
    // The claim itself threw, so nothing was claimed and no lock is held:
    // fail closed with the cause instead of a raw stack trace.
    return _failTraining(constantTrainDir, error);
  }
  if (constant != null) {
    try {
      return _runTraining(trainDir: constant.dir, job: job, out: out);
    } catch (error) {
      // The constant-dir training itself threw (a ProcessException when the
      // copied training VM cannot run, say): where the fallback is allowed,
      // warn and retry in the private scratch instead of failing closed.
      if (job.fallbackAllowed) {
        _warnFallback();
        return _trainInFallback(job: job, out: out);
      }
      return _failTraining(constantTrainDir, error);
    } finally {
      _discardConstant(constant);
    }
  }
  if (!Platform.isWindows && !job.fallbackAllowed) {
    _writeUnavailableError();
    return 1;
  }
  _warnFallback();
  return _trainInFallback(job: job, out: out);
}

/// Deletes the constant training directory this training claimed and releases
/// its lock (see [_trainInScratch]): the directory holds only what this
/// training put there, but it is shared by path, so it is deleted only when it
/// is still a real directory, never when it became a link, and before the lock
/// is released, also on failure. Cleanup errors are ignored.
void _discardConstant(({Directory dir, int lock}) constant) {
  // The constant directory holds only what this training put there, but it
  // is shared by path: delete it only when it is still a real directory,
  // never when it became a link, and before releasing the lock, also on
  // failure (see [_acquireConstantDir]).
  try {
    if (!FileSystemEntity.isLinkSync(constantTrainDir) &&
        constant.dir.existsSync()) {
      constant.dir.deleteSync(recursive: true);
    }
  } on FileSystemException {
    // Ignore cleanup errors.
  }
  jitUnlockAndClose(constant.lock);
}

/// Trains in a private directory per run under the declared output's directory
/// (see [_trainInScratch]): the caller warns first (see [_warnFallback]), and
/// the bytes are not reproducible. Any exception the training throws fails
/// closed with the cause while the scratch below is deleted. Returns the
/// training run's exit code.
int _trainInFallback({required _TrainingJob job, required File out}) {
  final scratch = out.parent.createTempSync('rules_dart_snapshot.');
  final trainDir = Directory('${scratch.path}/t')..createSync();
  try {
    return _runTraining(trainDir: trainDir, job: job, out: out);
  } catch (error) {
    // As above: fail closed with the cause while the scratch below is deleted.
    return _failTraining(scratch.path, error);
  } finally {
    if (scratch.existsSync()) {
      try {
        scratch.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
  }
}

/// Fails a training run with the fail-closed error: the message names
/// the training directory and the cause, and the caller exits non-zero, so a
/// raw stack trace is never the only output. Returns 1 for the caller to
/// return.
int _failTraining(String where, Object error) {
  stderr.writeln('app_jit_snapshot: training in $where failed: $error');
  return 1;
}

/// Stages the training inputs under [trainDir], runs the training there, and
/// copies the snapshot it writes to [out]. Returns the training run's exit
/// code.
///
/// [dart] and [dartvm] name the SDK binaries to train with; both are copied
/// into the training directory (see below), so no shared fixed path is read
/// or executed.
int _runTraining({
  required Directory trainDir,
  required _TrainingJob job,
  required File out,
}) {
  // [_trainFromArgs] exits unless `dart` is present, so the assertion below
  // never fires; the field stays nullable because parsing precedes validation.
  final dart = job.dart!;
  final dartArgs = job.dartArgs;
  // The training VM is a copy inside the training directory, and the copy
  // is deleted with it, leaving no undeclared output beside the snapshot.
  // At the constant path the copy reads the same on every build; in the
  // fallback the directory is private to the action's outputs, so no other
  // user can plant or replace the binary between the copy and the run.
  final exeExt = dart.endsWith('.exe') ? '.exe' : '';
  final bin = Directory('${trainDir.path}/vm/bin')..createSync(recursive: true);
  _installCopy(dart, '${bin.path}/dart$exeExt');
  final effectiveDartvm = job.dartvm ?? _adjacentDartvm(dart, exeExt);
  if (effectiveDartvm != null) {
    final vmExt = effectiveDartvm.endsWith('.exe') ? '.exe' : '';
    _installCopy(effectiveDartvm, '${bin.path}/dartvm$vmExt');
  }
  final trainingDart = '${bin.path}/dart$exeExt';
  // Every input is staged under the training directory. The script and the
  // staged trees are named absolutely (see [stageTrainingArgs]): the run
  // resolves them at startup into `Uri`s whose interned strings would
  // otherwise name the build's paths (see the header comment). A program
  // argument that merely equals a staged file stays relative: the runner
  // joins its test path onto the absolute `--precompiled` directory itself.
  for (final c in job.copies) {
    _copyFile(c.value, '${trainDir.path}/${c.key}');
  }
  for (final t in job.trees) {
    _copyTree(t.value, '${trainDir.path}/${t.key}');
  }
  // No `--packages` value is passed, and no package config is staged. The
  // value would resolve against the working directory and intern
  // build-specific strings (see the header comment). The training input is
  // a kernel file whose library URIs are already resolved, so loading
  // needs no package map; a runtime `package:` import would resolve by
  // walking up from the training directory, where no package config lives.
  final stagedEnv = absoluteHomeEnv(job.env, trainDir);
  final childEnv = buildChildEnvironment(
    homeDir: trainDir.path,
    parentEnv: Platform.environment,
    overrides: stagedEnv,
    isWindows: Platform.isWindows,
    includeParent: false,
  );

  // The training run keeps the VM flags that make the snapshot repeat, and
  // none that name a host path. Its working directory is the private
  // training directory: the runner only runs a test path naming a file
  // under the working directory, and joins that path onto the absolute
  // `--precompiled` directory itself, so the working directory must hold
  // the staged test source. Every path the run resolves is absolute (see
  // [stageTrainingArgs]) except the runner's test path, which is constant
  // across builds by construction; the directory's own value perturbs
  // cluster-walk order only through the residual hash luck the header
  // comment describes.
  //
  // The runner keeps its default reporter and timeout, and no file reporter
  // is passed. With the file reporter, and with the explicit reporter and
  // timeout, the same inputs gave different snapshots from one run to the
  // next; with none of them, ten runs gave one snapshot. Nothing here reads a
  // report, and the test's exit code is all the training needs.
  final result = Process.runSync(
    trainingDart,
    [
      '--deterministic',
      // Optimizing compilation stays on the training thread, so the functions
      // the snapshot holds optimized do not depend on when a background
      // compile happens to finish. (The stability measured for this tool was
      // with the flag in place; its own contribution was not measured
      // separately.)
      '--no-background-compilation',
      // Code for the VM's baseline CPU rather than the build machine's. The
      // intent is cross-CPU identity, so a cache can share the snapshot.
      '--target_unknown_cpu',
      if (job.enableAsserts) '--enable-asserts',
      '--snapshot-kind=app-jit',
      '--snapshot=${trainDir.path}/snapshot.jit',
      ...stageTrainingArgs(
        dartArgs,
        trainDir,
        stagedFiles: {for (final c in job.copies) c.key},
        stagedTrees: [for (final t in job.trees) t.key],
      ),
    ],
    workingDirectory: trainDir.path,
    environment: childEnv,
    includeParentEnvironment: false,
  );

  // Bazel echoes any action output, so a clean run stays silent.
  if (result.exitCode != 0) {
    stdout.write(result.stdout as String);
    stderr.write(result.stderr as String);
    return result.exitCode;
  }
  final written = File('${trainDir.path}/snapshot.jit');
  if (written.existsSync()) {
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(written.readAsBytesSync());
  }
  return 0;
}

/// Home-directory-like variable names whose values name a directory.
/// Mirrors the home keys [buildChildEnvironment] isolates.
const _scratchEnvKeys = {
  'HOME',
  'USERPROFILE',
  'LOCALAPPDATA',
  'APPDATA',
  'PUB_CACHE',
  'TMPDIR',
  'TEMP',
  'TMP',
};

/// Copies [env], resolving the relative values of scratch-directory variables
/// (see [_scratchEnvKeys]) against [trainDir]. The callers pass those as `.`,
/// naming the training directory without depending on the working directory
/// to resolve them. Every other entry passes through untouched: only the
/// tool's own home variables are known to name the scratch directory (a
/// `DART_TEST_CONFIG=none/DartTest.yaml`, for example, must keep resolving
/// the way its caller staged it).
///
/// Public so tests pin the rewriting both branches rely on.
Map<String, String> absoluteHomeEnv(
  Map<String, String> env,
  Directory trainDir,
) {
  final staged = <String, String>{};
  for (final entry in env.entries) {
    if (_scratchEnvKeys.contains(entry.key.toUpperCase()) &&
        entry.value.isNotEmpty &&
        !File(entry.value).isAbsolute) {
      staged[entry.key] = '${trainDir.path}/${entry.value}';
    } else {
      staged[entry.key] = entry.value;
    }
  }
  return staged;
}

/// Rewrites the staged paths among [dartArgs] to absolute paths under
/// [trainDir]: the training run resolves the script and any tree-rooted path
/// at startup, and relative values would intern the working directory's own
/// layout-derived strings (see the header comment).
///
/// The first argument is the script `dart` runs, so it is rewritten when it
/// names a staged file or a file at or under a staged tree. A later argument
/// is rewritten only when it is (or, past the first `=`, holds) a path at or
/// under a root in [stagedTrees]; a later argument that merely equals a file
/// in [stagedFiles] passes through untouched. The runner training relies on
/// that: its test path names a staged source file, but the runner joins the
/// path it is given onto the (rewritten, absolute) `--precompiled` directory
/// itself (`p.join` keeps a relative second half and mangles an absolute one
/// into a nonexistent path), so the test path must stay relative. Anything
/// else (flags, test names, URIs) passes through untouched.
///
/// Public so tests pin the rewriting both branches rely on.
List<String> stageTrainingArgs(
  List<String> dartArgs,
  Directory trainDir, {
  required Set<String> stagedFiles,
  required List<String> stagedTrees,
}) {
  String slashes(String path) => path.replaceAll(r'\', '/');
  final files = {for (final f in stagedFiles) slashes(f)};
  final roots = [for (final t in stagedTrees) slashes(t)];

  bool underTree(String candidate) {
    for (final root in roots) {
      if (candidate == root || candidate.startsWith('$root/')) return true;
    }
    return false;
  }

  String stage(String arg, {required bool isScript}) {
    final eq = arg.indexOf('=');
    final value = eq < 0 ? arg : arg.substring(eq + 1);
    if (value.isEmpty || value.contains(':') || File(value).isAbsolute) {
      // A URI (`package:`, `dart:`, `file://`), a Windows absolute path
      // (`C:\...`, whose colon would otherwise read as relative), or any
      // absolute path: never a staged relative path.
      return arg;
    }
    final candidate = slashes(value);
    final staged = isScript
        ? files.contains(candidate) || underTree(candidate)
        : underTree(candidate);
    if (!staged) return arg;
    final stagedValue = '${trainDir.path}/$value';
    return eq < 0 ? stagedValue : '${arg.substring(0, eq)}=$stagedValue';
  }

  return [
    for (var n = 0; n < dartArgs.length; n++)
      stage(dartArgs[n], isScript: n == 0),
  ];
}

/// Copies every file under [from] to the same relative place under [to].
void _copyTree(String from, String to) {
  final source = Directory(from);
  final entities = source.listSync(recursive: true)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in entities) {
    if (entity is File) {
      final relative = entity.path.substring(source.path.length + 1);
      _copyFile(entity.path, '$to/$relative');
    }
  }
}

/// Copies [from] to [to] by content, creating the parent directories of [to].
///
/// Writes bytes rather than `File.copySync` so read-only input modes from a
/// sandbox or remote executor are not carried onto the scratch copy.
void _copyFile(String from, String to) {
  final dest = File(to);
  dest.parent.createSync(recursive: true);
  dest.writeAsBytesSync(File(from).readAsBytesSync());
}

// Compiles a pre-built kernel `.dill` to an AOT snapshot (`--mode=aot-snapshot`)
// or self-contained AOT executable (`--mode=exe`) without invoking `dartdev`.
//
// `dart compile exe` runs through `dartdev`, which walks ancestor directories
// up to `/` probing `pubspec.yaml` and `.dart_tool/package_config.json` (for
// native-asset hook discovery) and spawns `/usr/bin/chmod` via `PATH`. Driving
// `gen_snapshot --deterministic` directly and writing a fresh executable from
// `dartaotruntime` plus the ELF snapshot (marking it `0755` via libc `chmod`)
// keeps the compile strictly hermetic inside the action sandbox, even when
// inputs are staged read-only and no shell or coreutils exist.
//
// The `--aot` branch ([_runAot] below) parses with [_parseAotArgs], delegates
// non-ELF targets to `dart compile`, and otherwise drives `gen_snapshot`
// directly.
/// The parsed `--aot` arguments (see [_parseAotArgs]).
final class _AotArgs {
  String? dart;
  String? mode;
  String? recordedUses;
  String? outputPath;
  String? dillPath;
  String? customGenSnapshot;
  String? customDartaotruntime;
  String? targetOs;
  String? targetArch;
  var enableAsserts = false;
  final extraGenSnapshotOptions = <String>[];
}

/// One direct AOT compile: the parsed arguments plus the paths [_runAot]
/// derives from them, threaded through the compile steps below instead of a
/// long parameter list. The nullable targetOs is a genuinely optional
/// derivation; every other field is present by construction.
typedef _AotPlan = ({
  _AotArgs args,
  String dart,
  String mode,
  String outputPath,
  String dillPath,
  String sdkBin,
  String hostDartaotruntime,
  String targetDartaotruntime,
  String genSnapshot,
  String? targetOs,
});

/// Parses the `--aot` arguments.
_AotArgs _parseAotArgs(List<String> argv) {
  final args = _AotArgs();
  for (var i = 0; i < argv.length; i++) {
    i = _applyAotArg(args, argv, i);
  }
  return args;
}

/// Applies the argument at [i], returning the index of the last argument it
/// consumed (the same index, or one further when it takes a separate value).
int _applyAotArg(_AotArgs args, List<String> argv, int i) {
  final arg = argv[i];
  final toolchainIndex = _applyAotToolchainOption(args, argv, i);
  if (toolchainIndex != null) return toolchainIndex;
  if (arg == '--enable-asserts') {
    args.enableAsserts = true;
    return i;
  }
  if (arg == '--verbosity=error') {
    // Ignored: gen_snapshot is silent on success.
    return i;
  }
  if (arg.startsWith('--extra-gen-snapshot-options=')) {
    final opts = arg.substring('--extra-gen-snapshot-options='.length);
    for (final opt in opts.split(',')) {
      if (opt.isNotEmpty) args.extraGenSnapshotOptions.add(opt);
    }
    return i;
  }
  if (arg == '-o') {
    args.outputPath = argv[++i];
    return i;
  }
  if (arg.startsWith('-o=')) {
    args.outputPath = arg.substring('-o='.length);
    return i;
  }
  if (!arg.startsWith('-')) {
    args.dillPath = arg;
    return i;
  }
  stderr.writeln('app_jit_snapshot --aot: unknown argument $arg');
  exit(64);
}

/// Applies a toolchain or target option at [i], returning the index of the
/// last argument it consumed, or null when [arg] is no such option.
int? _applyAotToolchainOption(_AotArgs args, List<String> argv, int i) {
  final arg = argv[i];
  if (arg.startsWith('--dart=')) {
    args.dart = arg.substring('--dart='.length);
    return i;
  }
  if (arg.startsWith('--mode=')) {
    args.mode = arg.substring('--mode='.length);
    return i;
  }
  if (arg.startsWith('--recorded-uses=')) {
    args.recordedUses = arg.substring('--recorded-uses='.length);
    return i;
  }
  if (arg.startsWith('--gen-snapshot=')) {
    args.customGenSnapshot = arg.substring('--gen-snapshot='.length);
    return i;
  }
  if (arg == '--gen-snapshot') {
    args.customGenSnapshot = argv[++i];
    return i;
  }
  if (arg.startsWith('--dartaotruntime=')) {
    args.customDartaotruntime = arg.substring('--dartaotruntime='.length);
    return i;
  }
  if (arg == '--dartaotruntime') {
    args.customDartaotruntime = argv[++i];
    return i;
  }
  if (arg.startsWith('--target-os=')) {
    args.targetOs = arg.substring('--target-os='.length);
    return i;
  }
  if (arg == '--target-os') {
    args.targetOs = argv[++i];
    return i;
  }
  if (arg.startsWith('--target-arch=')) {
    args.targetArch = arg.substring('--target-arch='.length);
    return i;
  }
  if (arg == '--target-arch') {
    args.targetArch = argv[++i];
    return i;
  }
  return null;
}

/// Exits unless a cross-compilation has the toolchain it needs: a custom
/// `gen_snapshot`, and a custom `dartaotruntime` for executables.
void _checkAotCrossRequirements(_AotArgs args, String mode, bool isCross) {
  if (!isCross) return;
  if (args.customGenSnapshot == null || args.customGenSnapshot!.isEmpty) {
    stderr.writeln(
      'app_jit_snapshot --aot: cross-compilation to '
      '${args.targetOs}-${args.targetArch} requires --gen-snapshot',
    );
    exit(64);
  }
  if (mode == 'exe' &&
      (args.customDartaotruntime == null ||
          args.customDartaotruntime!.isEmpty)) {
    stderr.writeln(
      'app_jit_snapshot --aot: cross-compiling exe to '
      '${args.targetOs}-${args.targetArch} requires --dartaotruntime',
    );
    exit(64);
  }
}

/// Whether the compile delegates to `dart compile` with a fresh temporary
/// HOME directory: on non-ELF targets (e.g. native macOS Mach-O executables or
/// Windows) or jit-snapshot fallback on Windows. Cross-compilation targets are
/// always ELF and never delegate to `dartdev`.
bool _aotDelegatesToDartCompile({
  required String dart,
  required String mode,
  required bool isCross,
  required String targetDartaotruntime,
}) =>
    !isCross &&
    (mode == 'jit-snapshot' ||
        dart.endsWith('.exe') ||
        (mode == 'exe' && !_isElfFile(File(targetDartaotruntime))));

/// Compiles through `dart compile` instead of driving `gen_snapshot` directly
/// (see [_aotDelegatesToDartCompile]), exiting when the compile fails.
void _runAotViaDartCompile(_AotPlan plan) {
  final dart = plan.dart;
  final mode = plan.mode;
  final outputPath = plan.outputPath;
  final dillPath = plan.dillPath;
  final compileArgs = <String>[
    'compile',
    mode,
    if (mode == 'exe' || mode == 'aot-snapshot') '--verbosity=error',
    if (plan.args.enableAsserts) '--enable-asserts',
    if (plan.args.recordedUses != null)
      '--recorded-uses=${plan.args.recordedUses}',
    for (final opt in plan.args.extraGenSnapshotOptions)
      '--extra-gen-snapshot-options=$opt',
    '-o',
    outputPath,
    dillPath,
  ];
  final scratchBase = File(outputPath).parent..createSync(recursive: true);
  final tempHome = scratchBase.createTempSync('rules_dart_compile_home.');
  final childEnv = buildChildEnvironment(
    homeDir: tempHome.path,
    parentEnv: Platform.environment,
    isWindows: Platform.isWindows,
  );
  final ProcessResult res;
  try {
    res = Process.runSync(
      dart,
      compileArgs,
      environment: childEnv,
      includeParentEnvironment: false,
    );
  } finally {
    if (tempHome.existsSync()) {
      try {
        tempHome.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
  }
  if (res.exitCode != 0) {
    stdout.write(res.stdout as String);
    stderr.write(res.stderr as String);
    exit(res.exitCode);
  }
}

/// Bakes [dillPath] with its recorded usages into the scratch directory,
/// returning the baked path and the bake's exit code (echoing a failed bake's
/// output, as the caller fails the action with that code).
({String dill, int exitCode}) _bakeRecordedDill({
  required _AotPlan plan,
  required Directory tmpDir,
  required Map<String, String> homeEnv,
}) {
  // [_aotActiveDill] calls only with `--recorded-uses` present, so the
  // assertion below never fires.
  final recordedUses = plan.args.recordedUses!;
  final sdkBin = plan.sdkBin;
  final dillPath = plan.dillPath;
  final targetOs = plan.targetOs;
  final productPlatform = '$sdkBin/../lib/_internal/vm_platform_product.dill';
  final strongPlatform = '$sdkBin/../lib/_internal/vm_platform_strong.dill';
  final platformDill = File(productPlatform).existsSync()
      ? productPlatform
      : strongPlatform;
  final recordedDill = '${tmpDir.path}/recorded.dill';
  final gkRes = Process.runSync(
    plan.hostDartaotruntime,
    [
      '$sdkBin/snapshots/gen_kernel_aot.dart.snapshot',
      '--platform=$platformDill',
      '--aot',
      '--tfa',
      '--no-embed-sources',
      '-Ddart.vm.product=true',
      '-Ddart.vm.asan=false',
      '-Ddart.vm.msan=false',
      '-Ddart.vm.tsan=false',
      if (targetOs != null && targetOs.isNotEmpty) '--target-os=$targetOs',
      if (plan.args.enableAsserts) '--enable-asserts',
      '--from-dill=$dillPath',
      '--recorded-usages-file=$recordedUses',
      '-o',
      recordedDill,
      dillPath,
    ],
    environment: homeEnv,
    includeParentEnvironment: false,
  );
  if (gkRes.exitCode != 0) {
    stdout.write(gkRes.stdout as String);
    stderr.write(gkRes.stderr as String);
    return (dill: dillPath, exitCode: gkRes.exitCode);
  }
  return (dill: recordedDill, exitCode: 0);
}

/// Runs `gen_snapshot` over [activeDill] into [elfPath], returning its exit
/// code (echoing a failed run's output, as the caller fails the action with
/// that code).
int _runGenSnapshotElf({
  required String genSnapshot,
  required String elfPath,
  required bool enableAsserts,
  required List<String> extraGenSnapshotOptions,
  required String activeDill,
  required Map<String, String> homeEnv,
}) {
  final gsRes = Process.runSync(
    genSnapshot,
    [
      '--deterministic',
      '--snapshot_kind=app-aot-elf',
      '--elf=$elfPath',
      if (enableAsserts) '--enable_asserts',
      ...extraGenSnapshotOptions,
      activeDill,
    ],
    environment: homeEnv,
    includeParentEnvironment: false,
  );
  if (gsRes.exitCode != 0) {
    stdout.write(gsRes.stdout as String);
    stderr.write(gsRes.stderr as String);
    return gsRes.exitCode;
  }
  return 0;
}

/// Compiles a pre-built kernel `.dill` to an AOT snapshot or executable (see
/// the section comment above [_AotArgs]).
void _runAot(List<String> argv) {
  final args = _parseAotArgs(argv);
  final dart = args.dart;
  final mode = args.mode;
  final outputPath = args.outputPath;
  final dillPath = args.dillPath;
  final targetOs = args.targetOs;
  final targetArch = args.targetArch;

  if (dart == null || mode == null || outputPath == null || dillPath == null) {
    stderr.writeln(
      'app_jit_snapshot --aot: --dart, --mode, -o, and input dill are required',
    );
    exit(64);
  }

  final isCross =
      (targetOs != null && targetOs.isNotEmpty) ||
      (targetArch != null && targetArch.isNotEmpty);
  _checkAotCrossRequirements(args, mode, isCross);

  final sdkBin = File(dart).parent.path;
  final hostExeExt = dart.endsWith('.exe') ? '.exe' : '';
  final hostDartaotruntime = '$sdkBin/dartaotruntime$hostExeExt';
  final targetDartaotruntime = args.customDartaotruntime ?? hostDartaotruntime;
  final genSnapshot =
      args.customGenSnapshot ?? '$sdkBin/utils/gen_snapshot$hostExeExt';

  final plan = (
    args: args,
    dart: dart,
    mode: mode,
    outputPath: outputPath,
    dillPath: dillPath,
    sdkBin: sdkBin,
    hostDartaotruntime: hostDartaotruntime,
    targetDartaotruntime: targetDartaotruntime,
    genSnapshot: genSnapshot,
    targetOs: targetOs,
  );
  if (_aotDelegatesToDartCompile(
    dart: dart,
    mode: mode,
    isCross: isCross,
    targetDartaotruntime: targetDartaotruntime,
  )) {
    _runAotViaDartCompile(plan);
    return;
  }

  final failureExitCode = _runAotDirect(plan);
  if (failureExitCode != 0) {
    exit(failureExitCode);
  }
}

// Runs AOT compilation through gen_snapshot in a scratch directory.
// Returns the process exit code: 0 on success.
int _runAotDirect(_AotPlan plan) {
  final scratch = _prepareAotScratch(plan.outputPath);
  final tmpDir = scratch.tmpDir;
  final homeEnv = scratch.homeEnv;
  var failureExitCode = 0;
  try {
    final active = _aotActiveDill(plan: plan, tmpDir: tmpDir, homeEnv: homeEnv);
    if (active.exitCode != 0) return active.exitCode;

    final elfPath = plan.mode == 'aot-snapshot'
        ? plan.outputPath
        : '${tmpDir.path}/snapshot.elf';
    final gsExitCode = _snapshotElfAndLink(
      plan: plan,
      elfPath: elfPath,
      activeDill: active.dill,
      homeEnv: homeEnv,
    );
    if (gsExitCode != 0) {
      failureExitCode = gsExitCode;
      return failureExitCode;
    }
  } finally {
    if (tmpDir.existsSync()) {
      try {
        tmpDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
  }
  return failureExitCode;
}

// The scratch directory for one direct AOT compile, with an isolated HOME.
({Directory tmpDir, Map<String, String> homeEnv}) _prepareAotScratch(
  String outputPath,
) {
  final scratchBase = File(outputPath).parent..createSync(recursive: true);
  final tmpDir = scratchBase.createTempSync('rules_dart_aot.');
  final homeDir = Directory('${tmpDir.path}/home')..createSync(recursive: true);
  final homeEnv = buildChildEnvironment(
    homeDir: homeDir.path,
    parentEnv: Platform.environment,
    isWindows: Platform.isWindows,
  );
  return (tmpDir: tmpDir, homeEnv: homeEnv);
}

// The dill to snapshot: with `--recorded-uses` the uses baked in, otherwise
// the input dill. A nonzero exit code means baking failed.
({String dill, int exitCode}) _aotActiveDill({
  required _AotPlan plan,
  required Directory tmpDir,
  required Map<String, String> homeEnv,
}) {
  if (plan.args.recordedUses == null) {
    return (dill: plan.dillPath, exitCode: 0);
  }
  final baked = _bakeRecordedDill(plan: plan, tmpDir: tmpDir, homeEnv: homeEnv);
  if (baked.exitCode != 0) {
    return (dill: plan.dillPath, exitCode: baked.exitCode);
  }
  return (dill: baked.dill, exitCode: 0);
}

// Snapshots [activeDill] to [elfPath] and, for `exe`, links the executable.
// Returns the gen_snapshot exit code.
int _snapshotElfAndLink({
  required _AotPlan plan,
  required String elfPath,
  required String activeDill,
  required Map<String, String> homeEnv,
}) {
  final gsExitCode = _runGenSnapshotElf(
    genSnapshot: plan.genSnapshot,
    elfPath: elfPath,
    enableAsserts: plan.args.enableAsserts,
    extraGenSnapshotOptions: plan.args.extraGenSnapshotOptions,
    activeDill: activeDill,
    homeEnv: homeEnv,
  );
  if (gsExitCode != 0) return gsExitCode;
  if (plan.mode == 'exe') {
    writeAppAotElfExe(
      dartaotruntime: File(plan.targetDartaotruntime),
      snapshotElf: File(elfPath),
      output: File(plan.outputPath),
    );
  }
  return 0;
}

bool _isElfFile(File file) {
  if (!file.existsSync()) return false;
  final raf = file.openSync();
  try {
    final magic = raf.readSync(4);
    return magic.length == 4 &&
        magic[0] == 0x7f &&
        magic[1] == 0x45 &&
        magic[2] == 0x4c &&
        magic[3] == 0x46;
  } finally {
    raf.closeSync();
  }
}

/// Writes a self-contained AOT ELF executable to [output] by concatenating
/// [dartaotruntime], zero padding up to a 64 KiB page boundary, [snapshotElf],
/// and the 16-byte app-JIT/AOT trailer, then marks [output] executable (`0755`).
///
/// Does not use `File.copySync`: under remote execution and read-only sandboxes,
/// [dartaotruntime] has mode `0555` (or `0444`), and `copySync` copies that
/// read-only mode onto [output], causing a subsequent open for append to fail
/// with `EACCES`. Writing a fresh file and setting `0755` via `libc`'s `chmod`
/// avoids both copying read-only permissions and spawning `/bin/chmod`.
void writeAppAotElfExe({
  required File dartaotruntime,
  required File snapshotElf,
  required File output,
}) {
  const pageSize = 65536;
  output.parent.createSync(recursive: true);
  if (output.existsSync()) {
    output.deleteSync();
  }
  final runtimeBytes = dartaotruntime.readAsBytesSync();
  final runtimeLen = runtimeBytes.length;
  final padLen = (pageSize - (runtimeLen % pageSize)) % pageSize;
  final offset = runtimeLen + padLen;

  final raf = output.openSync(mode: FileMode.writeOnly);
  try {
    raf.writeFromSync(runtimeBytes);
    if (padLen > 0) {
      raf.writeFromSync(Uint8List(padLen));
    }
    raf.writeFromSync(snapshotElf.readAsBytesSync());
    final trailer = ByteData(16)
      ..setUint64(0, offset, Endian.little)
      ..setUint8(8, 0xdc)
      ..setUint8(9, 0xdc)
      ..setUint8(10, 0xf6)
      ..setUint8(11, 0xf6)
      ..setUint8(12, 0x00)
      ..setUint8(13, 0x00)
      ..setUint8(14, 0x00)
      ..setUint8(15, 0x00);
    raf.writeFromSync(trailer.buffer.asUint8List());
  } finally {
    raf.closeSync();
  }
  chmodFile(output.path, 0x1ed);
}

typedef _MallocNative = ffi.Pointer<ffi.Uint8> Function(ffi.Size);
typedef _MallocDart = ffi.Pointer<ffi.Uint8> Function(int);
typedef _FreeNative = ffi.Void Function(ffi.Pointer<ffi.Uint8>);
typedef _FreeDart = void Function(ffi.Pointer<ffi.Uint8>);
typedef _ChmodNative = ffi.Int Function(ffi.Pointer<ffi.Uint8>, ffi.Uint32);
typedef _ChmodDart = int Function(ffi.Pointer<ffi.Uint8>, int);
typedef _MkdirNative = ffi.Int Function(ffi.Pointer<ffi.Uint8>, ffi.Uint32);
typedef _MkdirDart = int Function(ffi.Pointer<ffi.Uint8>, int);

/// Atomically claims a new directory at [path] with POSIX permission bits
/// [mode]: libc `mkdir(2)` returns 0 only when this call creates the
/// directory, and fails nonzero — `EEXIST` when another local user won the
/// race to the cleared constant training path, or any other error — when it
/// does not. The caller must never use the path unless this returns 0.
///
/// A variable so tests can make the claim see `EEXIST` (see the unclaimable
/// training path test); production code never reassigns it.
int Function(String path, int mode) mkdirExclusive = _libcMkdir;

/// Claims [path] with libc `mkdir(2)`: 0 when this call created it, -1 on any
/// failure (the caller falls back without reading `errno`).
int _libcMkdir(String path, int mode) {
  if (Platform.isWindows) return -1;
  final lib = ffi.DynamicLibrary.process();
  final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
  final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
  final mkdir = lib.lookupFunction<_MkdirNative, _MkdirDart>('mkdir');
  final bytes = utf8.encode(path);
  final ptr = malloc(bytes.length + 1);
  if (ptr == ffi.nullptr) return -1;
  try {
    ptr.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    return mkdir(ptr, mode) == 0 ? 0 : -1;
  } finally {
    free(ptr);
  }
}

/// Sets POSIX permission bits [mode] on [path] via libc's `chmod(2)`.
void chmodFile(String path, int mode) {
  if (Platform.isWindows) return;
  final lib = ffi.DynamicLibrary.process();
  final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
  final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
  final chmod = lib.lookupFunction<_ChmodNative, _ChmodDart>('chmod');
  final bytes = utf8.encode(path);
  final ptr = malloc(bytes.length + 1);
  if (ptr == ffi.nullptr) {
    throw FileSystemException('malloc failed for chmod', path);
  }
  try {
    ptr.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    final rc = chmod(ptr, mode);
    if (rc != 0) {
      throw FileSystemException('chmod failed (rc=$rc)', path);
    }
  } finally {
    free(ptr);
  }
}

void _copyEntitySync(String srcPath, String dstPath) {
  final type = FileSystemEntity.typeSync(srcPath);
  if (type == FileSystemEntityType.file) {
    final dst = File(dstPath);
    if (dst.existsSync()) return;
    dst.parent.createSync(recursive: true);
    dst.writeAsBytesSync(File(srcPath).readAsBytesSync());
  } else if (type == FileSystemEntityType.directory) {
    for (final entity in Directory(srcPath).listSync(recursive: true)) {
      if (entity is File) {
        final rel = entity.path
            .substring(srcPath.length)
            .replaceAll(r'\', '/')
            .replaceFirst(RegExp(r'^/+'), '');
        final childDst = '$dstPath/$rel';
        if (FileSystemEntity.typeSync(childDst) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        File(childDst).parent.createSync(recursive: true);
        File(childDst).writeAsBytesSync(File(entity.path).readAsBytesSync());
      }
    }
  }
}

String _stripFsRootPrefix(String path, List<String> fsRoots) {
  final slashPath = path.replaceAll(r'\', '/');
  var bestRootLen = -1;
  String? bestRel;
  for (final rawRoot in fsRoots) {
    final root = rawRoot.replaceAll(r'\', '/').replaceFirst(RegExp(r'/+$'), '');
    if (root.isEmpty || root == '.') continue;
    final prefix = '$root/';
    if (slashPath.startsWith(prefix) && root.length > bestRootLen) {
      bestRootLen = root.length;
      bestRel = slashPath.substring(prefix.length);
    }
  }
  return bestRel ?? slashPath.replaceFirst(RegExp(r'^(?:\./)+'), '');
}

/// Normalizes a filesystem path for comparison: `/` separators, no leading
/// `./` segments.
String _normFsPath(String path) =>
    path.replaceAll(r'\', '/').replaceFirst(RegExp(r'^(?:\./)+'), '');

/// A diagnostic for every `gen_kernel` input source with a directive URI that
/// names no file the action can read through its declared inputs: a `file:`
/// URI in any spelling, any other scheme but `dart:` and `package:`, a
/// `package:` URI climbing above its package, or a relative URI resolving to
/// no declared input source. The front end reads such a URI off the host,
/// outside every `--filesystem-root`, so the wrapper refuses before compiling.
/// Climbing `..` segments are followed past the declared inputs, never
/// clamped: enough segments name any host path. Every `if` alternative is
/// checked, since the wrapper has no configuration to select by. Empty when
/// clean. Each diagnostic names the file, the directive and the URI.
///
/// A relative URI is accepted when it resolves to a declared source beside the
/// importing file, or when it resolves to a declared source's multi-root key
/// ([_resolveKeyRelativeTarget] over [_stableSourceKey]): the front end finds
/// each key where it is, so a generated sibling in `bazel-out` staged beside a
/// source-tree importer reads a declared input, not the host.
List<String> _findDisallowedGenKernelDirectives(
  List<String> sources,
  List<String> fsRoots,
) {
  final contents = <String, String>{};
  for (final path in sources) {
    try {
      // Malformed sequences become U+FFFD, never a skipped file: gen_kernel
      // accepts the file, so the guard scans what it can.
      contents[path] = utf8.decode(
        File(path).readAsBytesSync(),
        allowMalformed: true,
      );
    } on FileSystemException {
      // Missing or unreadable here; gen_kernel reports it.
    }
  }
  final declared = <String>{
    for (final path in contents.keys) normalizeStagedPath(path),
  };
  final declaredKeys = <String>{
    for (final path in contents.keys) _stableSourceKey(path, fsRoots),
  };
  final errors = <String>[];
  final paths = contents.keys.toList()..sort();
  for (final path in paths) {
    final content = contents[path];
    if (content == null) continue;
    final from = normalizeStagedPath(path);
    final fromKey = _stableSourceKey(path, fsRoots);
    final checked = scanAllDirectiveUrisChecked(content);
    if (checked.unparsable) {
      errors.add(unparsableDirectiveDiagnostic('app_jit_snapshot', path));
      continue;
    }
    for (final ref in checked.refs) {
      final error = _disallowedDirectiveError(
        ref,
        path: path,
        from: from,
        fromKey: fromKey,
        declared: declared,
        declaredKeys: declaredKeys,
      );
      if (error != null) errors.add(error);
    }
  }
  return errors;
}

// The refusal message for one directive reference naming an undeclared input,
// or null when the reference is allowed.
String? _disallowedDirectiveError(
  ScanRef ref, {
  required String path,
  required String from,
  required String fromKey,
  required Set<String> declared,
  required Set<String> declaredKeys,
}) {
  final uri = ref.uri;
  // A URI spanning lines is refused however it spells its target: the
  // front end's multi-line first-line rule reads a different file than
  // the resolvers below see (see [hasLineBreak]).
  if (hasLineBreak(uri)) {
    return "app_jit_snapshot: $path ${ref.kind} '$uri' is not a declared input.";
  }
  // The resolvers below skip empty segments, but the front end resolves
  // some such spellings absolutely: refuse them before resolving.
  if (hasEmptyPathSegment(uri)) {
    return "app_jit_snapshot: $path ${ref.kind} '$uri' is not a declared input.";
  }
  if (uri.startsWith(defaultMultiRootPrefix) || uri.startsWith('dart:')) {
    return null;
  }
  if (uri.startsWith('package:')) {
    if (isEscapingPackageUri(uri)) {
      return "app_jit_snapshot: $path ${ref.kind} '$uri' "
          'is not a declared input.';
    }
    return null;
  }
  if (isFileSchemeDirectiveUri(uri) || isDisallowedDirectiveUri(uri)) {
    return "app_jit_snapshot: $path ${ref.kind} '$uri' is not a declared input.";
  }
  final target = resolveStagedRelativeTarget(uri, from);
  // A null filesystem-path resolution is not acceptance: the key-space
  // lookup below gets its say, and a null there refuses the directive.
  if (target != null && declared.contains(target)) return null;
  final keyTarget = _resolveKeyRelativeTarget(uri, fromKey);
  if (keyTarget != null && declaredKeys.contains(keyTarget)) return null;
  return "app_jit_snapshot: $path ${ref.kind} '$uri' is not a declared input.";
}

/// The multi-root key naming the declared input source [path]: the
/// exec-root-relative path with its longest `--filesystem-root` prefix
/// stripped. The wrapper runs with the exec root as its working directory (the
/// `"."` root), so an absolute declared path under it becomes relative, and a
/// generated file's key drops the bin-root prefix — the same derivation the
/// entrypoint URI uses (see `stable_entry_path` and `stable_path` in
/// `common.bzl`). A relative directive URI resolved against one declared
/// source's key therefore names the same key the front end looks up whether
/// the target lives in the source tree or under `bazel-out`. Paths already
/// relative, or absolute but under no root and outside the working directory
/// (tests), keep the [_stripFsRootPrefix] spelling, which stays consistent
/// because every key in the comparison uses this same function.
String _stableSourceKey(String path, List<String> fsRoots) {
  var slash = path.replaceAll(r'\', '/');
  final cwd = Directory.current.path
      .replaceAll(r'\', '/')
      .replaceFirst(RegExp(r'/+$'), '');
  if (slash == cwd) {
    slash = '';
  } else if (slash.startsWith('$cwd/')) {
    slash = slash.substring(cwd.length + 1);
  }
  slash = slash.replaceFirst(RegExp(r'^(?:\./)+'), '');
  String? best;
  for (final rawRoot in fsRoots) {
    final root = rawRoot
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'/+$'), '')
        .replaceFirst(RegExp(r'^(?:\./)+'), '');
    if (root.isEmpty || root == '.') continue;
    if ((slash == root || slash.startsWith('$root/')) &&
        (best == null || root.length > best.length)) {
      best = root;
    }
  }
  if (best != null) {
    slash = slash == best ? '' : slash.substring(best.length + 1);
  }
  return slash;
}

/// The multi-root key a schemeless relative directive URI in the declared
/// source with key [fromKey] refers to: the front end resolves the URI against
/// the importing file's key and finds each key where it is, whether in the
/// source tree or under `bazel-out`, so a generated sibling staged beside its
/// importer names a declared input. `\` separates and escapes decode once, as
/// in [resolveStagedRelativeTarget]; a `..` climbing above the key root drops
/// away, the way the front end's own resolution stays inside the multi-root
/// space, and the caller accepts the result only when some declared source
/// holds that key.
///
/// Null when [uri] is not a relative URI (any scheme, a fragment, a
/// `//`-prefixed authority, or a `/`-absolute path, which names a host file
/// outside every root) or when a decoded `/` names no file. A `?...` query is
/// dropped and the path part resolved instead: an empty reference names the
/// importing file itself. Null never means "declared": the caller refuses it
/// unless the filesystem-path check above already accepted it.
String? _resolveKeyRelativeTarget(String uri, String fromKey) {
  final text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  // A fragment names no file: the front end reports a URI with one instead of
  // reading through it. A query names no file either: the front end reads the
  // file the path part names, so the path part alone is resolved below.
  if (text.contains('#')) return null;
  final query = text.indexOf('?');
  final path = query < 0 ? text : text.substring(0, query);
  if (path.contains(':')) return null;
  if (path.startsWith('//') || path.startsWith('/')) return null;
  // An empty reference names the importing file itself (RFC 3986).
  if (path.isEmpty) return fromKey;
  final stack = <String>[];
  for (final part in fromKey.split('/')) {
    if (part.isNotEmpty) stack.add(part);
  }
  // Drop the file name: the URI resolves against its directory.
  if (stack.isNotEmpty) stack.removeLast();
  for (final raw in path.split('/')) {
    // An empty segment is not skipped: the front end resolves some such
    // spellings absolutely, so the key lookup fails and the guard refuses the
    // directive instead of confining the wrong file.
    if (raw.isEmpty) return null;
    final seg = decodeUriSegment(raw);
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (stack.isNotEmpty) stack.removeLast();
      continue;
    }
    if (seg.contains('/')) return null;
    stack.add(seg);
  }
  return stack.join('/');
}

/// Links [dstPath] to [srcPath] (a file or directory), copying instead when
/// the platform refuses symlinks (Windows without developer mode).
///
/// [createLink] injects symlink creation (tests pass a throwing function to
/// exercise the copy fallback that Windows without developer mode takes).
void _stageEntitySync(
  String srcPath,
  String dstPath, {
  void Function(String linkPath, String target)? createLink,
}) {
  if (FileSystemEntity.typeSync(srcPath) == FileSystemEntityType.notFound) {
    return;
  }
  try {
    File(dstPath).parent.createSync(recursive: true);
    final slashSrc = srcPath.replaceAll(r'\', '/');
    final target = slashSrc.startsWith('/') || _isWindowsDrivePath(slashSrc)
        ? slashSrc
        : '${Directory.current.path.replaceAll(r'\', '/')}/$slashSrc';
    if (createLink != null) {
      createLink(dstPath, target);
    } else {
      Link(dstPath).createSync(target);
    }
    return;
  } on FileSystemException {
    // Fall through to a copy, which isolates just as well.
  }
  _copyEntitySync(srcPath, dstPath);
}

bool _isWindowsDrivePath(String s) =>
    s.length >= 2 &&
    ((s.codeUnitAt(0) >= 0x41 && s.codeUnitAt(0) <= 0x5a) ||
        (s.codeUnitAt(0) >= 0x61 && s.codeUnitAt(0) <= 0x7a)) &&
    s.codeUnitAt(1) == 0x3a &&
    (s.length == 2 || s.codeUnitAt(2) == 0x2f || s.codeUnitAt(2) == 0x5c);

/// The package-name to key-prefix map for the `package_config.json` at
/// [packagesPath]: each package maps to the stable key of the directory its
/// `package:` URIs name files under — the key of its `rootUri` joined with its
/// `packageUri` (`lib/` by default). `rootUri` takes every form the rule set's
/// generators emit: a multi-root URI under [multiRootPrefix], a `file:` URI,
/// or a path relative to the config file (see `generate_package_config` and
/// `generate_dev_package_config` in `common.bzl`), resolved against the
/// config's directory and keyed through [fsRoots] exactly like a recorded
/// `file:` URI. A package rooted anywhere unmappable maps to nothing: no
/// declared input lives under it, so no `package:` spelling it defines can
/// name one. Unreadable or malformed configs map every package to nothing,
/// failing closed: a `package:` spelling then names no declared input.
Map<String, String> genKernelPackageKeyPrefixes({
  required String packagesPath,
  required String multiRootPrefix,
  required List<String> fsRoots,
}) {
  final prefixes = <String, String>{};
  String text;
  try {
    text = File(packagesPath).readAsStringSync();
  } on FileSystemException {
    return prefixes;
  }
  dynamic config;
  try {
    config = jsonDecode(text);
  } on FormatException catch (_) {
    // Not JSON: the config defines no packages.
    return prefixes;
  }
  final packages = config is Map ? config['packages'] : null;
  if (packages is! List) return prefixes;
  final configDir = packagesPath.contains('/')
      ? packagesPath.substring(0, packagesPath.lastIndexOf('/'))
      : '.';
  for (final entry in packages) {
    if (entry is! Map) continue;
    final name = entry['name'];
    final rootUri = entry['rootUri'];
    if (name is! String || name.isEmpty || rootUri is! String) continue;
    final packageUri = entry['packageUri'];
    final packagePath = packageUri is String
        ? packageUri
              .replaceFirst(RegExp(r'^/+'), '')
              .replaceFirst(RegExp(r'/+$'), '')
        : 'lib';
    String? rootKey;
    if (rootUri.startsWith(multiRootPrefix)) {
      rootKey = rootUri
          .substring(multiRootPrefix.length)
          .replaceFirst(RegExp(r'/+$'), '');
    } else {
      rootKey = _packageEntryFsRootKey(
        rootUri,
        multiRootPrefix: multiRootPrefix,
        configDir: configDir,
        fsRoots: fsRoots,
      );
      if (rootKey == null) continue;
    }
    final prefix = packagePath.isEmpty
        ? rootKey
        : rootKey.isEmpty
        ? packagePath
        : '$rootKey/$packagePath';
    prefixes[name] = prefix;
  }
  return prefixes;
}

// The filesystem-root key for a package-config `rootUri` that is not a
// multi-root URI: a `file:` URI via its path, a schemeless spelling relative
// to the config file, or null for any other scheme or an escape above the
// exec root (no declared input lives there).
String? _packageEntryFsRootKey(
  String rootUri, {
  required String multiRootPrefix,
  required String configDir,
  required List<String> fsRoots,
}) {
  if (rootUri.startsWith('file:')) {
    String path;
    try {
      path = Uri.parse(rootUri).toFilePath();
    } on FormatException catch (_) {
      // Unparsable all the way down: names no package root.
      return null;
    } on UnsupportedError catch (_) {
      // A `file:` URI with no path form: names no package root.
      return null;
    }
    // An empty key names the exec root itself: a valid package root whose
    // `package:` spellings the prefix below still scopes by name.
    return _gkKeyOfFsPath(path, fsRoots);
  }
  if (!rootUri.contains(':')) {
    // A path relative to the config file, per the package-config spec.
    final resolved = _gkResolveRelative(configDir, rootUri);
    if (resolved == '..' || resolved.startsWith('../')) return null;
    return _gkKeyOfFsPath(resolved, fsRoots);
  }
  return null;
}

/// Resolves the config-relative [rel] against the config directory [dir],
/// lexically: `.` and empty segments drop out, each `..` pops. A result that
/// still climbs (`..` or `../...`) names a file above the exec root. An
/// absolute [dir] stays absolute.
String _gkResolveRelative(String dir, String rel) {
  final joined = dir == '.' || dir.isEmpty ? rel : '$dir/$rel';
  final absolute = joined.startsWith('/');
  final parts = <String>[];
  for (final part in joined.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty && parts.last != '..') {
        parts.removeLast();
      } else if (!absolute) {
        parts.add('..');
      }
    } else {
      parts.add(part);
    }
  }
  final normalized = parts.join('/');
  return absolute ? '/$normalized' : normalized;
}

/// The stable multi-root key of the filesystem [path]: `/` separators, made
/// relative to the working directory (the exec root) when absolute, with its
/// longest `--filesystem-root` prefix in [fsRoots] stripped. The empty string
/// when the path names no key (the working directory or a root itself).
String _gkKeyOfFsPath(String path, List<String> fsRoots) {
  final normPath = _normFsPath(path);
  final cwd = _normFsPath(Directory.current.path);
  final rel = normPath == cwd
      ? ''
      : normPath.startsWith('$cwd/')
      ? normPath.substring(cwd.length + 1)
      : normPath;
  return _normFsPath(_stripFsRootPrefix(rel, fsRoots));
}

/// The declared-input key the recorded kernel URI [uri] names, or null when it
/// names no workspace file (`dart:`, `data:`, the SDK, an untranslatable URI,
/// or the empty entry). The empty string marks a file no root names — outside
/// every root, or an unknown scheme — which is never a declared input, so such
/// reads fail closed. Recorded multi-root URIs decode once; recorded `file:`
/// URIs map through the working directory and [fsRoots] the way the wrapper's
/// staging keys them.
String? _gkKeyOfRecordedUri(
  String uri,
  String multiRootPrefix,
  List<String> fsRoots,
) => keyOfDillSourceUri(
  uri,
  multiRootPrefix,
  (fileUri) => _gkKeyOfFileUri(fileUri, fsRoots),
);

/// The declared-input key the recorded `file:` URI [uri] names through the
/// working directory and [fsRoots] the way the wrapper's staging keys them.
/// The empty string marks an unresolvable read, never a declared input.
String _gkKeyOfFileUri(String uri, List<String> fsRoots) {
  String path;
  try {
    path = Uri.parse(uri).toFilePath();
  } on FormatException catch (_) {
    // Unparsable all the way down: an unresolvable read, never declared.
    return '';
  } on UnsupportedError catch (_) {
    // A `file:` URI with no path form: an unresolvable read, never declared.
    return '';
  }
  final normPath = _normFsPath(path);
  final cwd = _normFsPath(Directory.current.path);
  final rel = normPath == cwd
      ? ''
      : normPath.startsWith('$cwd/')
      ? normPath.substring(cwd.length + 1)
      : normPath;
  final key = _normFsPath(_stripFsRootPrefix(rel, fsRoots));
  return key.isEmpty ? '' : key;
}

/// The declared-input key the `package:` URI [uri] names through
/// [packageKeyPrefixes] (see [genKernelPackageKeyPrefixes]), or null when no
/// package defines it.
String? _gkKeyOfPackageUri(String uri, Map<String, String> packageKeyPrefixes) {
  if (!uri.startsWith('package:')) return null;
  final rest = uri.substring('package:'.length);
  final slash = rest.indexOf('/');
  if (slash <= 0) return null;
  final prefix = packageKeyPrefixes[rest.substring(0, slash)];
  if (prefix == null) return null;
  final path = rest.substring(slash + 1);
  if (path.isEmpty) return null;
  return prefix.isEmpty ? path : '$prefix/$path';
}

/// Verifies that the `gen_kernel` output at [outputPath] read only declared
/// inputs: every workspace file its source table names is one of
/// [declaredKeys] (stable multi-root keys, as [_stableSourceKey] derives
/// them), and every library `importUri` and top-level canonical-name root is
/// either a `dart:` library, a multi-root or `package:` spelling of a declared
/// input ([packageKeyPrefixes] maps the `package:` spellings, as
/// [genKernelPackageKeyPrefixes] builds it), or a resolvable spelling of a
/// declared file. Returns the diagnostics, empty when clean.
///
/// Whether [library] is the front end's synthesized `vm:ffi:native-assets`
/// entry: with a `--native-assets` manifest the front end records the asset
/// library with the bare placeholder `dummy` as its source, no import URI,
/// and the library URI itself as its canonical name (the shape the pinned
/// SDK's `gen_kernel` emits). A user library cannot take this shape: `vm:`
/// imports are refused in directives before the compile runs, and no declared
/// file is ever recorded under the bare name `dummy`.
bool _isSynthesizedNativeAssetsLibrary(DillLibraryReference library) =>
    library.fileUri == 'dummy' &&
    library.importUri == null &&
    library.canonicalName == 'vm:ffi:native-assets';

/// Verifies that the `gen_kernel` output at [outputPath] read only declared
/// inputs: every workspace file its source table names is one of
/// [declaredKeys] (stable multi-root keys, as [_stableSourceKey] derives
/// them), and every library `importUri` and top-level canonical-name root is
/// either a `dart:` library, a multi-root or `package:` spelling of a declared
/// input ([packageKeyPrefixes] maps the `package:` spellings, as
/// [genKernelPackageKeyPrefixes] builds it), or a resolvable spelling of a
/// declared file. Returns the diagnostics, empty when clean.
///
/// When [hasNativeAssetsManifest] is set, the compile was given a
/// `--native-assets` manifest, so exactly the front end's synthesized
/// `vm:ffi:native-assets` entries are accepted (see
/// [_isSynthesizedNativeAssetsLibrary]): the bare `dummy` source-table URI,
/// which names no file, and the asset library's node and canonical-name root.
/// Without a manifest — or for any entry that only resembles the shape, such
/// as a user file or library literally named `dummy` — the same entries are
/// refused as usual.
///
/// A missing output passes: there is no read set to verify. An unreadable
/// file or an unparsable table fails closed: the compile produced bytes whose
/// reads cannot be verified.
List<String> verifyGenKernelReads({
  required String outputPath,
  required Set<String> declaredKeys,
  required String multiRootPrefix,
  required List<String> fsRoots,
  required Map<String, String> packageKeyPrefixes,
  required bool hasNativeAssetsManifest,
}) {
  final output = _readKernelOutput(outputPath);
  if (output.error != null) return <String>[output.error!];
  final bytes = output.bytes;
  if (bytes == null) return <String>[];
  final errors = <String>[];
  final uris = dillSourceUris(bytes);
  if (uris == null) {
    return <String>[
      'app_jit_snapshot: cannot read the sources of $outputPath; '
          'refusing the compile.',
    ];
  }
  errors.addAll(
    _recordedSourceUriErrors(
      uris: uris,
      outputPath: outputPath,
      hasNativeAssetsManifest: hasNativeAssetsManifest,
      multiRootPrefix: multiRootPrefix,
      fsRoots: fsRoots,
      declaredKeys: declaredKeys,
    ),
  );
  // The import URIs the packages define: every declared key under its
  // multi-root spelling and its `package:` spellings (one per package whose
  // root directory holds the key).
  final depImportUris = _depImportUris(
    declaredKeys: declaredKeys,
    multiRootPrefix: multiRootPrefix,
    packageKeyPrefixes: packageKeyPrefixes,
  );

  // An unparsable library or canonical-name table fails closed like an
  // unparsable source table: the compile produced bytes whose reads cannot be
  // verified. (An empty component is not unparsable: with no library nodes the
  // readers return no references, and the source-table verdict stands alone.)
  final libraries = dillLibraryReferences(bytes);
  final canonicalRoots = dillCanonicalRoots(bytes);
  if (libraries == null) {
    errors.add(
      'app_jit_snapshot: cannot read the libraries of $outputPath; '
      'refusing the compile.',
    );
  }
  if (canonicalRoots == null) {
    errors.add(
      'app_jit_snapshot: cannot read the canonical names of $outputPath; '
      'refusing the compile.',
    );
  }
  if (libraries == null || canonicalRoots == null) return errors;
  final ref = _ReferenceChecker(
    depImportUris: depImportUris,
    multiRootPrefix: multiRootPrefix,
    fsRoots: fsRoots,
    packageKeyPrefixes: packageKeyPrefixes,
    declaredKeys: declaredKeys,
  );
  errors.addAll(
    _libraryReferenceErrors(
      outputPath: outputPath,
      libraries: libraries,
      hasNativeAssetsManifest: hasNativeAssetsManifest,
      checker: ref,
    ),
  );
  errors.addAll(
    _canonicalRootErrors(
      outputPath: outputPath,
      canonicalRoots: canonicalRoots,
      hasNativeAssetsManifest: hasNativeAssetsManifest,
      checker: ref,
    ),
  );
  return errors;
}

// The import URIs the packages define: every declared key under its
// multi-root spelling and its `package:` spellings (one per package whose
// root directory holds the key).
Set<String> _depImportUris({
  required Set<String> declaredKeys,
  required String multiRootPrefix,
  required Map<String, String> packageKeyPrefixes,
}) {
  return <String>{
    for (final key in declaredKeys) ...[
      '$multiRootPrefix$key',
      for (final entry in packageKeyPrefixes.entries)
        if (entry.value.isEmpty ||
            key == entry.value ||
            key.startsWith('${entry.value}/'))
          'package:${entry.key}/${entry.value.isEmpty ? key : key.substring(entry.value.length + 1)}',
    ],
  };
}

// Decides whether one library-table reference names a declared input, a
// `dart:` library, or a package: the source table already verified the file
// read, and a resolvable spelling of a declared file passes.
final class _ReferenceChecker {
  _ReferenceChecker({
    required this.depImportUris,
    required this.multiRootPrefix,
    required this.fsRoots,
    required this.packageKeyPrefixes,
    required this.declaredKeys,
  });

  final Set<String> depImportUris;
  final String multiRootPrefix;
  final List<String> fsRoots;
  final Map<String, String> packageKeyPrefixes;
  final Set<String> declaredKeys;

  bool isDeclared(String? reference) {
    if (reference == null || reference.isEmpty) return true;
    // A bare identifier names no file: only a URI- or path-shaped reference
    // can name one.
    if (!reference.contains(':') && !reference.contains('/')) return true;
    if (depImportUris.contains(reference)) return true;
    if (reference.startsWith('dart:') ||
        reference.startsWith('data:') ||
        reference.startsWith('org-dartlang-sdk:') ||
        reference.startsWith('org-dartlang-untranslatable-uri:')) {
      return true;
    }
    // A resolvable spelling of a declared file passes: the source table
    // already verified the file read, and this spelling names it.
    var key = _gkKeyOfRecordedUri(reference, multiRootPrefix, fsRoots);
    if (key == null || key.isEmpty) {
      key = _gkKeyOfPackageUri(reference, packageKeyPrefixes);
    }
    return key != null && key.isNotEmpty && declaredKeys.contains(key);
  }
}

// The refusal messages for library import URIs and canonical names naming no
// declared input, `dart:` library, or package.
List<String> _libraryReferenceErrors({
  required String outputPath,
  required List<DillLibraryReference> libraries,
  required bool hasNativeAssetsManifest,
  required _ReferenceChecker checker,
}) {
  final errors = <String>[];
  for (final library in libraries) {
    // The manifest-synthesized asset library names no file: only its exact
    // shape passes, and only with a manifest.
    if (hasNativeAssetsManifest && _isSynthesizedNativeAssetsLibrary(library)) {
      continue;
    }
    for (final reference in [library.importUri, library.canonicalName]) {
      if (!checker.isDeclared(reference)) {
        errors.add(
          'app_jit_snapshot: $outputPath references $reference, which no '
          'declared input, `dart:` library, or package defines; refusing '
          'the compile.',
        );
      }
    }
  }
  return errors;
}

// The refusal messages for top-level canonical names naming no declared
// input, `dart:` library, or package. A held component can smuggle a root the
// library nodes never mention, so every root is checked with the same
// predicate.
List<String> _canonicalRootErrors({
  required String outputPath,
  required List<String> canonicalRoots,
  required bool hasNativeAssetsManifest,
  required _ReferenceChecker checker,
}) {
  final errors = <String>[];
  for (final root in canonicalRoots) {
    // The synthesized asset library's canonical name is its own root.
    if (hasNativeAssetsManifest && root == 'vm:ffi:native-assets') {
      continue;
    }
    if (!checker.isDeclared(root)) {
      errors.add(
        'app_jit_snapshot: $outputPath references $root, which no '
        'declared input, `dart:` library, or package defines; refusing '
        'the compile.',
      );
    }
  }
  return errors;
}

// The kernel output bytes, or the refusal message when they cannot be read.
// A missing output has no read set to verify.
({Uint8List? bytes, String? error}) _readKernelOutput(String outputPath) {
  final dillFile = File(outputPath);
  if (!dillFile.existsSync()) return (bytes: null, error: null);
  try {
    return (bytes: dillFile.readAsBytesSync(), error: null);
  } on FileSystemException {
    return (
      bytes: null,
      error:
          'app_jit_snapshot: cannot read the kernel output at $outputPath; '
          'refusing the compile.',
    );
  }
}

// The refusal messages for recorded source URIs naming no declared input.
List<String> _recordedSourceUriErrors({
  required List<String> uris,
  required String outputPath,
  required bool hasNativeAssetsManifest,
  required String multiRootPrefix,
  required List<String> fsRoots,
  required Set<String> declaredKeys,
}) {
  final errors = <String>[];
  for (final uri in uris) {
    // A `--native-assets` manifest makes the front end synthesize the
    // `vm:ffi:native-assets` library from the bare placeholder URI `dummy`,
    // which names no file; without a manifest the same spelling still fails
    // below, as does any other undeclared spelling.
    if (hasNativeAssetsManifest && uri == 'dummy') continue;
    final key = _gkKeyOfRecordedUri(uri, multiRootPrefix, fsRoots);
    if (key == null) continue;
    if (key.isEmpty || !declaredKeys.contains(key)) {
      errors.add(
        'app_jit_snapshot: $outputPath reads $uri, which is not a declared '
        'input; refusing the compile.',
      );
    }
  }
  return errors;
}

/// The parsed `--gen-kernel` arguments (see [_parseGenKernelArgs]): the
/// runtime, the args forwarded to `gen_kernel`, the declared inputs, the
/// filesystem roots, and the output.
final class _GenKernelArgs {
  var snapshotPatched = false;
  String? outputPath;
  final rawGenArgs = <String>[];
  final declaredInputSources = <String>[];
  final fsRoots = <String>[];
}

/// Parses the `--gen-kernel` arguments after the `dartaotruntime` executable.
_GenKernelArgs _parseGenKernelArgs(List<String> argv) {
  final args = _GenKernelArgs();
  for (var i = 1; i < argv.length; i++) {
    i = _applyGenKernelArg(args, argv, i);
  }
  return args;
}

/// Applies the argument at [i], returning the index of the last argument it
/// consumed (the same index, or one further when it takes a separate value).
/// Wrapper-only options are consumed; `--filesystem-root` and `-o`/`--output`
/// are recorded without consuming their value, and every other argument —
/// including those — is forwarded to `gen_kernel`.
int _applyGenKernelArg(_GenKernelArgs args, List<String> argv, int i) {
  final arg = argv[i];
  // Passed by Starlark when the snapshot at rawGenArgs[0] is the
  // content-keyed patched copy declared by the toolchain. Consumed here and
  // never forwarded to gen_kernel.
  if (arg == '--comma-patched-snapshot') {
    args.snapshotPatched = true;
    return i;
  }
  if (arg == '--input-source' && i + 1 < argv.length) {
    args.declaredInputSources.add(argv[++i]);
    return i;
  }
  if (arg.startsWith('--input-source=')) {
    args.declaredInputSources.add(arg.substring('--input-source='.length));
    return i;
  }
  if (arg == '--input-sources-file' && i + 1 < argv.length) {
    _readInputSourcesFile(args, argv[++i]);
    return i;
  }
  if (arg.startsWith('--input-sources-file=')) {
    _readInputSourcesFile(args, arg.substring('--input-sources-file='.length));
    return i;
  }
  if (arg == '--filesystem-root' && i + 1 < argv.length) {
    args.fsRoots.add(argv[i + 1]);
  } else if (arg.startsWith('--filesystem-root=')) {
    args.fsRoots.add(arg.substring('--filesystem-root='.length));
  } else if ((arg == '-o' || arg == '--output') && i + 1 < argv.length) {
    args.outputPath = argv[i + 1];
  } else if (arg.startsWith('-o=')) {
    args.outputPath = arg.substring('-o='.length);
  } else if (arg.startsWith('--output=')) {
    args.outputPath = arg.substring('--output='.length);
  }
  args.rawGenArgs.add(arg);
  return i;
}

/// Reads declared inputs from the `--input-sources-file` at [path]: one
/// source per nonempty line. A missing file lists nothing.
void _readInputSourcesFile(_GenKernelArgs args, String path) {
  final file = File(path);
  if (file.existsSync()) {
    for (final line in file.readAsLinesSync()) {
      if (line.isNotEmpty) args.declaredInputSources.add(line);
    }
  }
}

// Exits when a define contains a comma but the gen_kernel snapshot is not the
// toolchain's patched copy: its Parser._setOption comma-splitting is only
// tolerable for comma-free defines. Fail loudly instead of miscompiling.
void _rejectUnpatchedCommaDefines(
  List<String> rawGenArgs,
  bool snapshotPatched,
) {
  final commaError = unpatchedCommaDefinesError(
    rawGenArgs,
    snapshotPatched: snapshotPatched,
    snapshotKind: 'gen_kernel',
    toolName: 'app_jit_snapshot',
  );
  if (commaError != null) {
    stderr.writeln(commaError);
    exit(1);
  }
}

// Exits when a declared source's directives read the host (see
// [_findDisallowedGenKernelDirectives]): a disallowed URI fails however the
// roots resolve.
void _rejectDisallowedDirectives(
  List<String> declaredInputSources,
  List<String> fsRoots,
) {
  final disallowedDirectives = _findDisallowedGenKernelDirectives(
    declaredInputSources,
    fsRoots,
  );
  if (disallowedDirectives.isNotEmpty) {
    for (final error in disallowedDirectives) {
      stderr.writeln(error);
    }
    exit(1);
  }
}

/// Runs `gen_kernel` via `dartaotruntime` with comma-splitting disabled on
/// `-D` / `--define` options and an isolated `--filesystem-root` containing
/// only declared input sources.
void _runGenKernel(List<String> argv) {
  if (argv.length < 2) {
    stderr.writeln(
      'app_jit_snapshot --gen-kernel: expected <dartaotruntime> <gen_kernel_args...>',
    );
    exit(64);
  }
  final dartaotruntime = argv.first;
  final args = _parseGenKernelArgs(argv);
  final rawGenArgs = args.rawGenArgs;
  final declaredInputSources = args.declaredInputSources;
  final fsRoots = args.fsRoots;
  final snapshotPatched = args.snapshotPatched;
  final outputPath = args.outputPath;

  // The gen_kernel snapshot must already be the toolchain's patched copy when
  // a define contains a comma: its Parser._setOption comma-splitting is only
  // tolerable for comma-free defines. Fail loudly instead of miscompiling.
  _rejectUnpatchedCommaDefines(rawGenArgs, snapshotPatched);

  // No declared source may read the host (see
  // [_findDisallowedGenKernelDirectives]). This runs before the isolated-root
  // staging below: a disallowed URI fails however the roots resolve.
  _rejectDisallowedDirectives(declaredInputSources, fsRoots);

  // The scratch directories below anchor at the declared output: shared temp
  // is never used, so concurrent actions cannot see each other's files.
  if (outputPath == null) {
    stderr.writeln('app_jit_snapshot --gen-kernel: -o/--output is required');
    exit(64);
  }

  // Only stage an isolated filesystem root when an undeclared file would
  // otherwise shadow a declared input. In the common case (no shadows) the
  // declared roots are forwarded unchanged.
  final staged = _stageIsolatedRoot(
    declaredInputSources: declaredInputSources,
    fsRoots: fsRoots,
    outputPath: outputPath,
    rawGenArgs: rawGenArgs,
  );
  _runGenKernelProcess(
    dartaotruntime: dartaotruntime,
    forwarded: staged.forwarded,
    isolatedRootDir: staged.isolatedRoot,
    outputPath: outputPath,
  );

  // The compile read only what its directives name, and the directive check
  // above refused every hostile spelling it knows — but a spelling it misses
  // would read the host into the output, so the output's own read set is
  // verified against the declared inputs before the action succeeds (see
  // [verifyGenKernelReads]). A dirty read set deletes the output and fails:
  // the kernel must never carry an undeclared file.
  final verify = _genKernelVerifyOptions(rawGenArgs);
  _verifyGenKernelOutput(
    outputPath: outputPath,
    declaredInputSources: declaredInputSources,
    fsRoots: fsRoots,
    multiRootPrefix: '${verify.scheme}:///',
    hasNativeAssetsManifest: verify.hasNativeAssetsManifest,
    packagesPath: verify.packagesPath,
  );
}

// Whether an undeclared file would shadow a declared input through some
// filesystem root: each declared source is compared against every root, where
// the candidate naming the declared file itself is its origin, and any other
// candidate that exists on disk is a shadow.
bool _hasShadowRisk(List<String> declaredInputSources, List<String> fsRoots) {
  if (declaredInputSources.isEmpty || fsRoots.isEmpty) return false;
  final normRoots = <String>[
    for (final root in fsRoots)
      _normFsPath(root).replaceFirst(RegExp(r'/+$'), ''),
  ];
  for (final srcPath in declaredInputSources) {
    final normSrc = _normFsPath(srcPath);
    final normKey = _normFsPath(_stripFsRootPrefix(srcPath, fsRoots));
    if (normKey.isEmpty) return true;
    for (final normRoot in normRoots) {
      final candidate = normRoot == '.' || normRoot.isEmpty
          ? normKey
          : '$normRoot/$normKey';
      // The candidate naming the declared file itself is its origin.
      if (candidate == normSrc) continue;
      if (File(candidate).existsSync()) return true;
    }
  }
  return false;
}

// The isolated `--filesystem-root` staging the declared inputs, with the
// forwarded `gen_kernel` arguments rewritten to it; without shadow risk the
// declared roots are forwarded unchanged and no staging exists.
({Directory? isolatedRoot, List<String> forwarded}) _stageIsolatedRoot({
  required List<String> declaredInputSources,
  required List<String> fsRoots,
  required String outputPath,
  required List<String> rawGenArgs,
}) {
  final forwarded = <String>[];
  if (!_hasShadowRisk(declaredInputSources, fsRoots)) {
    forwarded.addAll(rawGenArgs);
    return (isolatedRoot: null, forwarded: forwarded);
  }
  final baseDir = File(outputPath).parent;
  baseDir.createSync(recursive: true);
  final isolatedRootDir = baseDir.createTempSync('.gen_kernel_root.');
  final seenKeys = <String>{};
  for (final srcPath in declaredInputSources) {
    final key = _stripFsRootPrefix(srcPath, fsRoots);
    if (key.isEmpty || !seenKeys.add(key)) continue;
    _stageEntitySync(srcPath, '${isolatedRootDir.path}/$key');
  }
  var insertedRoot = false;
  for (var i = 0; i < rawGenArgs.length; i++) {
    final arg = rawGenArgs[i];
    if (arg == '--filesystem-root' && i + 1 < rawGenArgs.length) {
      i++;
      if (!insertedRoot) {
        insertedRoot = true;
        forwarded
          ..add('--filesystem-root')
          ..add(isolatedRootDir.path);
      }
      continue;
    }
    if (arg.startsWith('--filesystem-root=')) {
      if (!insertedRoot) {
        insertedRoot = true;
        forwarded.add('--filesystem-root=${isolatedRootDir.path}');
      }
      continue;
    }
    forwarded.add(arg);
  }
  return (isolatedRoot: isolatedRootDir, forwarded: forwarded);
}

// Runs `gen_kernel` with an isolated home, relays its output, and exits
// non-zero when it fails. The scratch directories anchor at the declared
// output: shared temp is never used, so concurrent actions cannot see each
// other's files.
void _runGenKernelProcess({
  required String dartaotruntime,
  required List<String> forwarded,
  required Directory? isolatedRootDir,
  required String outputPath,
}) {
  final genKernelScratchBase = File(outputPath).parent
    ..createSync(recursive: true);
  final tempHome = genKernelScratchBase.createTempSync(
    'rules_dart_gen_kernel_home.',
  );
  final childEnv = buildChildEnvironment(
    homeDir: tempHome.path,
    parentEnv: Platform.environment,
    isWindows: Platform.isWindows,
  );
  final ProcessResult res;
  try {
    res = Process.runSync(
      dartaotruntime,
      forwarded,
      environment: childEnv,
      includeParentEnvironment: false,
    );
  } finally {
    if (isolatedRootDir != null && isolatedRootDir.existsSync()) {
      try {
        isolatedRootDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
    if (tempHome.existsSync()) {
      try {
        tempHome.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
  }
  if ((res.stdout as String).isNotEmpty) {
    stdout.write(res.stdout as String);
  }
  if ((res.stderr as String).isNotEmpty) {
    stderr.write(res.stderr as String);
  }
  if (res.exitCode != 0) {
    exit(res.exitCode);
  }
}

// The read-set verification options carried in the forwarded arguments: the
// filesystem scheme, the packages config, and the native-assets manifest flag.
({String scheme, String? packagesPath, bool hasNativeAssetsManifest})
_genKernelVerifyOptions(List<String> rawGenArgs) {
  var scheme = defaultMultiRootPrefix.replaceFirst(RegExp(r':///$'), '');
  String? packagesPath;
  var hasNativeAssetsManifest = false;
  for (var i = 0; i < rawGenArgs.length; i++) {
    final arg = rawGenArgs[i];
    if (arg == '--filesystem-scheme' && i + 1 < rawGenArgs.length) {
      scheme = rawGenArgs[i + 1];
    } else if (arg.startsWith('--filesystem-scheme=')) {
      scheme = arg.substring('--filesystem-scheme='.length);
    } else if (arg == '--packages' && i + 1 < rawGenArgs.length) {
      packagesPath = rawGenArgs[i + 1];
    } else if (arg.startsWith('--packages=')) {
      packagesPath = arg.substring('--packages='.length);
    } else if (arg == '--native-assets' && i + 1 < rawGenArgs.length) {
      hasNativeAssetsManifest = true;
    } else if (arg.startsWith('--native-assets=')) {
      hasNativeAssetsManifest = true;
    }
  }
  return (
    scheme: scheme,
    packagesPath: packagesPath,
    hasNativeAssetsManifest: hasNativeAssetsManifest,
  );
}

// Verifies the compile's own read set against the declared inputs (see
// [verifyGenKernelReads]). A dirty read set deletes the output and fails: the
// kernel must never carry an undeclared file.
void _verifyGenKernelOutput({
  required String outputPath,
  required List<String> declaredInputSources,
  required List<String> fsRoots,
  required String multiRootPrefix,
  required bool hasNativeAssetsManifest,
  required String? packagesPath,
}) {
  final readErrors = verifyGenKernelReads(
    outputPath: outputPath,
    declaredKeys: {
      for (final path in declaredInputSources) _stableSourceKey(path, fsRoots),
    },
    multiRootPrefix: multiRootPrefix,
    fsRoots: fsRoots,
    hasNativeAssetsManifest: hasNativeAssetsManifest,
    packageKeyPrefixes: packagesPath == null
        ? <String, String>{}
        : genKernelPackageKeyPrefixes(
            packagesPath: packagesPath,
            multiRootPrefix: multiRootPrefix,
            fsRoots: fsRoots,
          ),
  );
  if (readErrors.isNotEmpty) {
    for (final error in readErrors) {
      stderr.writeln(error);
    }
    try {
      File(outputPath).deleteSync();
    } on FileSystemException {
      // The compile failed; a leftover output must not survive it.
    }
    exit(1);
  }
}
