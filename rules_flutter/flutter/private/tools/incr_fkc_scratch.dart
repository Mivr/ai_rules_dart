/// Crash-safe scratch-directory ownership for the incremental worker.
///
/// A worker that is killed outright (Bazel destroying it, a server shutdown,
/// the OOM killer) never runs its graceful-exit cleanup, so its scratch
/// directory — full and incremental dills of tens of megabytes — would stay
/// in the host temp directory for good. Reclaiming that scratch must not
/// depend on the worker exiting gracefully: every worker, when it starts,
/// sweeps the temp directory for scratch left by workers that are no longer
/// alive.
///
/// Liveness is decided by something a dead process cannot keep holding: an
/// advisory exclusive file lock. Each worker publishes a lock file named
/// `lock` inside its own scratch and holds `lockSync(FileLock.exclusive)`
/// on it for its whole life; the kernel drops the lock when the process
/// dies, SIGKILL included, in every network and mount namespace. The claim
/// is published atomically: the worker creates `lock.claim`, locks it, and
/// renames it to `lock` on the same still-open handle — POSIX locks belong
/// to the inode, so the rename keeps the lock and `lock` never exists
/// unlocked. A directory with only the temporary claim, or none, is a
/// newborn mid-claim and is always kept. The sweep probes each sibling's
/// `lock` in process and read-only, attempting `lockSync(FileLock.shared)`:
/// the shared lock conflicts with a live owner's exclusive lock and fails
/// at once, and succeeds once the owner is dead. Acquiring it proves the
/// owner is gone and the directory is deleted, while a held lock, a missing
/// or unopenable lock file, or any other failure keeps the directory.
/// Liveness never depends on age or on PIDs, so PID reuse cannot confuse it.
///
/// The sweep only touches directories the worker's own naming scheme
/// produces (`incr_fkc_*`), never the worker's own directory, spawns no
/// process, and never fails the start or the compile: anything it cannot
/// remove is skipped with a note on stderr.
library;

import 'dart:io';

/// The temp-directory entry prefix the worker's scratch uses.
const incrFkcScratchPrefix = 'incr_fkc_';

/// The lock file inside one worker's scratch directory.
const incrFkcLockFileName = 'lock';

/// The temporary claim file a worker locks before renaming it to [incrFkcLockFileName].
const incrFkcClaimFileName = 'lock.claim';

/// One worker's held scratch lock: the open handle whose exclusive lock
/// proves this worker is alive. The handle stays open for the worker's whole
/// life and is never duplicated: POSIX locks are per process and are dropped
/// when the process closes any descriptor for the file, so this file is
/// opened exactly once and never read back through another handle.
class ScratchLock {
  new _(this._handle);

  final RandomAccessFile? _handle;

  /// Releases the lock. Never throws.
  Future<void> close() async {
    final RandomAccessFile? handle = _handle;
    if (handle == null) return;
    try {
      await handle.close();
    } on FileSystemException {
      // Shutting down; nothing left to report.
    }
  }
}

/// The lock file path inside scratch directory [dir].
String scratchLockPath(Directory dir) =>
    '${dir.path}${Platform.pathSeparator}$incrFkcLockFileName';

/// The temporary claim file path inside scratch directory [dir].
String scratchClaimPath(Directory dir) =>
    '${dir.path}${Platform.pathSeparator}$incrFkcClaimFileName';

