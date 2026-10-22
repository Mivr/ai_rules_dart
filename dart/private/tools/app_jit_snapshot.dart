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
// behind still clears. The lock opens append-only for every user (mode 0666,
// fixed where missing); a lock that still will not open for writing, as
// another user's 0644 lock, fails the action too — a shared lock would let
// two trainings hold it at once, and the second would delete the first's
// live training directory as its own. A lock held past the deadline fails the
// action the same way (see [_openConstantLock]): the failure names the lock,
// the holder's PID, the deadline, and the remedies. Either failure names the path, the
// entry's type and its owner uid: remove the entry (or have the lock's owner
// make it world-writable or remove it), pass
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

import 'comma_patch.dart';

void main(List<String> argv) {
  if (argv.isNotEmpty && argv.first == '--aot') {
    _runAot(argv.sublist(1));
    return;
  }
  if (argv.isNotEmpty && argv.first == '--gen-kernel') {
    _runGenKernel(argv.sublist(1));
    return;
  }
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
  _trainFromArgs(
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
void _trainFromArgs({
  required String? dart,
  required String? dartvm,
  required String? snapshot,
  required String? trainKey,
  required int lockTimeout,
  required List<String> dartArgs,
  required bool enableAsserts,
  required bool fallbackAllowed,
  required Map<String, String> env,
  required List<_Pair> copies,
  required List<_Pair> trees,
}) {
  if (dart == null || snapshot == null || dartArgs.isEmpty) {
    _usage('--dart, --snapshot and the dart arguments are required');
  }
  trainKeyOverride = trainKey;
  lockTimeoutSecs = lockTimeout;

  final out = File(snapshot).absolute;
  final exitCode = _trainInScratch(
    dart: File(dart).absolute.path,
    dartvm: dartvm == null ? null : File(dartvm).absolute.path,
    dartArgs: dartArgs,
    enableAsserts: enableAsserts,
    fallbackAllowed: fallbackAllowed,
    env: env,
    copies: [for (final c in copies) _Pair(c.key, File(c.value).absolute.path)],
    trees: [
      for (final t in trees) _Pair(t.key, Directory(t.value).absolute.path),
    ],
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
  final result = <String, String>{};

  bool isValidEntry(String key, String value) =>
      key.isNotEmpty &&
      !key.contains('=') &&
      !key.contains('\x00') &&
      !value.contains('\x00');

  void setEnv(String key, String value) {
    if (!isValidEntry(key, value)) return;
    if (win) {
      final upper = key.toUpperCase();
      result.removeWhere(
        (existingKey, _) => existingKey.toUpperCase() == upper,
      );
    }
    result[key] = value;
  }

  if (win) {
    final systemRoot =
        _lookupEnvCaseInsensitive(source, 'SystemRoot') ??
        _lookupEnvCaseInsensitive(source, 'WINDIR') ??
        r'C:\Windows';
    final systemDrive =
        _lookupEnvCaseInsensitive(source, 'SystemDrive') ??
        (systemRoot.length >= 2 && systemRoot[1] == ':'
            ? systemRoot.substring(0, 2)
            : 'C:');
    setEnv('SystemRoot', systemRoot);
    setEnv('WINDIR', _lookupEnvCaseInsensitive(source, 'WINDIR') ?? systemRoot);
    setEnv('SystemDrive', systemDrive);
    setEnv(
      'COMSPEC',
      _lookupEnvCaseInsensitive(source, 'COMSPEC') ??
          '$systemRoot\\System32\\cmd.exe',
    );
    setEnv(
      'PATHEXT',
      _lookupEnvCaseInsensitive(source, 'PATHEXT') ?? '.COM;.EXE;.BAT;.CMD',
    );
    final parentPath = _lookupEnvCaseInsensitive(source, 'PATH');
    setEnv(
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
        setEnv(optionalKey, val);
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
      setEnv(homeKey, homeDir);
    }
    for (final entry in overrides.entries) {
      setEnv(entry.key, entry.value);
    }
    if ((_lookupEnvCaseInsensitive(result, 'SystemRoot') ?? '').isEmpty) {
      setEnv('SystemRoot', systemRoot);
    }
    return result;
  }

  if (includeParent) {
    for (final entry in source.entries) {
      if (_isolatedHomeEnvKeys.contains(entry.key.toUpperCase())) continue;
      setEnv(entry.key, entry.value);
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
      setEnv(homeKey, homeDir);
    }
  } else {
    setEnv('HOME', homeDir);
    setEnv('TMPDIR', homeDir);
  }
  for (final entry in overrides.entries) {
    setEnv(entry.key, entry.value);
  }
  return result;
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

void _releaseConstantLock(RandomAccessFile lock) {
  try {
    lock.unlockSync();
  } on FileSystemException {
    // Ignore cleanup errors.
  }
  try {
    lock.closeSync();
  } on FileSystemException {
    // Ignore cleanup errors.
  }
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

/// Takes the lock without blocking, returning true when it is now held.
///
/// A non-blocking exclusive `fcntl` try-lock: false means another process
/// holds the lock, and the caller polls until its deadline (see
/// [_openConstantLock]) instead of hanging forever. Any other lock error
/// reads the same way: the deadline still fails the action closed.
bool _tryExclusiveLock(RandomAccessFile lock) {
  try {
    lock.lockSync(FileLock.exclusive);
    return true;
  } on FileSystemException {
    // Held by another process (or unlocked for us): poll until the deadline.
    return false;
  }
}

/// Fixes the group/other write bits on [constantTrainLock] where they are
/// missing (see [_openConstantLock]): a no-op where the bits are already set,
/// ignored where the lock is not ours to chmod.
void _fixLockMode() {
  try {
    // Shareable across users on a shared host, whatever the creator's
    // umask; a no-op fixup where the bits are already set.
    chmodFile(constantTrainLock, 0x1b6);
  } on FileSystemException {
    // Not ours to chmod (a lock that opens append-only but is owned by
    // another user): the lock is still held, so training proceeds.
  }
}

/// Opens the lock serializing trainings at [constantTrainDir] and takes it
/// exclusively, returning the held lock.
///
/// The lock file opens append-only and is never written: a pre-existing
/// regular file keeps its content. A freshly created lock (made with the
/// process umask, usually 0644) is set to 0666 explicitly, umask-proof, so
/// every user on a shared host can open it; a pre-existing lock that is ours
/// but lacks the group/other write bits is fixed the same way (a foreign
/// lock's chmod fails, which is ignored: the lock is still held). When the
/// append-open itself fails, as on a foreign 0644 lock, there is no
/// read-only path: an `fcntl(2)` shared lock coexists with other shared
/// holders, so two trainings that reached the keyed path that way could
/// both hold it, and the second would delete the first's live training
/// directory as "its own" before claiming the path. The caller fails the
/// action instead (see [_acquireConstantDir]). Null when the lock path is a
/// symlink, or cannot be opened at all.
///
/// A contended lock never blocks forever: the exclusive take is a
/// non-blocking `fcntl` try-lock (see [_tryExclusiveLock]), polled with
/// sleeps backing off from 50 ms to 1 s until [lockTimeoutSecs] seconds pass.
/// After 10 s of waiting, and then every 60 s, one notice names the lock path
/// and the holder's PID (see [_lockHolderPid]), or "unknown" where it cannot
/// be read. At the deadline the path counts as unavailable: null is returned
/// with [_lockWaitTimedOut] set, and the caller fails the action (or falls
/// back where allowed), naming the lock, the holder and the deadline.
RandomAccessFile? _openConstantLock() {
  if (FileSystemEntity.isLinkSync(constantTrainLock)) return null;
  _lockWaitTimedOut = false;
  _lockHolderPidAtDeadline = null;
  _lockDeadlineSecs = lockTimeoutSecs;
  final RandomAccessFile lock;
  try {
    lock = File(constantTrainLock).openSync(mode: FileMode.append);
  } on FileSystemException {
    // The append-open failed (a foreign 0644 lock, or a non-file at the
    // path): no shared-lock fallback, the caller fails the action.
    return null;
  }
  if (_tryExclusiveLock(lock)) {
    _fixLockMode();
    return lock;
  }
  final stopwatch = Stopwatch()..start();
  final deadline = Duration(seconds: lockTimeoutSecs);
  var sleepMs = 50;
  var nextNotice = const Duration(seconds: 10);
  for (;;) {
    final remaining = deadline - stopwatch.elapsed;
    if (remaining <= Duration.zero) break;
    sleep(
      remaining < Duration(milliseconds: sleepMs)
          ? remaining
          : Duration(milliseconds: sleepMs),
    );
    if (_tryExclusiveLock(lock)) {
      _fixLockMode();
      return lock;
    }
    sleepMs = sleepMs >= 500 ? 1000 : sleepMs * 2;
    if (stopwatch.elapsed >= nextNotice) {
      final holder = _lockHolderPid(constantTrainLock);
      stderr.writeln(
        'app_jit_snapshot: waiting for $constantTrainLock'
        '${holder == null ? ' held by process unknown' : ' held by process $holder'}...',
      );
      nextNotice += const Duration(seconds: 60);
    }
  }
  _lockWaitTimedOut = true;
  _lockHolderPidAtDeadline = _lockHolderPid(constantTrainLock);
  try {
    lock.closeSync();
  } on FileSystemException {
    // Ignore cleanup errors.
  }
  return null;
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
    final info = _statEntry(path);
    if (info != null && info.kind == 'directory' && info.uid == _ownUid()) {
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

/// Our uid, for telling our own stale directories (whose modes a crashed
/// training may have left read-only) from another user's.
int _ownUid() {
  if (Platform.isWindows) return -1;
  final lib = ffi.DynamicLibrary.process();
  final geteuid = lib.lookupFunction<_GeteuidNative, _GeteuidDart>('geteuid');
  return geteuid();
}

/// Names the entry currently at [path] for the fail-closed error: its type
/// and its owner uid, never its content.
String _describeEntryAt(String path) {
  final info = _statEntry(path);
  if (info == null) {
    return 'entry at $path of unknown ownership';
  }
  return '${info.kind} at $path owned by uid ${info.uid}';
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
({Directory dir, RandomAccessFile lock})? _acquireConstantDir() {
  if (Platform.isWindows) return null;
  _constantLockUnavailable = false;
  final RandomAccessFile? lock = _openConstantLock();
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
          'the lock file ${_describeEntryAt(constantTrainLock)} cannot be opened for writing';
    }
    _constantLockUnavailable = true;
    return null;
  }
  ({Directory dir, RandomAccessFile lock})? fail(String reason) {
    _constantDirUnavailable = reason;
    _releaseConstantLock(lock);
    return null;
  }

  try {
    if (!removeStaleEntry(constantTrainDir)) {
      return fail(
        'the ${_describeEntryAt(constantTrainDir)} cannot be removed',
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
        'the ${_describeEntryAt(constantTrainDir)} cannot be claimed',
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
        'the ${_describeEntryAt(constantTrainDir)} cannot be claimed',
      );
    }
  } on FileSystemException {
    return fail('the ${_describeEntryAt(constantTrainDir)} cannot be claimed');
  }
  return (dir: Directory(constantTrainDir), lock: lock);
}

/// Writes the fail-closed error for a null [_acquireConstantDir]: the
/// blocker in [_constantDirUnavailable] and its remedies. A lock that stayed
/// held past its deadline names stopping the holder and waiting longer; any
/// other blocked lock names the lock's own remedies — its owner makes it
/// world-writable or removes it — since we cannot remove another user's lock;
/// a blocked training directory names removing the entry.
void _writeUnavailableError() {
  final String remedy;
  if (_lockWaitTimedOut) {
    final holder = _lockHolderPidAtDeadline == null
        ? 'process unknown'
        : 'process ${_lockHolderPidAtDeadline}';
    remedy =
        'Stop the holder ($holder), raise `--@rules_dart//dart:jit_snapshot_lock_timeout` '
        'above $_lockDeadlineSecs, or pass ';
  } else {
    remedy = _constantLockUnavailable
        ? 'Have its owner run `chmod 0666 $constantTrainLock` or remove it, or pass '
        : 'Remove the entry, or pass ';
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
/// `exit` is not called in here: it would skip the cleanup.
int _trainInScratch({
  required String dart,
  required String? dartvm,
  required List<String> dartArgs,
  required bool enableAsserts,
  required bool fallbackAllowed,
  required Map<String, String> env,
  required List<_Pair> copies,
  required List<_Pair> trees,
  required File out,
}) {
  out.parent.createSync(recursive: true);
  final constant = Platform.isWindows ? null : _acquireConstantDir();
  if (constant != null) {
    final trainDir = constant.dir;
    final exitCode = _runTraining(
      trainDir: trainDir,
      dart: dart,
      dartvm: dartvm,
      dartArgs: dartArgs,
      enableAsserts: enableAsserts,
      env: env,
      copies: copies,
      trees: trees,
      out: out,
    );
    // The constant directory holds only what this training put there, but it
    // is shared by path: delete it only when it is still a real directory,
    // never when it became a link, and before releasing the lock, also on
    // failure (see [_acquireConstantDir]).
    try {
      if (!FileSystemEntity.isLinkSync(constantTrainDir) &&
          trainDir.existsSync()) {
        trainDir.deleteSync(recursive: true);
      }
    } on FileSystemException {
      // Ignore cleanup errors.
    }
    _releaseConstantLock(constant.lock);
    return exitCode;
  }
  if (!Platform.isWindows && !fallbackAllowed) {
    _writeUnavailableError();
    return 1;
  }
  _warnFallback();
  final scratch = out.parent.createTempSync('rules_dart_snapshot.');
  final trainDir = Directory('${scratch.path}/t')..createSync();
  try {
    return _runTraining(
      trainDir: trainDir,
      dart: dart,
      dartvm: dartvm,
      dartArgs: dartArgs,
      enableAsserts: enableAsserts,
      env: env,
      copies: copies,
      trees: trees,
      out: out,
    );
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

/// Stages the training inputs under [trainDir], runs the training there, and
/// copies the snapshot it writes to [out]. Returns the training run's exit
/// code.
///
/// [dart] and [dartvm] name the SDK binaries to train with; both are copied
/// into the training directory (see below), so no shared fixed path is read
/// or executed.
int _runTraining({
  required Directory trainDir,
  required String dart,
  required String? dartvm,
  required List<String> dartArgs,
  required bool enableAsserts,
  required Map<String, String> env,
  required List<_Pair> copies,
  required List<_Pair> trees,
  required File out,
}) {
  // The training VM is a copy inside the training directory, and the copy
  // is deleted with it, leaving no undeclared output beside the snapshot.
  // At the constant path the copy reads the same on every build; in the
  // fallback the directory is private to the action's outputs, so no other
  // user can plant or replace the binary between the copy and the run.
  final exeExt = dart.endsWith('.exe') ? '.exe' : '';
  final bin = Directory('${trainDir.path}/vm/bin')..createSync(recursive: true);
  _installCopy(dart, '${bin.path}/dart$exeExt');
  final effectiveDartvm = dartvm ?? _adjacentDartvm(dart, exeExt);
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
  for (final c in copies) {
    _copyFile(c.value, '${trainDir.path}/${c.key}');
  }
  for (final t in trees) {
    _copyTree(t.value, '${trainDir.path}/${t.key}');
  }
  // No `--packages` value is passed, and no package config is staged. The
  // value would resolve against the working directory and intern
  // build-specific strings (see the header comment). The training input is
  // a kernel file whose library URIs are already resolved, so loading
  // needs no package map; a runtime `package:` import would resolve by
  // walking up from the training directory, where no package config lives.
  final stagedEnv = absoluteHomeEnv(env, trainDir);
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
      if (enableAsserts) '--enable-asserts',
      '--snapshot-kind=app-jit',
      '--snapshot=${trainDir.path}/snapshot.jit',
      ...stageTrainingArgs(
        dartArgs,
        trainDir,
        stagedFiles: {for (final c in copies) c.key},
        stagedTrees: [for (final t in trees) t.key],
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

/// Compiles a pre-built kernel `.dill` to an AOT snapshot (`--mode=aot-snapshot`)
/// or self-contained AOT executable (`--mode=exe`) without invoking `dartdev`.
///
/// `dart compile exe` runs through `dartdev`, which walks ancestor directories
/// up to `/` probing `pubspec.yaml` and `.dart_tool/package_config.json` (for
/// native-asset hook discovery) and spawns `/usr/bin/chmod` via `PATH`. Driving
/// `gen_snapshot --deterministic` directly and writing a fresh executable from
/// `dartaotruntime` plus the ELF snapshot (marking it `0755` via libc `chmod`)
/// keeps the compile strictly hermetic inside the action sandbox, even when
/// inputs are staged read-only and no shell or coreutils exist.
void _runAot(List<String> argv) {
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

  for (var i = 0; i < argv.length; i++) {
    final arg = argv[i];
    if (arg == '--enable-asserts') {
      enableAsserts = true;
    } else if (arg == '--verbosity=error') {
      // Ignored: gen_snapshot is silent on success.
    } else if (arg.startsWith('--dart=')) {
      dart = arg.substring('--dart='.length);
    } else if (arg.startsWith('--mode=')) {
      mode = arg.substring('--mode='.length);
    } else if (arg.startsWith('--recorded-uses=')) {
      recordedUses = arg.substring('--recorded-uses='.length);
    } else if (arg.startsWith('--gen-snapshot=')) {
      customGenSnapshot = arg.substring('--gen-snapshot='.length);
    } else if (arg == '--gen-snapshot') {
      customGenSnapshot = argv[++i];
    } else if (arg.startsWith('--dartaotruntime=')) {
      customDartaotruntime = arg.substring('--dartaotruntime='.length);
    } else if (arg == '--dartaotruntime') {
      customDartaotruntime = argv[++i];
    } else if (arg.startsWith('--target-os=')) {
      targetOs = arg.substring('--target-os='.length);
    } else if (arg == '--target-os') {
      targetOs = argv[++i];
    } else if (arg.startsWith('--target-arch=')) {
      targetArch = arg.substring('--target-arch='.length);
    } else if (arg == '--target-arch') {
      targetArch = argv[++i];
    } else if (arg.startsWith('--extra-gen-snapshot-options=')) {
      final opts = arg.substring('--extra-gen-snapshot-options='.length);
      for (final opt in opts.split(',')) {
        if (opt.isNotEmpty) extraGenSnapshotOptions.add(opt);
      }
    } else if (arg == '-o') {
      outputPath = argv[++i];
    } else if (arg.startsWith('-o=')) {
      outputPath = arg.substring('-o='.length);
    } else if (!arg.startsWith('-')) {
      dillPath = arg;
    } else {
      stderr.writeln('app_jit_snapshot --aot: unknown argument $arg');
      exit(64);
    }
  }

  if (dart == null || mode == null || outputPath == null || dillPath == null) {
    stderr.writeln(
      'app_jit_snapshot --aot: --dart, --mode, -o, and input dill are required',
    );
    exit(64);
  }

  final isCross =
      (targetOs != null && targetOs.isNotEmpty) ||
      (targetArch != null && targetArch.isNotEmpty);
  if (isCross) {
    if (customGenSnapshot == null || customGenSnapshot.isEmpty) {
      stderr.writeln(
        'app_jit_snapshot --aot: cross-compilation to $targetOs-$targetArch '
        'requires --gen-snapshot',
      );
      exit(64);
    }
    if (mode == 'exe' &&
        (customDartaotruntime == null || customDartaotruntime.isEmpty)) {
      stderr.writeln(
        'app_jit_snapshot --aot: cross-compiling exe to $targetOs-$targetArch '
        'requires --dartaotruntime',
      );
      exit(64);
    }
  }

  final sdkBin = File(dart).parent.path;
  final hostExeExt = dart.endsWith('.exe') ? '.exe' : '';
  final hostDartaotruntime = '$sdkBin/dartaotruntime$hostExeExt';
  final targetDartaotruntime = customDartaotruntime ?? hostDartaotruntime;
  final genSnapshot =
      customGenSnapshot ?? '$sdkBin/utils/gen_snapshot$hostExeExt';

  // On non-ELF targets (e.g. native macOS Mach-O executables or Windows) or
  // jit-snapshot fallback on Windows, delegate to `dart compile` with a fresh
  // temporary HOME directory. Cross-compilation targets are always ELF and
  // never delegate to `dartdev`.
  if (!isCross &&
      (mode == 'jit-snapshot' ||
          dart.endsWith('.exe') ||
          (mode == 'exe' && !_isElfFile(File(targetDartaotruntime))))) {
    final compileArgs = <String>[
      'compile',
      mode,
      if (mode == 'exe' || mode == 'aot-snapshot') '--verbosity=error',
      if (enableAsserts) '--enable-asserts',
      if (recordedUses != null) '--recorded-uses=$recordedUses',
      for (final opt in extraGenSnapshotOptions)
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
    return;
  }

  final scratchBase = File(outputPath).parent..createSync(recursive: true);
  final tmpDir = scratchBase.createTempSync('rules_dart_aot.');
  final homeDir = Directory('${tmpDir.path}/home')..createSync(recursive: true);
  final homeEnv = buildChildEnvironment(
    homeDir: homeDir.path,
    parentEnv: Platform.environment,
    isWindows: Platform.isWindows,
  );
  var failureExitCode = 0;
  try {
    var activeDill = dillPath;
    if (recordedUses != null) {
      final productPlatform =
          '$sdkBin/../lib/_internal/vm_platform_product.dill';
      final strongPlatform = '$sdkBin/../lib/_internal/vm_platform_strong.dill';
      final platformDill = File(productPlatform).existsSync()
          ? productPlatform
          : strongPlatform;
      final recordedDill = '${tmpDir.path}/recorded.dill';
      final gkRes = Process.runSync(
        hostDartaotruntime,
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
          if (enableAsserts) '--enable-asserts',
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
        failureExitCode = gkRes.exitCode;
        return;
      }
      activeDill = recordedDill;
    }

    final elfPath = mode == 'aot-snapshot'
        ? outputPath
        : '${tmpDir.path}/snapshot.elf';
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
      failureExitCode = gsRes.exitCode;
      return;
    }

    if (mode == 'exe') {
      writeAppAotElfExe(
        dartaotruntime: File(targetDartaotruntime),
        snapshotElf: File(elfPath),
        output: File(outputPath),
      );
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
  if (failureExitCode != 0) {
    exit(failureExitCode);
  }
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
typedef _StatxNative = ffi.Int Function(
  ffi.Int,
  ffi.Pointer<ffi.Uint8>,
  ffi.Int,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint8>,
);
typedef _StatxDart = int Function(
  int,
  ffi.Pointer<ffi.Uint8>,
  int,
  int,
  ffi.Pointer<ffi.Uint8>,
);
typedef _LstatNative = ffi.Int Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
);
typedef _LstatDart = int Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
);
typedef _GeteuidNative = ffi.Uint32 Function();
typedef _GeteuidDart = int Function();
typedef _OpenNative = ffi.Int Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Int,
  ffi.VarArgs<(ffi.Int,)>,
);
typedef _OpenDart = int Function(ffi.Pointer<ffi.Uint8>, int, int);
typedef _CloseNative = ffi.Int Function(ffi.Int);
typedef _CloseDart = int Function(int);
typedef _FcntlGetlkNative = ffi.Int Function(
  ffi.Int,
  ffi.Int,
  ffi.VarArgs<(ffi.Pointer<ffi.Uint8>,)>,
);
typedef _FcntlGetlkDart = int Function(int, int, ffi.Pointer<ffi.Uint8>);

/// The PID holding an exclusive `fcntl` lock on [path], for the lock-wait
/// notices and the deadline error. Null where no process holds one, where the
/// path cannot be opened, or where the platform has no suitable call: the
/// callers then say "unknown".
///
/// Queries with `fcntl(2)` `F_GETLK` for a conflicting write lock over the
/// whole file: the kernel reports the lock the training's own try-lock
/// refuses, with the holder's PID. `fcntl` is variadic
/// (`int fcntl(int, int, ...)`), so its `struct flock` pointer binds through
/// `ffi.VarArgs`: a fixed binding passes the pointer in a register that
/// `fcntl` never reads on Apple arm64, and the lookup reports "unknown".
/// The `struct flock` layout differs by OS:
/// on Linux the type is a little-endian i16 at offset 0 and the PID a
/// little-endian i32 at offset 20+4, on macOS the start/len are two i64 at
/// offsets 0/8, the PID an i32 at offset 16 and the type an i16 at offset 20.
/// All supported hosts are little-endian. Metadata only: the file is opened
/// read-only and never read.
int? _lockHolderPid(String path) {
  if (Platform.isWindows) return null;
  try {
    final lib = ffi.DynamicLibrary.process();
    final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
    final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
    final open = lib.lookupFunction<_OpenNative, _OpenDart>('open');
    final close = lib.lookupFunction<_CloseNative, _CloseDart>('close');
    final fcntl = lib.lookupFunction<_FcntlGetlkNative, _FcntlGetlkDart>(
      'fcntl',
    );
    final pathPtr = _toCString(malloc, path);
    try {
      final buf = malloc(32);
      if (buf == ffi.nullptr) return null;
      try {
        buf.asTypedList(32).fillRange(0, 32, 0);
        // `open` is variadic (`int open(const char *, int, ...)`): the mode
        // slot is passed explicitly so the call marshals as variadic. The
        // flags open read-only without `O_CREAT`, so the kernel ignores it.
        final fd = open(pathPtr, 0, 0);
        if (fd < 0) return null;
        try {
          final view = ByteData.sublistView(buf.asTypedList(32));
          final int cmd;
          if (Platform.isMacOS) {
            view.setInt16(20, 1, Endian.little);
            cmd = 7;
          } else {
            view.setInt16(0, 1, Endian.little);
            cmd = 5;
          }
          if (fcntl(fd, cmd, buf) != 0) return null;
          final type = Platform.isMacOS
              ? view.getInt16(20, Endian.little)
              : view.getInt16(0, Endian.little);
          if (type == 2) return null;
          final holderPid = Platform.isMacOS
              ? view.getInt32(16, Endian.little)
              : view.getInt32(24, Endian.little);
          return holderPid > 0 ? holderPid : null;
        } finally {
          close(fd);
        }
      } finally {
        free(buf);
      }
    } finally {
      free(pathPtr);
    }
  } on ArgumentError {
    // A libc call this host lacks (`fcntl`, `open`): no holder available.
    return null;
  }
}

/// Allocates a zero-terminated UTF-8 copy of [path] with libc `malloc`.
/// The caller frees it with libc `free`.
ffi.Pointer<ffi.Uint8> _toCString(
  ffi.Pointer<ffi.Uint8> Function(int) malloc,
  String path,
) {
  final bytes = utf8.encode(path);
  final ptr = malloc(bytes.length + 1);
  if (ptr == ffi.nullptr) {
    throw FileSystemException('malloc failed', path);
  }
  ptr.asTypedList(bytes.length + 1)
    ..setAll(0, bytes)
    ..[bytes.length] = 0;
  return ptr;
}

int _u32le(List<int> bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

int _u16le(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

/// Names a POSIX file-type bit pattern for the fail-closed error.
String _entryKind(int mode) {
  switch (mode & 0xf000) {
    case 0x4000:
      return 'directory';
    case 0x8000:
      return 'regular file';
    case 0xa000:
      return 'symlink';
    case 0x1000:
      return 'FIFO';
    case 0xc000:
      return 'socket';
    case 0x2000:
      return 'character device';
    case 0x6000:
      return 'block device';
    default:
      return 'entry of unknown type';
  }
}

/// Stats [path] without following symlinks, returning its kind (see
/// [_entryKind]) and its owner uid for the fail-closed error. Null when the
/// entry cannot be statted or the platform has no suitable call.
///
/// On Linux this is `statx(2)`, whose `struct statx` layout is the same on
/// every architecture (the uid is a little-endian u32 at offset 20, the mode
/// a little-endian u16 at offset 28); on macOS it is `lstat(2)` with the
/// 64-bit `struct stat` layout (the mode at offset 4, the uid at offset 16).
/// All supported hosts are little-endian. Metadata only: the entry's content
/// is never read.
({String kind, int uid})? _statEntry(String path) {
  if (Platform.isWindows) return null;
  try {
    final lib = ffi.DynamicLibrary.process();
    final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
    final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
    final pathPtr = _toCString(malloc, path);
    try {
      final buf = malloc(256);
      if (buf == ffi.nullptr) return null;
      try {
        buf.asTypedList(256).fillRange(0, 256, 0);
        if (Platform.isLinux) {
          final statx = lib.lookupFunction<_StatxNative, _StatxDart>('statx');
          const atFdcwd = -100;
          const nofollow = 0x100;
          const basicStats = 0x7ff;
          if (statx(atFdcwd, pathPtr, nofollow, basicStats, buf) != 0) {
            return null;
          }
          final bytes = buf.asTypedList(64);
          return (kind: _entryKind(_u16le(bytes, 28)), uid: _u32le(bytes, 20));
        }
        if (Platform.isMacOS) {
          final lstat = lib.lookupFunction<_LstatNative, _LstatDart>('lstat');
          if (lstat(pathPtr, buf) != 0) return null;
          final bytes = buf.asTypedList(64);
          return (kind: _entryKind(_u16le(bytes, 4)), uid: _u32le(bytes, 16));
        }
        return null;
      } finally {
        free(buf);
      }
    } finally {
      free(pathPtr);
    }
  } on ArgumentError {
    // The stat call is missing from this libc: no description available.
    return null;
  }
}

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
    for (final ref in scanAllDirectiveUris(content)) {
      final uri = ref.uri;
      // A URI spanning lines is refused however it spells its target: the
      // front end's multi-line first-line rule reads a different file than
      // the resolvers below see (see [hasLineBreak]).
      if (hasLineBreak(uri)) {
        errors.add(
          "app_jit_snapshot: $path ${ref.kind} '$uri' is not a declared input.",
        );
        continue;
      }
      // The resolvers below skip empty segments, but the front end resolves
      // some such spellings absolutely: refuse them before resolving.
      if (hasEmptyPathSegment(uri)) {
        errors.add(
          "app_jit_snapshot: $path ${ref.kind} '$uri' is not a declared input.",
        );
        continue;
      }
      if (uri.startsWith(defaultMultiRootPrefix) || uri.startsWith('dart:')) {
        continue;
      }
      if (uri.startsWith('package:')) {
        if (isEscapingPackageUri(uri)) {
          errors.add(
            "app_jit_snapshot: $path ${ref.kind} '$uri' "
            'is not a declared input.',
          );
        }
        continue;
      }
      if (isFileSchemeDirectiveUri(uri) || isDisallowedDirectiveUri(uri)) {
        errors.add(
          "app_jit_snapshot: $path ${ref.kind} '$uri' is not a declared input.",
        );
        continue;
      }
      final target = resolveStagedRelativeTarget(uri, from);
      // A null filesystem-path resolution is not acceptance: the key-space
      // lookup below gets its say, and a null there refuses the directive.
      if (target != null && declared.contains(target)) continue;
      final keyTarget = _resolveKeyRelativeTarget(uri, fromKey);
      if (keyTarget != null && declaredKeys.contains(keyTarget)) continue;
      errors.add(
        "app_jit_snapshot: $path ${ref.kind} '$uri' is not a declared input.",
      );
    }
  }
  return errors;
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

/// The kernel component-file magic, read big-endian as the modular kernel
/// planner reads it (`Tag.ComponentFile` in `dill_outline.dart`, which this
/// file cannot import: it runs from source in the `gen_kernel` action where
/// only this file is staged).
const _gkComponentMagic = 0x90ABCDEF;

/// The byte ranges of the kernel components in [data]: a single range for one
/// component, or one range per appended component. Null when [data] is not a
/// well-formed kernel file. Copied from the modular kernel planner
/// (`_componentRanges` in `kernel_module.dart`) so the whole-program
/// read-set check below parses exactly what the modular one parses; every
/// offset is bounds-checked, so malformed bytes fail instead of misreading.
List<(int, int)>? _gkComponentRanges(Uint8List data) {
  if (data.length < 48) return null;
  final bd = ByteData.sublistView(data);
  if (bd.getUint32(0) != _gkComponentMagic) return null;
  final lastSize = bd.getUint32(data.length - 4);
  if (lastSize == data.length) return [(0, data.length)];
  final ranges = <(int, int)>[];
  var end = data.length;
  while (end >= 48) {
    final compSize = bd.getUint32(end - 4);
    if (compSize < 48 || compSize > end) return null;
    final start = end - compSize;
    if (bd.getUint32(start) != _gkComponentMagic) return null;
    ranges.add((start, end));
    end = start;
  }
  if (end != 0 || ranges.isEmpty) return null;
  return ranges.reversed.toList();
}

/// Adds the `fileUri` of every source in the one kernel component [part] to
/// [uris] — and, when [importUris] is given, the `importUri` recorded
/// alongside it. Returns false (leaving [uris] short) when [part] is not a
/// well-formed component. Copied from the modular kernel planner
/// (`_collectComponentSourceUris` in `kernel_module.dart`): the source-table
/// entry layout (`uri`, `sourceCode`, `lineStarts`, `importUri`,
/// `constantCoverageConstructors`) is stable across SDKs, so the table is
/// parsed structurally with no version gate, and every offset and length is
/// bounds-checked against the table.
bool _gkCollectComponentSourceUris(
  Uint8List part,
  List<String> uris, [
  List<String>? importUris,
]) {
  if (part.length < 12) return false;
  final bd = ByteData.sublistView(part);
  if (bd.getUint32(0) != _gkComponentMagic) return false;
  final libCount = bd.getUint32(part.length - 8);
  final idxBytes = (libCount + 12) * 4;
  if (idxBytes > part.length) return false;
  final rawIdxStart = part.length - idxBytes;
  int u32(int offset) => bd.getUint32(offset);
  final offSourceTable = u32(rawIdxStart);
  final offConstantTable = u32(rawIdxStart + 4);
  if (offSourceTable + 4 > offConstantTable || offConstantTable > rawIdxStart) {
    return false;
  }
  var pos = offSourceTable + 4;
  int? readU30() {
    if (pos >= offConstantTable) return null;
    final b0 = part[pos++];
    if ((b0 & 0x80) == 0) return b0;
    if ((b0 & 0x40) == 0) {
      if (pos >= offConstantTable) return null;
      return ((b0 & 0x3f) << 8) | part[pos++];
    }
    if (pos + 3 > offConstantTable) return null;
    final value =
        ((b0 & 0x3f) << 24) |
        (part[pos] << 16) |
        (part[pos + 1] << 8) |
        part[pos + 2];
    pos += 3;
    return value;
  }

  bool skipBytes(int n) {
    if (n < 0 || pos + n > offConstantTable) return false;
    pos += n;
    return true;
  }

  final numSources = u32(offSourceTable);
  for (var i = 0; i < numSources; i++) {
    // 1. uri: UInt30 byteLength + UTF-8 bytes.
    final uriLen = readU30();
    if (uriLen == null || uriLen < 0 || pos + uriLen > offConstantTable) {
      return false;
    }
    String uri;
    try {
      uri = utf8.decode(part.sublist(pos, pos + uriLen));
    } catch (_) {
      return false;
    }
    pos += uriLen;
    uris.add(uri);
    // 2. sourceCode: UInt30 byteLength + UTF-8 bytes.
    final srcLen = readU30();
    if (srcLen == null || !skipBytes(srcLen)) return false;
    // 3. lineStarts: UInt30 count + count * UInt30 delta.
    final lineCount = readU30();
    if (lineCount == null) return false;
    for (var j = 0; j < lineCount; j++) {
      if (readU30() == null) return false;
    }
    // 4. importUri: UInt30 byteLength + UTF-8 bytes.
    final impLen = readU30();
    if (impLen == null || impLen < 0 || pos + impLen > offConstantTable) {
      return false;
    }
    if (importUris != null) {
      try {
        importUris.add(utf8.decode(part.sublist(pos, pos + impLen)));
      } catch (_) {
        return false;
      }
    }
    pos += impLen;
    // 5. constantCoverageConstructors: UInt30 count + count * UInt30.
    final covCount = readU30();
    if (covCount == null) return false;
    for (var j = 0; j < covCount; j++) {
      if (readU30() == null) return false;
    }
  }
  return true;
}

/// The `fileUri` of every source recorded in the kernel component(s) in [data]
/// — the files the compile actually read — or null when [data] is not a
/// well-formed kernel file.
List<String>? genKernelDillSourceUris(Uint8List data) {
  final ranges = _gkComponentRanges(data);
  if (ranges == null) return null;
  final uris = <String>[];
  for (final (start, end) in ranges) {
    if (!_gkCollectComponentSourceUris(
      Uint8List.sublistView(data, start, end),
      uris,
    )) {
      return null;
    }
  }
  return uris;
}

/// One library node of a kernel component: the source-table entry it was read
/// from, and the names it is linked under. A `null` [fileUri] or [importUri]
/// means the node's source index names no table entry; an empty
/// [canonicalName] means the node has no canonical-name reference.
typedef GenKernelLibraryReference = ({
  int fileUriIndex,
  String? fileUri,
  String? importUri,
  String canonicalName,
});

/// The name tables of one kernel component: its source-table URIs plus the
/// string table and canonical-name table its library references link through.
/// Null when the component's tables do not parse; every offset and length is
/// bounds-checked. Copied from the modular kernel planner
/// (`_componentNameTables` in `kernel_module.dart`).
({
  List<String> fileUris,
  List<String> importUris,
  String? Function(int) stringAt,
  List<int> canonParents,
  List<int> canonStrings,
})?
_gkComponentNameTables(Uint8List part) {
  if (part.length < 12) return null;
  final bd = ByteData.sublistView(part);
  if (bd.getUint32(0) != _gkComponentMagic) return null;
  final libCount = bd.getUint32(part.length - 8);
  // No library nodes means no library references: the source-table verdict
  // stands alone, and the remaining tables are never touched.
  if (libCount == 0) {
    return (
      fileUris: <String>[],
      importUris: <String>[],
      stringAt: (int index) => null,
      canonParents: <int>[],
      canonStrings: <int>[],
    );
  }
  final idxBytes = (libCount + 12) * 4;
  if (idxBytes > part.length) return null;
  final rawIdxStart = part.length - idxBytes;
  int u32(int offset) => bd.getUint32(offset);
  final offSourceTable = u32(rawIdxStart);
  final offLinkTable = u32(rawIdxStart + 12);
  final offStringTable = u32(rawIdxStart + 24);
  if (offSourceTable + 4 > part.length ||
      offLinkTable > rawIdxStart ||
      offStringTable > rawIdxStart ||
      offLinkTable > offStringTable) {
    return null;
  }
  final fileUris = <String>[];
  final importUris = <String>[];
  if (!_gkCollectComponentSourceUris(part, fileUris, importUris)) return null;

  // The string table: a count, cumulative end offsets, then the bytes.
  var pos = offStringTable;
  int? readU30(int limit) {
    if (pos >= limit) return null;
    final b0 = part[pos++];
    if ((b0 & 0x80) == 0) return b0;
    if ((b0 & 0x40) == 0) {
      if (pos >= limit) return null;
      return ((b0 & 0x3f) << 8) | part[pos++];
    }
    if (pos + 3 > limit) return null;
    final value =
        ((b0 & 0x3f) << 24) |
        (part[pos] << 16) |
        (part[pos + 1] << 8) |
        part[pos + 2];
    pos += 3;
    return value;
  }

  final strCount = readU30(rawIdxStart);
  if (strCount == null || strCount < 0) return null;
  final strEnds = <int>[];
  var prevEnd = 0;
  for (var i = 0; i < strCount; i++) {
    final end = readU30(rawIdxStart);
    if (end == null || end < prevEnd) return null;
    strEnds.add(end);
    prevEnd = end;
  }
  final strBase = pos;
  if (strEnds.isNotEmpty && strBase + strEnds.last > rawIdxStart) return null;
  String? stringAt(int index) {
    if (index < 0 || index >= strEnds.length) return null;
    final start = index == 0 ? 0 : strEnds[index - 1];
    try {
      return utf8.decode(
        part.sublist(strBase + start, strBase + strEnds[index]),
      );
    } catch (_) {
      return null;
    }
  }

  // The canonical-name table: a count of (parent, name-string) pairs, with
  // the parent biased by one (zero names the nameless root).
  pos = offLinkTable;
  final canonCount = readU30(offStringTable);
  if (canonCount == null || canonCount < 0) return null;
  final canonParents = <int>[];
  final canonStrings = <int>[];
  for (var i = 0; i < canonCount; i++) {
    final parent = readU30(offStringTable);
    final name = readU30(offStringTable);
    if (parent == null || name == null) return null;
    canonParents.add(parent);
    canonStrings.add(name);
  }
  return (
    fileUris: fileUris,
    importUris: importUris,
    stringAt: stringAt,
    canonParents: canonParents,
    canonStrings: canonStrings,
  );
}

/// Adds one [GenKernelLibraryReference] per library node of the one kernel
/// component [part] to [refs]. Returns false (leaving [refs] short) when the
/// component's tables do not parse; every offset and length is bounds-checked.
/// Copied from the modular kernel planner (`_collectComponentLibraries` in
/// `kernel_module.dart`): each node header opens with a flags byte, the
/// version, and three references — canonical name (biased), name string,
/// source-table file URI — after which only that prefix has been consumed.
bool _gkCollectComponentLibraries(
  Uint8List part,
  List<GenKernelLibraryReference> refs,
) {
  final tables = _gkComponentNameTables(part);
  if (tables == null) return false;
  final (:fileUris, :importUris, :stringAt, :canonParents, :canonStrings) =
      tables;
  final canonCount = canonParents.length;
  String canonicalRoot(int biased) {
    var index = biased - 1;
    if (biased <= 0 || index >= canonCount) return '';
    var guard = canonCount + 1;
    while (canonParents[index] != 0) {
      if (guard-- <= 0) return '';
      index = canonParents[index] - 1;
      if (index < 0 || index >= canonCount) return '';
    }
    return stringAt(canonStrings[index]) ?? '';
  }

  if (part.length < 12) return false;
  final bd = ByteData.sublistView(part);
  final libCount = bd.getUint32(part.length - 8);
  // No library nodes means no library references: the source-table verdict
  // stands alone, and the remaining tables are never touched.
  if (libCount == 0) return true;
  final idxBytes = (libCount + 12) * 4;
  if (idxBytes > part.length) return false;
  final rawIdxStart = part.length - idxBytes;
  int u32(int offset) => bd.getUint32(offset);
  var pos = 0;
  int? readU30(int limit) {
    if (pos >= limit) return null;
    final b0 = part[pos++];
    if ((b0 & 0x80) == 0) return b0;
    if ((b0 & 0x40) == 0) {
      if (pos >= limit) return null;
      return ((b0 & 0x3f) << 8) | part[pos++];
    }
    if (pos + 3 > limit) return null;
    final value =
        ((b0 & 0x3f) << 24) |
        (part[pos] << 16) |
        (part[pos + 1] << 8) |
        part[pos + 2];
    pos += 3;
    return value;
  }

  for (var i = 0; i < libCount; i++) {
    final libStart = u32(rawIdxStart + 36 + i * 4);
    final libEnd = u32(rawIdxStart + 36 + (i + 1) * 4);
    if (libEnd < libStart || libStart > part.length || libEnd > part.length) {
      return false;
    }
    pos = libStart;
    int? readNodeU30() => readU30(libEnd);
    // Flags.
    if (pos >= libEnd) return false;
    pos++;
    if (readNodeU30() == null) return false; // Major version.
    if (readNodeU30() == null) return false; // Minor version.
    final canon = readNodeU30();
    if (canon == null) return false;
    if (readNodeU30() == null) return false; // Name string reference.
    final fileUriIndex = readNodeU30();
    if (fileUriIndex == null) return false;
    final importUri = fileUriIndex >= 0 && fileUriIndex < importUris.length
        ? importUris[fileUriIndex]
        : null;
    refs.add((
      fileUriIndex: fileUriIndex,
      fileUri: fileUriIndex >= 0 && fileUriIndex < fileUris.length
          ? fileUris[fileUriIndex]
          : null,
      importUri: importUri == null || importUri.isEmpty ? null : importUri,
      canonicalName: canonicalRoot(canon),
    ));
  }
  return true;
}

/// The library references of the kernel component(s) in [data] — one record
/// per library node, holding its source-table index with that entry's
/// `fileUri`/`importUri` spellings, and its canonical name's root string.
/// Null when [data] is not a well-formed kernel file, or when its string,
/// link, or library tables do not parse: the caller refuses the compile, since
/// an unreadable table may carry references nobody verified.
List<GenKernelLibraryReference>? genKernelDillLibraryReferences(
  Uint8List data,
) {
  final ranges = _gkComponentRanges(data);
  if (ranges == null) return null;
  final refs = <GenKernelLibraryReference>[];
  for (final (start, end) in ranges) {
    if (!_gkCollectComponentLibraries(
      Uint8List.sublistView(data, start, end),
      refs,
    )) {
      return null;
    }
  }
  return refs;
}

/// Every top-level canonical-name string (parent index zero) recorded in the
/// kernel component(s) in [data], or `null` when the tables do not parse. A
/// held component can smuggle a root the library nodes never mention, so the
/// read-set check below checks these roots too, not just the library nodes.
List<String>? genKernelDillCanonicalRoots(Uint8List data) {
  final ranges = _gkComponentRanges(data);
  if (ranges == null) return null;
  final roots = <String>[];
  for (final (start, end) in ranges) {
    final tables = _gkComponentNameTables(
      Uint8List.sublistView(data, start, end),
    );
    if (tables == null) return null;
    for (var i = 0; i < tables.canonParents.length; i++) {
      // An unresolvable root string degrades to empty (accepted, like the
      // per-library walk): only a present root the inputs do not define fails.
      if (tables.canonParents[i] == 0) {
        roots.add(tables.stringAt(tables.canonStrings[i]) ?? '');
      }
    }
  }
  return roots;
}

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
  } catch (_) {
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
    String rootKey;
    if (rootUri.startsWith(multiRootPrefix)) {
      rootKey = rootUri
          .substring(multiRootPrefix.length)
          .replaceFirst(RegExp(r'/+$'), '');
    } else if (rootUri.startsWith('file:')) {
      String path;
      try {
        path = Uri.parse(rootUri).toFilePath();
      } catch (_) {
        continue;
      }
      // An empty key names the exec root itself: a valid package root whose
      // `package:` spellings the prefix below still scopes by name.
      rootKey = _gkKeyOfFsPath(path, fsRoots);
    } else if (!rootUri.contains(':')) {
      // A path relative to the config file, per the package-config spec.
      final resolved = _gkResolveRelative(configDir, rootUri);
      // Above the exec root: no declared input lives there.
      if (resolved == '..' || resolved.startsWith('../')) continue;
      rootKey = _gkKeyOfFsPath(resolved, fsRoots);
    } else {
      continue;
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
) {
  // An empty source-table entry names no file, so there is no read to verify.
  if (uri.isEmpty) return null;
  final stripped = _stripPrefix(uri, multiRootPrefix);
  if (stripped != null) {
    return stripped.contains('%')
        ? stripped.split('/').map(decodeUriSegment).join('/')
        : stripped;
  }
  if (uri.startsWith('dart:') ||
      uri.startsWith('data:') ||
      uri.startsWith('org-dartlang-sdk:') ||
      uri.startsWith('org-dartlang-untranslatable-uri:')) {
    return null;
  }
  if (uri.startsWith('file:')) {
    String path;
    try {
      path = Uri.parse(uri).toFilePath();
    } catch (_) {
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
  return '';
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
bool _isSynthesizedNativeAssetsLibrary(GenKernelLibraryReference library) =>
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
  final dillFile = File(outputPath);
  if (!dillFile.existsSync()) return <String>[];
  Uint8List bytes;
  try {
    bytes = dillFile.readAsBytesSync();
  } on FileSystemException {
    return <String>[
      'app_jit_snapshot: cannot read the kernel output at $outputPath; '
          'refusing the compile.',
    ];
  }
  final errors = <String>[];
  final uris = genKernelDillSourceUris(bytes);
  if (uris == null) {
    return <String>[
      'app_jit_snapshot: cannot read the sources of $outputPath; '
          'refusing the compile.',
    ];
  }
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
  // The import URIs the packages define: every declared key under its
  // multi-root spelling and its `package:` spellings (one per package whose
  // root directory holds the key).
  final depImportUris = <String>{
    for (final key in declaredKeys) ...[
      '$multiRootPrefix$key',
      for (final entry in packageKeyPrefixes.entries)
        if (entry.value.isEmpty ||
            key == entry.value ||
            key.startsWith('${entry.value}/'))
          'package:${entry.key}/${entry.value.isEmpty ? key : key.substring(entry.value.length + 1)}',
    ],
  };
  bool referenceIsDeclared(String? reference) {
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

  // An unparsable library or canonical-name table fails closed like an
  // unparsable source table: the compile produced bytes whose reads cannot be
  // verified. (An empty component is not unparsable: with no library nodes the
  // readers return no references, and the source-table verdict stands alone.)
  final libraries = genKernelDillLibraryReferences(bytes);
  final canonicalRoots = genKernelDillCanonicalRoots(bytes);
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
  for (final library in libraries) {
    // The manifest-synthesized asset library names no file: only its exact
    // shape passes, and only with a manifest.
    if (hasNativeAssetsManifest && _isSynthesizedNativeAssetsLibrary(library)) {
      continue;
    }
    for (final reference in [library.importUri, library.canonicalName]) {
      if (!referenceIsDeclared(reference)) {
        errors.add(
          'app_jit_snapshot: $outputPath references $reference, which no '
          'declared input, `dart:` library, or package defines; refusing '
          'the compile.',
        );
      }
    }
  }
  // A held component can smuggle a root the library nodes never mention, so
  // every top-level canonical name is checked with the same predicate.
  for (final root in canonicalRoots) {
    // The synthesized asset library's canonical name is its own root.
    if (hasNativeAssetsManifest && root == 'vm:ffi:native-assets') {
      continue;
    }
    if (!referenceIsDeclared(root)) {
      errors.add(
        'app_jit_snapshot: $outputPath references $root, which no '
        'declared input, `dart:` library, or package defines; refusing '
        'the compile.',
      );
    }
  }
  return errors;
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
  final rawGenArgs = <String>[];
  final declaredInputSources = <String>[];
  final fsRoots = <String>[];
  String? outputPath;
  var snapshotPatched = false;
  for (var i = 1; i < argv.length; i++) {
    final arg = argv[i];
    // Passed by Starlark when the snapshot at rawGenArgs[0] is the
    // content-keyed patched copy declared by the toolchain. Consumed here and
    // never forwarded to gen_kernel.
    if (arg == '--comma-patched-snapshot') {
      snapshotPatched = true;
      continue;
    }
    if (arg == '--input-source' && i + 1 < argv.length) {
      declaredInputSources.add(argv[++i]);
      continue;
    }
    if (arg.startsWith('--input-source=')) {
      declaredInputSources.add(arg.substring('--input-source='.length));
      continue;
    }
    if (arg == '--input-sources-file' && i + 1 < argv.length) {
      final file = File(argv[++i]);
      if (file.existsSync()) {
        for (final line in file.readAsLinesSync()) {
          if (line.isNotEmpty) declaredInputSources.add(line);
        }
      }
      continue;
    }
    if (arg.startsWith('--input-sources-file=')) {
      final file = File(arg.substring('--input-sources-file='.length));
      if (file.existsSync()) {
        for (final line in file.readAsLinesSync()) {
          if (line.isNotEmpty) declaredInputSources.add(line);
        }
      }
      continue;
    }
    if (arg == '--filesystem-root' && i + 1 < argv.length) {
      fsRoots.add(argv[i + 1]);
    } else if (arg.startsWith('--filesystem-root=')) {
      fsRoots.add(arg.substring('--filesystem-root='.length));
    } else if ((arg == '-o' || arg == '--output') && i + 1 < argv.length) {
      outputPath = argv[i + 1];
    } else if (arg.startsWith('-o=')) {
      outputPath = arg.substring('-o='.length);
    } else if (arg.startsWith('--output=')) {
      outputPath = arg.substring('--output='.length);
    }
    rawGenArgs.add(arg);
  }

  // The gen_kernel snapshot must already be the toolchain's patched copy when
  // a define contains a comma: its Parser._setOption comma-splitting is only
  // tolerable for comma-free defines. Fail loudly instead of miscompiling.
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

  // No declared source may read the host (see
  // [_findDisallowedGenKernelDirectives]). This runs before the isolated-root
  // staging below: a disallowed URI fails however the roots resolve.
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

  // The scratch directories below anchor at the declared output: shared temp
  // is never used, so concurrent actions cannot see each other's files.
  if (outputPath == null) {
    stderr.writeln('app_jit_snapshot --gen-kernel: -o/--output is required');
    exit(64);
  }

  // Only stage an isolated filesystem root when an undeclared file would
  // otherwise shadow a declared input. Each declared source is compared
  // against every root: the candidate naming the declared file itself is its
  // origin, and any other candidate that exists on disk is a shadow. In the
  // common case (no shadows) the declared roots are forwarded unchanged.
  var hasShadowRisk = false;
  if (declaredInputSources.isNotEmpty && fsRoots.isNotEmpty) {
    final normRoots = <String>[
      for (final root in fsRoots)
        _normFsPath(root).replaceFirst(RegExp(r'/+$'), ''),
    ];
    for (final srcPath in declaredInputSources) {
      final normSrc = _normFsPath(srcPath);
      final normKey = _normFsPath(_stripFsRootPrefix(srcPath, fsRoots));
      if (normKey.isEmpty) {
        hasShadowRisk = true;
        break;
      }
      for (final normRoot in normRoots) {
        final candidate = normRoot == '.' || normRoot.isEmpty
            ? normKey
            : '$normRoot/$normKey';
        // The candidate naming the declared file itself is its origin.
        if (candidate == normSrc) continue;
        if (File(candidate).existsSync()) {
          hasShadowRisk = true;
          break;
        }
      }
      if (hasShadowRisk) break;
    }
  }

  Directory? isolatedRootDir;
  final forwarded = <String>[];
  if (declaredInputSources.isNotEmpty && fsRoots.isNotEmpty && hasShadowRisk) {
    final baseDir = File(outputPath).parent;
    baseDir.createSync(recursive: true);
    isolatedRootDir = baseDir.createTempSync('.gen_kernel_root.');
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
  } else {
    forwarded.addAll(rawGenArgs);
  }

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

  // The compile read only what its directives name, and the directive check
  // above refused every hostile spelling it knows — but a spelling it misses
  // would read the host into the output, so the output's own read set is
  // verified against the declared inputs before the action succeeds (see
  // [verifyGenKernelReads]). A dirty read set deletes the output and fails:
  // the kernel must never carry an undeclared file.
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
  final multiRootPrefix = '$scheme:///';
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
// Mirror of `directive_guard.dart` (the shared directive-URI check): the
// prologue scanner, the directive-URI resolution, the disallowed-scheme
// classification and the staged-relative resolution, copied verbatim (names
// included) so this tool classifies exactly what the modular kernel planner
// classifies.
//
// This file runs from source inside the whole-program `gen_kernel` action,
// where only this file is staged: it cannot import the guard library. Keep
// this mirror in sync with `directive_guard.dart`; the scanner diff must stay
// empty apart from this header.

const defaultMultiRootPrefix = 'org-dartlang-root:///';

/// The path after `multiRootPrefix`, or null for any other URI.
String? _stripPrefix(String uri, String multiRootPrefix) {
  if (uri.startsWith(multiRootPrefix)) {
    return uri.substring(multiRootPrefix.length);
  }
  return null;
}

/// The segments of the longest [packageDirs] directory holding `fromKey`, or
/// the empty list when no package holds it (an unpackaged file).
List<String> _packageDirOf(String fromKey, Map<String, String> packageDirs) {
  var best = const <String>[];
  for (final dir in packageDirs.values) {
    if (dir.isEmpty) continue;
    if (fromKey == dir || fromKey.startsWith('$dir/')) {
      final segs = dir.split('/');
      if (segs.length > best.length) best = segs;
    }
  }
  return best;
}

/// Applies the segments of a directive path onto [base]: `.` segments are
/// dropped, each `..` pops while deeper than [floor], and a decoded `/`
/// (`%2F`) names no file, since no file can be read through it. An empty
/// segment names no file either: the front end does not resolve every such
/// spelling the way skipping it would (a `package:` doubled slash resolves
/// absolutely), so the path fails and the caller refuses the directive.
/// Above [floor], `..` either fails ([failAboveFloor], for `package:` URIs,
/// where the front end reports leaving the package) or is dropped (relative
/// and absolute URIs, which the front end clamps to the package directory or
/// the multi-root).
String? _resolveDirectivePath(
  String path,
  List<String> base,
  int floor,
  bool failAboveFloor,
) {
  final stack = base.toList();
  for (final raw in path.split('/')) {
    // An empty segment is not skipped: no caller passes a leading `/`, so one
    // here is a doubled slash the front end resolves differently.
    if (raw.isEmpty) return null;
    final seg = decodeUriSegment(raw);
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (stack.length > floor) {
        stack.removeLast();
      } else if (failAboveFloor) {
        return null;
      }
      continue;
    }
    if (seg.contains('/')) return null;
    stack.add(seg);
  }
  return stack.join('/');
}

/// The key a directive URI (`import`, `export`, `part`, `part of`) in the file
/// named `fromKey` refers to: the key of the file the front end reads.
///
/// `packageDirs` maps each package name to its directory key (`pkg/lib`).
/// [multiRootPrefix] is the scheme the absolute URIs of multi-root files start
/// with (`org-dartlang-root:///`). Null when the URI names no workspace file:
/// an unknown package or scheme, an escape above a `package:` directory, an
/// empty path segment (which the front end resolves differently than skipping
/// it would), a fragment, an authority, or a decoded `/`. A `?...` query is
/// dropped and the path part resolved instead: an empty reference names the
/// importing file itself.
///
/// The resolution mirrors the front end exactly: `\` is a separator everywhere,
/// escapes decode once (either hex case), `/`-absolute URIs resolve against the
/// importer's package directory (unpackaged files against the multi-root), and
/// relative URIs against the importer's directory, clamped so `..` never leaves
/// the package directory.
String? resolveDirectiveUri(
  String uri,
  String fromKey,
  Map<String, String> packageDirs, {
  String multiRootPrefix = defaultMultiRootPrefix,
}) {
  final text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  final absolute = _stripPrefix(text, multiRootPrefix);
  if (absolute != null) {
    return _resolveDirectivePath(absolute, const [], 0, false);
  }
  if (text.startsWith('package:')) {
    final rest = text.substring('package:'.length);
    if (rest.contains('?') || rest.contains('#')) return null;
    final slash = rest.indexOf('/');
    if (slash <= 0) return null;
    final dir = packageDirs[rest.substring(0, slash)];
    if (dir == null) return null;
    final base = dir.isEmpty ? const <String>[] : dir.split('/');
    return _resolveDirectivePath(
      rest.substring(slash + 1),
      base,
      base.length,
      true,
    );
  }
  // A fragment names no file: the front end reports a URI with one instead of
  // reading through it. A query names no file either: the front end reads the
  // file the path part names, so the path part alone is classified and
  // resolved below.
  if (text.contains('#')) return null;
  final query = text.indexOf('?');
  final path = query < 0 ? text : text.substring(0, query);
  if (path.contains(':')) return null;
  if (path.startsWith('//')) return null;
  // An empty reference names the importing file itself (RFC 3986).
  if (path.isEmpty) return fromKey;
  if (path.startsWith('/')) {
    final base = _packageDirOf(fromKey, packageDirs);
    // The one leading `/` marks absoluteness; any further empty segment fails.
    return _resolveDirectivePath(path.substring(1), base, base.length, false);
  }
  final slash = fromKey.lastIndexOf('/');
  final base = slash < 0
      ? const <String>[]
      : fromKey.substring(0, slash).split('/');
  final floor = _packageDirOf(fromKey, packageDirs).length;
  return _resolveDirectivePath(path, base, floor, false);
}

/// One URI-bearing directive of a source's prologue.
class ScanRef {
  const ScanRef(this.kind, this.uri);

  /// `import`, `export`, `part` or `part of`.
  final String kind;

  /// The URI. A configurable import gives the alternative it takes for the VM.
  final String uri;

  bool get isPart => kind == 'part';

  bool get isPartOf => kind == 'part of';
}

/// The directives of a source's prologue.
class ScanResult {
  const ScanResult(this.refs, {this.libraryName, this.partOfLibrary});

  final List<ScanRef> refs;

  /// The name from `library <name>;`, when declared.
  final String? libraryName;

  /// The library name from `part of <name>;`, when a part names its library by
  /// identifier rather than URI.
  final String? partOfLibrary;
}

/// The directives in the prologue of a Dart source, or null when the prologue has a
/// form this scanner does not read.
ScanResult? scanDirectives(String source, Set<String> vmLibraries) {
  try {
    return _Prologue(_Lexer(source), vmLibraries).parse();
  } on _Unparsable {
    return null;
  }
}

class _Unparsable implements Exception {
  const _Unparsable();
}

const _identKind = 0;
const _stringKind = 1;
const _punctKind = 2;
const _otherKind = 3;

class _Token {
  const _Token(this.kind, this.text, {this.raw = false});

  final int kind;
  final String text;
  final bool raw;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    c == 0x5f ||
    c == 0x24 ||
    c >= 0x80;

bool _isIdentChar(int c) => _isIdentStart(c) || _isDigit(c);

int _skipLine(String src, int start) {
  var at = start;
  while (at < src.length && src[at] != '\n' && src[at] != '\r') {
    at++;
  }
  return at;
}

/// The index just past the block comment that starts at `start`. Dart block
/// comments nest.
int _skipBlockComment(String src, int start) {
  var depth = 0;
  var at = start;
  while (at < src.length) {
    if (src.startsWith('/*', at)) {
      depth++;
      at += 2;
    } else if (src.startsWith('*/', at)) {
      depth--;
      at += 2;
      if (depth == 0) return at;
    } else {
      at++;
    }
  }
  throw const _Unparsable();
}

String _unescape(String s) {
  if (!s.contains('\\')) return s;
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final ch = s[i++];
    if (ch != '\\') {
      out.write(ch);
      continue;
    }
    if (i >= s.length) throw const _Unparsable();
    final esc = s[i++];
    switch (esc) {
      case 'n':
        out.write('\n');
      case 'r':
        out.write('\r');
      case 'f':
        out.write('\f');
      case 'b':
        out.write('\b');
      case 't':
        out.write('\t');
      case 'v':
        out.write('\v');
      case 'x':
        if (i + 2 > s.length) throw const _Unparsable();
        final code = int.tryParse(s.substring(i, i + 2), radix: 16);
        if (code == null) throw const _Unparsable();
        out.writeCharCode(code);
        i += 2;
      case 'u':
        if (i < s.length && s[i] == '{') {
          final close = s.indexOf('}', i + 1);
          if (close < 0) throw const _Unparsable();
          final code = int.tryParse(s.substring(i + 1, close), radix: 16);
          if (code == null || code < 0 || code > 0x10FFFF) {
            throw const _Unparsable();
          }
          out.writeCharCode(code);
          i = close + 1;
        } else {
          if (i + 4 > s.length) throw const _Unparsable();
          final code = int.tryParse(s.substring(i, i + 4), radix: 16);
          if (code == null) throw const _Unparsable();
          out.writeCharCode(code);
          i += 4;
        }
      default:
        out.write(esc);
    }
  }
  return out.toString();
}

/// Reads the tokens of a Dart source one at a time, so a scan that stops at the end
/// of the directives never reads the rest of the file.
class _Lexer {
  _Lexer(this._src);

  final String _src;
  var _at = 0;
  _Token? _ahead;

  _Token? peek() => _ahead ??= _scan();

  _Token? take() {
    final token = peek();
    _ahead = null;
    return token;
  }

  _Token? _scan() {
    final src = _src;
    final n = src.length;
    if (_at == 0) {
      if (src.startsWith('\uFEFF')) _at++;
      if (src.startsWith('#!', _at)) {
        _at = _skipLine(src, _at + 2);
      }
    }
    while (_at < n) {
      final ch = src[_at];
      if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        _at++;
        continue;
      }
      if (ch == '/' && _at + 1 < n && src[_at + 1] == '/') {
        _at = _skipLine(src, _at + 2);
        continue;
      }
      if (ch == '/' && _at + 1 < n && src[_at + 1] == '*') {
        _at = _skipBlockComment(src, _at);
        continue;
      }
      final code = ch.codeUnitAt(0);
      if (_isIdentStart(code)) {
        final start = _at;
        while (_at < n && _isIdentChar(src.codeUnitAt(_at))) {
          _at++;
        }
        final word = src.substring(start, _at);
        if (word == 'r' && _at < n && (src[_at] == "'" || src[_at] == '"')) {
          return _string(raw: true);
        }
        return _Token(_identKind, word);
      }
      if (_isDigit(code)) {
        final start = _at;
        while (_at < n && _isIdentChar(src.codeUnitAt(_at))) {
          _at++;
        }
        return _Token(_otherKind, src.substring(start, _at));
      }
      if (ch == "'" || ch == '"') return _string(raw: false);
      _at++;
      return _Token(_punctKind, ch);
    }
    return null;
  }

  /// The string literal at `_at`, with its quotes removed and its escapes kept.
  _Token _string({required bool raw}) {
    final src = _src;
    final quote = src[_at];
    final triple = src.startsWith(quote * 3, _at);
    final delim = triple ? quote * 3 : quote;
    var contentStart = _at + delim.length;
    final endQuote = _skipString(_at, raw: raw);
    final contentEnd = endQuote - delim.length;
    if (triple && contentStart < contentEnd) {
      if (src.startsWith('\r\n', contentStart)) {
        contentStart += 2;
      } else if (src[contentStart] == '\n' || src[contentStart] == '\r') {
        contentStart += 1;
      }
    }
    _at = endQuote;
    return _Token(
      _stringKind,
      src.substring(contentStart, contentEnd),
      raw: raw,
    );
  }

  /// The index just past the string literal that starts at `quoteAt`.
  int _skipString(int quoteAt, {required bool raw}) {
    final src = _src;
    final n = src.length;
    final quote = src[quoteAt];
    final triple = src.startsWith(quote * 3, quoteAt);
    final delim = triple ? quote * 3 : quote;
    var at = quoteAt + delim.length;
    while (true) {
      if (at >= n) throw const _Unparsable();
      if (!raw && src[at] == '\\') {
        if (at + 1 >= n) throw const _Unparsable();
        at += 2;
        continue;
      }
      if (!raw && src.startsWith(r'${', at)) {
        at = _skipInterpolation(at + 2);
        continue;
      }
      if (src.startsWith(delim, at)) {
        return at + delim.length;
      }
      if (!triple && (src[at] == '\n' || src[at] == '\r')) {
        throw const _Unparsable();
      }
      at++;
    }
  }

  /// The index just past the `}` that closes a `${...}` string interpolation
  /// whose body starts at `start`.
  int _skipInterpolation(int start) {
    final src = _src;
    final n = src.length;
    var at = start;
    var depth = 1;
    while (at < n) {
      final ch = src[at];
      if (ch == '/' && at + 1 < n && src[at + 1] == '/') {
        at = _skipLine(src, at + 2);
        continue;
      }
      if (ch == '/' && at + 1 < n && src[at + 1] == '*') {
        at = _skipBlockComment(src, at);
        continue;
      }
      final code = ch.codeUnitAt(0);
      if (_isIdentStart(code) || _isDigit(code)) {
        final wordStart = at;
        while (at < n && _isIdentChar(src.codeUnitAt(at))) {
          at++;
        }
        if (at - wordStart == 1 &&
            src[wordStart] == 'r' &&
            at < n &&
            (src[at] == "'" || src[at] == '"')) {
          at = _skipString(at, raw: true);
        }
        continue;
      }
      if (ch == "'" || ch == '"') {
        at = _skipString(at, raw: false);
        continue;
      }
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return at + 1;
      }
      at++;
    }
    throw const _Unparsable();
  }
}

/// Reads the directive prologue: `library`, `import`, `export`, `part` and `part
/// of`, with the annotations before them. The first other token ends it.
class _Prologue {
  _Prologue(this._lexer, this._vm, {this.collectAll = false});

  final _Lexer _lexer;
  final Set<String> _vm;

  /// When true, every URI of an `import` or `export` directive is collected:
  /// the declared URI and each `if` alternative, without evaluating which one
  /// the configuration selects. Validators without the VM library set use this
  /// so no spelling of a disallowed scheme hides in an unselected branch.
  final bool collectAll;

  _Token? _peek() => _lexer.peek();

  _Token _take() {
    final token = _lexer.take();
    if (token == null) throw const _Unparsable();
    return token;
  }

  bool _is(String text, int kind) {
    final token = _peek();
    return token != null && token.kind == kind && token.text == text;
  }

  bool _ident(String text) => _is(text, _identKind);

  bool _punct(String text) => _is(text, _punctKind);

  void _expect(String text) {
    if (!_punct(text)) throw const _Unparsable();
    _lexer.take();
  }

  /// Consumes up to and including `text`.
  void _skipPast(String text) {
    while (!_punct(text)) {
      _take();
    }
    _lexer.take();
  }

  void _identToken() {
    if (_take().kind != _identKind) throw const _Unparsable();
  }

  /// A dotted identifier such as `foo` or `foo.bar.baz`.
  String _dottedIdent() {
    final first = _take();
    if (first.kind != _identKind) throw const _Unparsable();
    final out = StringBuffer(first.text);
    while (_punct('.')) {
      _lexer.take();
      final next = _take();
      if (next.kind != _identKind) throw const _Unparsable();
      out
        ..write('.')
        ..write(next.text);
    }
    return out.toString();
  }

  /// Adjacent string literals are one URI.
  String _string() {
    final token = _take();
    if (token.kind != _stringKind) throw const _Unparsable();
    final out = StringBuffer(token.raw ? token.text : _unescape(token.text));
    while (_peek()?.kind == _stringKind) {
      final next = _take();
      out.write(next.raw ? next.text : _unescape(next.text));
    }
    return out.toString();
  }

  /// `@name`, `@name.name`, `@name<...>(...)`, or `@name<...>.name(...)`.
  void _annotation() {
    _expect('@');
    _identToken();
    while (_punct('.')) {
      _lexer.take();
      _identToken();
    }
    if (_punct('<')) {
      var depth = 0;
      do {
        final token = _take();
        if (token.kind == _punctKind && token.text == '<') depth++;
        if (token.kind == _punctKind && token.text == '>') depth--;
      } while (depth > 0);
      while (_punct('.')) {
        _lexer.take();
        _identToken();
      }
    }
    if (_punct('(')) {
      var depth = 0;
      do {
        final token = _take();
        if (token.kind == _punctKind && token.text == '(') depth++;
        if (token.kind == _punctKind && token.text == ')') depth--;
      } while (depth > 0);
    }
  }

  /// The `if (...)` test of a configurable import, after its `(`, through its `)`.
  /// True when it holds for the VM. In CFE's configurable-import environment,
  /// available SDK libraries are mapped to `'true'` and all other names are
  /// unspecified (matching only `== ''`).
  bool _condition() {
    final text = _dottedIdent();
    String? value;
    if (_punct('=')) {
      _lexer.take();
      _expect('=');
      value = _string();
    }
    _expect(')');
    const prefix = 'dart.library.';
    if (text.startsWith(prefix)) {
      final present = _vm.contains(text.substring(prefix.length));
      if (!present) return false;
      return value == null || value == 'true';
    }
    return value == '';
  }

  /// `import` or `export` after its keyword: the URI, then any `if`
  /// alternatives, then the rest of the directive, which names nothing to read.
  ScanRef _uriDirective(String kind, List<ScanRef> refs) {
    final declared = _string();
    if (collectAll) refs.add(ScanRef(kind, declared));
    var chosen = declared;
    var picked = false;
    while (_ident('if')) {
      _lexer.take();
      _expect('(');
      final holds = _condition();
      final alternative = _string();
      if (collectAll) refs.add(ScanRef(kind, alternative));
      if (holds && !picked) {
        chosen = alternative;
        picked = true;
      }
    }
    _skipPast(';');
    return ScanRef(kind, chosen);
  }

  ScanResult parse() {
    final refs = <ScanRef>[];
    String? libraryName;
    String? partOfLibrary;
    while (true) {
      final token = _peek();
      if (token == null) break;
      if (token.kind == _punctKind && token.text == '@') {
        _annotation();
        continue;
      }
      if (token.kind != _identKind) break;
      if (token.text == 'library') {
        _lexer.take();
        if (_punct(';')) {
          _lexer.take();
        } else if (_peek()?.kind == _identKind) {
          libraryName ??= _dottedIdent();
          _expect(';');
        } else {
          break;
        }
      } else if (token.text == 'import' || token.text == 'export') {
        _lexer.take();
        if (_peek()?.kind != _stringKind) break;
        final ref = _uriDirective(token.text, refs);
        if (!collectAll) refs.add(ref);
      } else if (token.text == 'part') {
        _lexer.take();
        if (_ident('of')) {
          _lexer.take();
          if (_peek()?.kind == _stringKind) {
            refs.add(ScanRef('part of', _string()));
          } else {
            partOfLibrary ??= _dottedIdent();
          }
          _expect(';');
        } else if (_peek()?.kind == _stringKind) {
          refs.add(ScanRef('part', _string()));
          _expect(';');
        } else {
          break;
        }
      } else {
        break;
      }
    }
    return ScanResult(
      refs,
      libraryName: libraryName,
      partOfLibrary: partOfLibrary,
    );
  }
}

/// Every URI-bearing directive of a source's prologue: each `import` and
/// `export` contributes its declared URI and every `if` alternative, each
/// `part` and `part of` its URI. Conditions are not evaluated, so no VM
/// library set is needed. An empty list when the prologue does not scan (the
/// compiler then reports the genuine syntax error).
List<ScanRef> scanAllDirectiveUris(String source) {
  try {
    return _Prologue(_Lexer(source), const {}, collectAll: true).parse().refs;
  } on _Unparsable {
    return const [];
  }
}

/// The diagnostics for every disallowed-scheme directive URI in `fileContents`
/// (display path to source text), in path order. Empty when clean. Each names
/// the file, the directive and the URI.
List<String> findDisallowedDirectives(
  Map<String, String> fileContents, {
  String tool = 'dart',
  String multiRootPrefix = defaultMultiRootPrefix,
}) {
  final errors = <String>[];
  final paths = fileContents.keys.toList()..sort();
  for (final path in paths) {
    final content = fileContents[path];
    if (content == null) continue;
    for (final ref in scanAllDirectiveUris(content)) {
      // A URI spanning lines is refused however it spells its target: the
      // front end's multi-line first-line rule reads a different file than
      // the resolvers below see (see [hasLineBreak]).
      if (hasLineBreak(ref.uri)) {
        errors.add(
          "$tool: $path ${ref.kind} '${ref.uri}' is not a declared input.",
        );
        continue;
      }
      final disallowed = ref.isPart || ref.isPartOf
          ? isFileSchemeDirectiveUri(ref.uri)
          : isDisallowedDirectiveUri(ref.uri, multiRootPrefix: multiRootPrefix);
      if (disallowed) {
        errors.add(
          "$tool: $path ${ref.kind} '${ref.uri}' is not a declared input.",
        );
      }
    }
  }
  return errors;
}

// BEGIN staged-resolver-mirror: byte-identical in
// dart/guard/lib/directive_guard.dart and
// dart/private/tools/app_jit_snapshot.dart (pinned by
// directive_guard_test.dart). Edit only by syncing both copies.

/// Decodes one raw URI path segment the way the front end does (RFC 3986): each
/// valid `%XX` escape becomes its byte (bytes together decode as UTF-8, either
/// hex case), while anything else — including a lone `%` — stays literal.
/// Decoding happens once: a `%` produced by decoding is never decoded again.
String decodeUriSegment(String segment) {
  if (!segment.contains('%')) return segment;
  final out = StringBuffer();
  final bytes = <int>[];
  void flush() {
    if (bytes.isEmpty) return;
    out.write(utf8.decode(bytes, allowMalformed: true));
    bytes.clear();
  }

  for (var i = 0; i < segment.length; i++) {
    final c = segment.codeUnitAt(i);
    if (c == 0x25 && i + 2 < segment.length) {
      final hex = int.tryParse(segment.substring(i + 1, i + 3), radix: 16);
      if (hex != null && hex >= 0 && hex <= 0xff) {
        bytes.add(hex);
        i += 2;
        continue;
      }
    }
    flush();
    out.writeCharCode(c);
  }
  flush();
  return out.toString();
}

/// Whether [uri] is a `package:` URI whose path climbs above its package
/// directory (`package:pkg/sub/../../x.dart`), has an empty path segment
/// (`package:pkg//x.dart`), or hides a separator in one decoded segment
/// (`package:pkg/..%2F..%2Fx.dart`). The front end reports leaving the
/// package, but a tool that resolves against the real filesystem reads a host
/// file instead, so the staged-source check refuses it before they run. An
/// empty segment is refused too: the front end resolves the doubled slash as
/// an absolute path, so `package:pkg//x.dart` reads the workspace-root file,
/// not the package's, which no empty-skipping resolver reproduces. A decoded
/// `/` or `\` is refused as well: it climbs without counting, and a
/// filesystem resolver may honour it. A query or fragment suffix is dropped
/// before classifying (the front end reads the file the path part names), so
/// an escaping path still escapes with one, while a path that stays inside
/// its package is still false with one. False for any other URI, including a
/// `package:` URI that stays inside its package (an unknown package name
/// fails closed downstream, where the analyzer cannot resolve it, so it is
/// not refused here).
bool isEscapingPackageUri(String uri) {
  if (!uri.startsWith('package:')) return false;
  var rest = uri.substring('package:'.length);
  // A query or fragment names no file: the front end reads the file the path
  // part names, so the path part alone is classified below.
  final hash = rest.indexOf('#');
  if (hash >= 0) rest = rest.substring(0, hash);
  final query = rest.indexOf('?');
  if (query >= 0) rest = rest.substring(0, query);
  final slash = rest.indexOf('/');
  if (slash <= 0) return false;
  final text = rest.substring(slash + 1).replaceAll(r'\', '/');
  var depth = 0;
  for (final raw in text.split('/')) {
    // An empty segment resolves absolutely in the front end, outside the
    // package, so it escapes however the siblings resolve.
    if (raw.isEmpty) return true;
    final seg = decodeUriSegment(raw);
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      depth--;
      if (depth < 0) return true;
    } else if (seg.contains('/') || seg.contains(r'\')) {
      // A decoded separator climbs without counting: a filesystem resolver
      // may honour it, so it escapes however the front end spells it.
      return true;
    } else {
      depth++;
    }
  }
  return false;
}

/// Whether [path] is absolute: POSIX `/`, a Windows drive (`C:/`, `C:\`), or
/// a UNC share (`\\`).
bool _isAbsoluteStagedPath(String path) =>
    path.startsWith('/') ||
    path.startsWith(r'\') ||
    (path.length >= 3 &&
        ((path.codeUnitAt(0) >= 0x41 && path.codeUnitAt(0) <= 0x5a) ||
            (path.codeUnitAt(0) >= 0x61 && path.codeUnitAt(0) <= 0x7a)) &&
        path.codeUnitAt(1) == 0x3a &&
        (path.codeUnitAt(2) == 0x2f || path.codeUnitAt(2) == 0x5c));

bool _isWindowsDriveSegment(String s) =>
    s.length == 2 &&
    ((s.codeUnitAt(0) >= 0x41 && s.codeUnitAt(0) <= 0x5a) ||
        (s.codeUnitAt(0) >= 0x61 && s.codeUnitAt(0) <= 0x7a)) &&
    s.codeUnitAt(1) == 0x3a;

/// [path] as an absolute `/`-separated path: backslashes become separators,
/// a relative path resolves against the current directory, and empty and `.`
/// segments drop out. `..` segments stay (the caller applies them against its
/// own base), except the resolution below, which clamps them at the
/// filesystem root the way the analyzer does.
///
/// Public because tools that stage their own trees compare staged paths the
/// same way the guard does: normalize both sides with this before comparing,
/// so a root passed with a trailing slash or backslashes still matches.
String normalizeStagedPath(String path) {
  final slashed = path.replaceAll(r'\', '/');
  final absolute = _isAbsoluteStagedPath(slashed)
      ? slashed
      : '${Directory.current.path.replaceAll(r'\', '/')}/$slashed';
  final unc = absolute.startsWith('//');
  final parts = <String>[];
  for (final part in absolute.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      // `..` clamps at the filesystem root the way the analyzer clamps it:
      // past `/`, past a drive (`C:`), or past a UNC share's host.
      final floor = unc
          ? (parts.length <= 2 ? parts.length : 2)
          : (parts.isNotEmpty && _isWindowsDriveSegment(parts.first) ? 1 : 0);
      if (parts.length > floor) {
        parts.removeLast();
      }
      continue;
    }
    parts.add(part);
  }
  final joined = parts.join('/');
  if (unc) return '//$joined';
  if (absolute.startsWith('/')) return '/$joined';
  return joined;
}

/// Applies each `/`-separated segment of the relative reference [queue] to
/// the [base] directory stack: `.` and empty segments skip, `..` pops unless
/// already at [floor], anything else appends. Returns the joined path, or null
/// when a decoded segment still holds a `/`, which names no readable file.
String? _applyStagedSegments(List<String> base, int floor, String queue) {
  for (final raw in queue.split('/')) {
    if (raw.isEmpty) continue;
    final seg = decodeUriSegment(raw);
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (base.length > floor) base.removeLast();
      continue;
    }
    if (seg.contains('/')) return null;
    base.add(seg);
  }
  return base.join('/');
}

/// The absolute `/`-separated path a schemeless relative or `/`-absolute
/// directive URI in the staged file [fromPath] refers to, resolved the way the
/// analyzer resolves it on the real filesystem: `\` separates, escapes decode
/// once, a `?...` query is dropped (the front end reads the file the path part
/// names, query or not), and `..` climbs past the staged tree (clamped at the
/// filesystem root, where overshooting names any host path) instead of staying
/// inside the declared inputs.
///
/// An empty reference — `''`, or `'?query'` with no path — names the importing
/// file itself (RFC 3986): a self-import, always declared.
///
/// Null when [uri] is not such a URI: any scheme (`dart:`, `package:`,
/// `file:`, the multi-root scheme, or anything else with a `:`), a fragment
/// (the front end reports a URI with one instead of reading through it), or a
/// `//`-prefixed authority. A decoded `/` also yields null: it names no file,
/// so the compiler reports it and the guard has nothing to confine. Null means
/// "no host file beyond what the scheme check already refuses", never "inside
/// the declared inputs".
String? resolveStagedRelativeTarget(String uri, String fromPath) {
  final text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  // A fragment names no file: the front end reports a URI with one instead of
  // reading through it, whatever path precedes it.
  if (text.contains('#')) return null;
  // A query names no file either: the front end reads the file the path part
  // names, so the path part alone is classified and resolved below. Cutting
  // here also keeps a `:` inside the query from looking like a scheme.
  final query = text.indexOf('?');
  final path = query < 0 ? text : text.substring(0, query);
  if (path.contains(':')) return null;
  if (path.startsWith('//')) return null;
  final from = normalizeStagedPath(fromPath);
  // An empty reference names the importing file itself (RFC 3986).
  if (path.isEmpty) return from;
  final rooted = from.startsWith('/');
  final drive =
      !rooted &&
      from.contains('/') &&
      _isWindowsDriveSegment(from.split('/').first);
  final stack = from.split('/');
  // Drop the file name: the URI resolves against its directory.
  if (stack.isNotEmpty) stack.removeLast();
  final floor = rooted || drive ? 1 : 0;
  final absolute = path.startsWith('/');
  final base = absolute ? stack.sublist(0, floor) : stack;
  final queue = absolute ? path.substring(1) : path;
  final joined = _applyStagedSegments(base, floor, queue);
  if (joined == null) return null;
  // A rooted `from` splits with a leading empty segment, so the join already
  // starts with `/` (or `//` for a UNC share); only fill in a bare `/` when
  // the base ran empty.
  if (rooted) return joined.startsWith('/') ? joined : '/$joined';
  return joined;
}

/// Whether `uri` is a `file:` URI in any spelling: any letter case, any
/// authority (`file://localhost/`), a bare path (`file:x.dart`), backslash
/// separators, or a query or fragment suffix. The front end reads all of these
/// off the host filesystem, outside every multi-root.
bool isFileSchemeDirectiveUri(String uri) {
  final colon = uri.indexOf(':');
  if (colon != 4) return false;
  const scheme = 'file';
  for (var i = 0; i < 4; i++) {
    var c = uri.codeUnitAt(i);
    if (c >= 0x41 && c <= 0x5A) c += 0x20;
    if (c != scheme.codeUnitAt(i)) return false;
  }
  return true;
}

bool _isSchemeStart(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7a);

bool _isSchemeChar(int c) =>
    _isSchemeStart(c) ||
    (c >= 0x30 && c <= 0x39) ||
    c == 0x2B ||
    c == 0x2D ||
    c == 0x2E;

/// Whether an `import` or `export` directive URI must fail the build: it names
/// no file the action can read through its declared inputs. That is a `file:`
/// URI in any spelling, a schemeless `//` authority in any separator spelling
/// (`//host/x.dart`, `\\host\x.dart`: the front end resolves those above every
/// root, outside the declared inputs), or any other URI scheme but `dart:`,
/// `package:` and the multi-root scheme. `dart:` libraries are checked against
/// the VM set and `package:` URIs against the package config by the caller.
/// Other schemeless relative URIs are not classified here: the staged-source
/// check resolves those against the importing file's declared location itself,
/// since no caller confines them.
bool isDisallowedDirectiveUri(
  String uri, {
  String multiRootPrefix = defaultMultiRootPrefix,
}) {
  if (uri.startsWith(multiRootPrefix)) return false;
  if (uri.startsWith('package:') || uri.startsWith('dart:')) return false;
  if (isFileSchemeDirectiveUri(uri)) return true;
  // A schemeless `//` authority names no declared file: the front end resolves
  // it above every root, so it reads the host whatever the roots hold. `\`
  // separates like the front end, so a leading `\\` counts too.
  final text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  if (text.startsWith('//')) return true;
  final colon = uri.indexOf(':');
  if (colon <= 0) return false;
  if (!_isSchemeStart(uri.codeUnitAt(0))) return false;
  for (var i = 1; i < colon; i++) {
    if (!_isSchemeChar(uri.codeUnitAt(i))) return false;
  }
  return true;
}

/// Whether [uri] has an empty path segment (`a//b.dart`): the resolvers below
/// skip empty segments, but the front end does not resolve every such spelling
/// the same way — the doubled slash of a `package:` URI resolves as an
/// absolute path, so `package:c//s/t.dart` reads the workspace-root file, not
/// the package's. A directive the guard cannot resolve exactly like the front
/// end is refused, so such URIs fail before the compiler runs. False for URIs
/// with no path to resolve: an empty reference, a query or fragment alone, a
/// `//` authority, or any scheme but `package:` and the multi-root scheme
/// (those never reach a path resolver: their own checks refuse them).
bool hasEmptyPathSegment(String uri) {
  var text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  if (text.startsWith(defaultMultiRootPrefix)) {
    text = text.substring(defaultMultiRootPrefix.length);
  } else if (text.startsWith('package:')) {
    final slash = text.indexOf('/', 'package:'.length);
    if (slash < 0) return false;
    text = text.substring(slash + 1);
  } else {
    if (text.contains(':')) return false;
    if (text.startsWith('//')) return false;
    if (text.startsWith('/')) text = text.substring(1);
  }
  final query = text.indexOf('?');
  final path = query < 0 ? text : text.substring(0, query);
  final hash = path.indexOf('#');
  final clean = hash < 0 ? path : path.substring(0, hash);
  return clean.startsWith('/') || clean.contains('//');
}

/// Whether [uri] spans lines: it holds a `\n` or `\r`.
///
/// A scanned directive URI holding a line break is refused wherever it
/// appears, however the directive names it. The front end drops a
/// whitespace-only (or lone-`\`) first line of a multi-line string literal,
/// so the file it reads differs from the relative path the resolvers below
/// see; reimplementing that first-line rule would risk the next spelling of
/// the same divergence, so multi-line directive URIs are refused outright. A
/// line break can never address a declared file through the resolvers below,
/// so refusing is fail-closed: real directives use single-line URIs.
/// (A single-line literal spelling the break as an escape — `'a\nb.dart'` —
/// is refused too. No clean program names a file that way.)
bool hasLineBreak(String uri) => uri.contains('\n') || uri.contains('\r');

// END staged-resolver-mirror