/// Claims the lock for scratch directory [dir]: creates the temporary
/// claim file, takes the exclusive lock on it, renames it to the lock file,
/// and holds the same handle. Runs before the worker writes anything
/// costly, so a claimed directory never holds valuable state another worker
/// could sweep. Never throws: when the lock cannot be set up, the returned
/// lock holds nothing (future sweeps keep the directory as possibly-live)
/// and the worker still starts.
Future<ScratchLock> lockWorkerScratch(Directory dir) async {
  RandomAccessFile? handle;
  try {
    // Claim under a temporary name, lock it, then rename it to `lock`:
    // POSIX locks belong to the inode, so the same open handle stays
    // locked across the rename and `lock` never exists unlocked — a sweep
    // that sees `lock` either fails against its live owner's exclusive
    // lock or acquires it after that owner died. Several workers start at
    // once and sweep at start, so without this a sweep could catch the
    // file between creation and locking, judge the newborn dead, and
    // delete its scratch.
    handle = File(
      scratchClaimPath(dir),
    ).openSync(mode: FileMode.write);
    handle.lockSync(FileLock.exclusive);
    File(scratchClaimPath(dir)).renameSync(scratchLockPath(dir));
    return ScratchLock._(handle);
  } on FileSystemException catch (e) {
    if (handle != null) {
      try {
        handle.closeSync();
      } on FileSystemException {
        // Releasing a lock that was never published; nothing to report.
      }
    }
    stderr.writeln('incr_fkc_worker: no scratch lock ($e).');
    return ScratchLock._(null);
  }
}

/// Deletes every dead worker's scratch directory under [parent], except the
/// entry named [exemptName] (this worker's own). Only directories the
/// worker's own naming scheme produces are candidates. A sibling without a
/// lock file is always kept: it is either a newborn whose owner has not
/// claimed yet (the claim lands after the directory becomes visible) or a
/// foreign entry, and neither may be deleted. Anything the sweep cannot
/// remove is kept. Never throws.
Future<void> sweepWorkerScratch(
  Directory parent, {
  required String exemptName,
}) async {
  final List<FileSystemEntity> entries;
  try {
    entries = parent.listSync(followLinks: false);
  } on FileSystemException catch (e) {
    stderr.writeln('incr_fkc_worker: scratch sweep skipped ($e).');
    return;
  }
  for (final entry in entries) {
    if (_entryName(entry) == exemptName) continue;
    _reclaimEntry(entry);
  }
}

/// The final path segment of [entry].
String _entryName(FileSystemEntity entry) =>
    entry.path.split(Platform.pathSeparator).last;

/// Deletes [entry] when it is a dead worker's scratch. Keeps everything
/// else and notes kept entries on stderr. Never throws.
void _reclaimEntry(FileSystemEntity entry) {
  if (entry is! Directory) return;
  if (!_entryName(entry).startsWith(incrFkcScratchPrefix)) return;
  if (!_siblingDead(entry)) return;
  try {
    entry.deleteSync(recursive: true);
  } on FileSystemException catch (e) {
    stderr.writeln('incr_fkc_worker: keeping ${entry.path} ($e).');
  }
}

/// Whether [entry] is a dead worker's scratch: it carries a lock file whose
/// shared lock this process can take right now. A missing lock file, an
/// owner that still holds the lock, and every failure count as alive. If the
/// lock file vanishes between the existence check and the open, the open
/// throws and the entry is kept.
bool _siblingDead(Directory entry) {
  if (!File(scratchLockPath(entry)).existsSync()) return false;
  return _tryTakeLock(scratchLockPath(entry));
}

/// Attempts the exclusive verdict on [lockPath] without blocking: opens it
/// read-only and tries a shared lock, then releases the probe handle.
/// `lockSync(FileLock.shared)` is a non-blocking attempt that conflicts
/// with the owner's exclusive lock — failing at once while the owner lives
/// and succeeding once it is dead — so this always answers in microseconds.
/// Read-only never creates, truncates or modifies another worker's file,
/// and a file that vanished throws here, keeping the entry. Returns true
/// only when the lock was acquired — the owner is dead — and false on a
/// held lock, an unopenable file, or any other [FileSystemException].
/// Releasing the probe handle touches only this process's lock, never the
/// owner's; two sweepers that both succeed delete in turn, and the loser
/// finds nothing and keeps. Never throws.
bool _tryTakeLock(String lockPath) {
  RandomAccessFile? handle;
  try {
    handle = File(lockPath).openSync(mode: FileMode.read);
    handle.lockSync(FileLock.shared);
  } on FileSystemException {
    if (handle != null) {
      try {
        handle.closeSync();
      } on FileSystemException {
        // Releasing a lock that was never taken; nothing to report.
      }
    }
    return false;
  }
  try {
    handle.closeSync();
  } on FileSystemException {
    // Already released; the verdict stands.
  }
  return true;
}
