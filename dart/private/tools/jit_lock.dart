// Opens and locks the shared JIT training lock by file descriptor.
//
// The keyed training lock (see `app_jit_snapshot.dart`) is one fixed path per
// output shared by every user on the host: it must open for a second user
// after the first created it. Linux's `fs.protected_regular` refuses O_CREAT
// on another user's file in sticky world-writable /tmp, so an existing lock
// opens without O_CREAT (read-write, O_NOFOLLOW), and only a missing lock is
// published: a uniquely named temporary in the same directory is created
// (O_CREAT|O_EXCL|O_NOFOLLOW), made 0666 through its descriptor whatever the
// umask, and renamed over the lock path without replacing an existing entry,
// so the lock appears at its final 0666 mode atomically and never at a mode
// another user cannot open. Where the atomic rename is unavailable the
// temporary is hard-linked over the lock path instead, and a peer observing
// the momentary second link adopts it only while a sibling matching the
// temporary scheme stats to the same entry. Losing
// the publish race falls back to the no-create open. After opening, the
// descriptor is statted and kept only when it is a regular file with link count
// 1, or link count 2 with such a same-entry temporary sibling still beside
// it: a hard link planted at the lock path has no such sibling, so adopting
// it would serialize nothing and, worse, the adopted
// lock's permissions could be relaxed through the descriptor onto a victim's
// private file. Permissions change only on the temporary the publisher created
// itself with O_EXCL, never on an adopted lock. No path-based check precedes
// the open and no chmod by path touches the lock, so a symlink, directory,
// FIFO or other non-regular entry at the lock path is never followed and never
// created through: the open fails closed instead.
//
// The exclusive lock is an `fcntl` whole-file write lock on the descriptor,
// the same domain `File.lockSync` takes, so trainings using either contend.
// All metadata reads (stat, owner name) never read entry content.
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'jit_policy.dart';

export 'jit_policy.dart';

/// The result of opening the lock: a held descriptor [fd] (nonnegative), or a
/// fail-closed [detail] naming the entry plus which remedy applies.
/// [chmodRemedy] is true only when the lock's own mode is what denies us
/// access (a regular file we cannot open for writing); anything else wants
/// the entry removed. [ownEntry] tells a mode-denied remedy whether the entry
/// is ours to chmod ourselves. [publishFailed] is true only when the publish
/// itself failed (see [_jitPublishFailure]): there may be no entry at all, so
/// neither the `chmod 0666` remedy nor an owner-removal remedy applies.
/// [linkRefused] is true only when the entry was refused for its hard links
/// (see [_jitAdoptFd]): the detail names the count, and the remedy names
/// removing the extra links.
typedef JitLockOpen = ({
  int fd,
  String detail,
  bool chmodRemedy,
  bool ownEntry,
  bool publishFailed,
  bool linkRefused,
});

/// Runs between the temporary's chmod and its publish (see
/// [jitCreateAndPublishLock]): tests inspect the paths while the lock is still
/// unpublished. Must return normally.
typedef JitTempReady = void Function(String tempPath, int tempFd);

/// An opened lock backend: the libc handle with the flags opening the lock.
/// [_jitBackendFor] returns one, or a fail-closed [JitLockOpen] where the host
/// cannot open the lock at all.
typedef _JitBackend = ({ffi.DynamicLibrary lib, JitOpenFlags flags});

typedef _MallocNative = ffi.Pointer<ffi.Uint8> Function(ffi.Size);
typedef _MallocDart = ffi.Pointer<ffi.Uint8> Function(int);
typedef _FreeNative = ffi.Void Function(ffi.Pointer<ffi.Uint8>);
typedef _FreeDart = void Function(ffi.Pointer<ffi.Uint8>);
typedef _OpenNative = ffi.Int Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Int,
  ffi.VarArgs<(ffi.Int,)>,
);
typedef _OpenDart = int Function(ffi.Pointer<ffi.Uint8>, int, int);
typedef _CloseNative = ffi.Int Function(ffi.Int);
typedef _CloseDart = int Function(int);
typedef _FcntlNative = ffi.Int Function(
  ffi.Int,
  ffi.Int,
  ffi.VarArgs<(ffi.Pointer<ffi.Uint8>,)>,
);
typedef _FcntlDart = int Function(int, int, ffi.Pointer<ffi.Uint8>);
typedef _FstatNative = ffi.Int Function(ffi.Int, ffi.Pointer<ffi.Uint8>);
typedef _FstatDart = int Function(int, ffi.Pointer<ffi.Uint8>);
typedef _FchmodNative = ffi.Int Function(ffi.Int, ffi.Uint32);
typedef _FchmodDart = int Function(int, int);
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
typedef _LinkNative = ffi.Int Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
);
typedef _LinkDart = int Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
);
typedef _UnlinkNative = ffi.Int Function(ffi.Pointer<ffi.Uint8>);
typedef _UnlinkDart = int Function(ffi.Pointer<ffi.Uint8>);
typedef _Renameat2Native = ffi.Int Function(
  ffi.Int,
  ffi.Pointer<ffi.Uint8>,
  ffi.Int,
  ffi.Pointer<ffi.Uint8>,
  ffi.UnsignedInt,
);
typedef _Renameat2Dart = int Function(
  int,
  ffi.Pointer<ffi.Uint8>,
  int,
  ffi.Pointer<ffi.Uint8>,
  int,
);
typedef _RenamexNative = ffi.Int Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.UnsignedInt,
);
typedef _RenamexDart = int Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
  int,
);
typedef _LstatDart = int Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
);
typedef _Fxstat64Native = ffi.Int Function(
  ffi.Int,
  ffi.Int,
  ffi.Pointer<ffi.Uint8>,
);
typedef _Fxstat64Dart = int Function(int, int, ffi.Pointer<ffi.Uint8>);
typedef _Lxstat64Native = ffi.Int Function(
  ffi.Int,
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
);
typedef _Lxstat64Dart = int Function(
  int,
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
);
typedef _GeteuidNative = ffi.Uint32 Function();
typedef _GeteuidDart = int Function();
typedef _ErrnoNative = ffi.Pointer<ffi.Int> Function();
typedef _ErrnoDart = ffi.Pointer<ffi.Int> Function();

final class _Passwd extends ffi.Opaque {}

typedef _GetpwuidNative = ffi.Pointer<_Passwd> Function(ffi.Uint32);
typedef _GetpwuidDart = ffi.Pointer<_Passwd> Function(int);

/// Our uid, for telling our own entries from another user's: only our own
/// lock gets the `chmod 0666` remedy, and only our own stale directories get
/// removed.
int jitOwnUid() {
  if (Platform.isWindows) return -1;
  final lib = ffi.DynamicLibrary.process();
  final geteuid = lib.lookupFunction<_GeteuidNative, _GeteuidDart>('geteuid');
  return geteuid();
}

/// Names the entry currently at [path] for the fail-closed error: its type
/// and its owner, never its content. The owner is the uid, plus the user name
/// where the host resolves it.
String jitDescribeEntry(String path) {
  final info = jitStatEntry(path);
  if (info == null) return 'entry at $path of unknown ownership';
  final owner = jitUserName(info.uid);
  final who = owner == null ? 'uid ${info.uid}' : 'uid ${info.uid} ($owner)';
  return '${info.kind} at $path owned by $who';
}

/// The user name for [uid], or null where the host resolves none.
String? jitUserName(int uid) {
  if (Platform.isWindows) return null;
  try {
    final lib = ffi.DynamicLibrary.process();
    final getpwuid = lib.lookupFunction<_GetpwuidNative, _GetpwuidDart>(
      'getpwuid',
    );
    final pwd = getpwuid(uid);
    if (pwd == ffi.nullptr) return null;
    // `pw_name` is the first field of `struct passwd` on Linux and macOS.
    final name = pwd.cast<ffi.Pointer<ffi.Uint8>>().value;
    if (name == ffi.nullptr) return null;
    final bytes = <int>[];
    for (var i = 0; i < 1024; i++) {
      final byte = name[i];
      if (byte == 0) break;
      bytes.add(byte);
    }
    if (bytes.isEmpty) return null;
    return utf8.decode(bytes, allowMalformed: true);
  } on ArgumentError {
    // This libc has no `getpwuid`: no name available.
    return null;
  }
}

/// Stats [path] without following symlinks, returning its kind (see
/// [jitEntryKind]), its owner uid, its full mode and its hard-link count for
/// the fail-closed error. Null when the entry cannot be statted or the platform
/// has no suitable call.
///
/// On Linux this is `statx(2)`, whose `struct statx` layout is the same on
/// every architecture (the link count is a little-endian u32 at offset 16, the
/// uid a little-endian u32 at offset 20, the mode a little-endian u16 at offset
/// 28), falling back to `lstat(2)` with the 64-bit `struct stat` layout where
/// `statx` is unavailable (see [jitLinuxStatOffsets]), and to `__lxstat64`
/// where the plain symbol is missing (see [jitLinuxStat64Calls]); on macOS it is `lstat(2)`
/// with the 64-bit `struct stat` layout (the mode at offset 4, the link count
/// at offset 6, the uid at offset 16; see [jitLstatSymbol]). All supported
/// hosts are little-endian. Metadata only: the entry's content is never read.
JitStat? jitStatEntry(String path) {
  if (Platform.isWindows) return null;
  final lib = ffi.DynamicLibrary.process();
  final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
  final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
  final pathPtr = _jitCString(malloc, path);
  try {
    final buf = malloc(256);
    if (buf == ffi.nullptr) return null;
    try {
      buf.asTypedList(256).fillRange(0, 256, 0);
      if (Platform.isLinux) return _jitLinuxStatPath(lib, pathPtr, buf);
      if (Platform.isMacOS) {
        final lstat = _jitBindMacLstat(lib);
        if (lstat == null) return null;
        if (lstat(pathPtr, buf) != 0) return null;
        return jitDecodeMacStat(buf.asTypedList(64));
      }
      return null;
    } finally {
      free(buf);
    }
  } finally {
    free(pathPtr);
  }
}

/// Binds the macOS `lstat` reading the 64-bit layout (see [jitLstatSymbol]),
/// or null where the symbol is missing: the guard wraps only the lookup, so a
/// decoder out-of-range error can never read as a missing call.
_LstatDart? _jitBindMacLstat(ffi.DynamicLibrary lib) {
  final symbol = jitLstatSymbol(
    isMacOS: true,
    isX64: ffi.Abi.current() == ffi.Abi.macosX64,
  );
  try {
    return lib.lookupFunction<_LstatNative, _LstatDart>(symbol);
  } on ArgumentError {
    // This libc has no such `lstat`: no description available.
    return null;
  }
}

/// Binds `statx` (see [_jitLinuxStatPath] and [_jitLinuxFstatFd]), or null
/// where the symbol is missing (glibc older than 2.28): the guard wraps only
/// the lookup, so a short-buffer decode error can never read as "old libc"
/// again.
_StatxDart? _jitBindStatx(ffi.DynamicLibrary lib) {
  try {
    return lib.lookupFunction<_StatxNative, _StatxDart>('statx');
  } on ArgumentError {
    // No `statx` in this libc: the callers fall through to the `struct stat`
    // calls.
    return null;
  }
}

/// Stats through the 64-bit `struct stat` fallback on old glibc (see
/// [jitLinuxStat64Calls]): [plain] (`fstat`/`lstat`) first, [versioned]
/// (`__fxstat64`/`__lxstat64` with `_STAT_VER`) where the plain symbol is
/// missing (glibc older than 2.33 inlines it). True when either call statted
/// the entry; the caller then decodes the buffer (see [jitDecodeLinuxStat]).
bool _jitStat64Fallback({
  required int Function() plain,
  required int Function() versioned,
}) {
  try {
    return plain() == 0;
  } on ArgumentError {
    // The plain symbol is missing: fall back to the versioned call.
    try {
      return versioned() == 0;
    } on ArgumentError {
      // Neither call exists on this libc: nothing statted.
      return false;
    }
  }
}

/// Stats [pathPtr] on Linux (see [jitStatEntry]): `statx(2)` first, `lstat(2)`
/// with the 64-bit `struct stat` layout where `statx` is unavailable or
/// refuses the entry (see [jitLinuxStatOffsets]), `__lxstat64` with
/// `_STAT_VER` where the plain symbol is missing (see [jitLinuxStat64Calls]).
/// Null when none stats the entry.
JitStat? _jitLinuxStatPath(
  ffi.DynamicLibrary lib,
  ffi.Pointer<ffi.Uint8> pathPtr,
  ffi.Pointer<ffi.Uint8> buf,
) {
  final statx = _jitBindStatx(lib);
  if (statx != null) {
    const atFdcwd = -100;
    const nofollow = 0x100;
    const basicStats = 0x7ff;
    if (statx(atFdcwd, pathPtr, nofollow, basicStats, buf) == 0) {
      return jitDecodeStatx(buf.asTypedList(256));
    }
  }
  final calls = jitLinuxStat64Calls(abi: ffi.Abi.current());
  if (calls == null) return null;
  final statted = _jitStat64Fallback(
    plain: () =>
        lib.lookupFunction<_LstatNative, _LstatDart>('lstat')(pathPtr, buf),
    versioned: () => lib.lookupFunction<_Lxstat64Native, _Lxstat64Dart>(
      calls.lstat,
    )(calls.ver, pathPtr, buf),
  );
  if (!statted) return null;
  return jitDecodeLinuxStat(buf.asTypedList(64), abi: ffi.Abi.current());
}

/// Opens the lock at [path] by file descriptor, for the caller to take with
/// [jitTryExclusiveLock] and release with [jitUnlockAndClose].
///
/// An existing lock opens read-write with O_NOFOLLOW and without O_CREAT and
/// is kept only when it is a regular file with link count 1, or link count 2
/// with a same-entry temporary sibling still beside it (see [_jitAdoptFd]); a
/// missing lock is published at 0666 through a uniquely named temporary
/// renamed over the lock path without replacing (see
/// [jitCreateAndPublishLock]), so the lock never exists at a mode
/// another user cannot open, whatever the umask or the scheduling. Losing the
/// publish race falls back to the no-create open. An adopted lock is never
/// chmodded: only the temporary the publisher created itself with O_EXCL ever
/// has its permissions changed. Nothing is followed and nothing is created
/// through: a symlink, directory, FIFO, hard link or other non-regular entry
/// fails closed with its path, type, owner and link count in
/// [JitLockOpen.detail].
JitLockOpen jitOpenLock(String path) {
  final ready = _jitBackendFor(path);
  final backend = ready.backend;
  if (backend == null) return ready.failure!;
  final first = _jitOpen(backend.lib, path, backend.flags.noCreate, 0);
  if (first.fd >= 0) return _jitAdoptFd(backend.lib, path, first.fd);
  if (first.errno != _enoent) {
    return _jitLockFailure(path, accessDenied: first.errno == _eacces);
  }
  return _jitCreateAndPublish(backend.lib, path, backend.flags, null);
}

/// Creates the lock at [path] at its final 0666 mode and opens it, for a
/// missing lock (see [jitOpenLock]).
///
/// The lock never exists at a narrower mode: a uniquely named temporary in the
/// same directory is created with O_CREAT|O_EXCL|O_NOFOLLOW, made 0666 through
/// its descriptor whatever the umask, then renamed over [path] without
/// replacing an existing entry (see [jitRenameCall]), which fails with EEXIST
/// when another process published first (then that lock
/// opens without O_CREAT, as today). Where the atomic rename is unavailable
/// the temporary is hard-linked over [path] instead (see [_jitPublishLink]).
/// The temporary is unlinked on every path but the publish,
/// and its name starts with the lock's file name, so a leftover from a killed
/// process is recognisable; such a leftover never blocks a later run (names
/// are unique per call) and is never taken for the lock (only [path] opens).
/// The same construction runs on macOS; Windows fails closed as [jitOpenLock].
///
/// [onTempReady] runs after the temporary is 0666 and before it is published,
/// so tests can inspect the paths between the steps; it must return normally.
JitLockOpen jitCreateAndPublishLock(String path, {JitTempReady? onTempReady}) {
  final ready = _jitBackendFor(path);
  final backend = ready.backend;
  if (backend == null) return ready.failure!;
  return _jitCreateAndPublish(backend.lib, path, backend.flags, onTempReady);
}

/// The shared open preamble for [jitOpenLock] and [jitCreateAndPublishLock]:
/// the libc handle with the flags opening the lock, or a fail-closed opening
/// where the platform cannot open the lock at all (Windows, or a Linux ABI
/// with no pinned O_* values).
({_JitBackend? backend, JitLockOpen? failure}) _jitBackendFor(String path) {
  if (Platform.isWindows) {
    return (
      backend: null,
      failure: (
        fd: -1,
        detail: 'entry at $path of unknown ownership',
        chmodRemedy: false,
        ownEntry: false,
        publishFailed: false,
        linkRefused: false,
      ),
    );
  }
  final lib = ffi.DynamicLibrary.process();
  try {
    final flags = jitOpenFlags(
      isMacOS: Platform.isMacOS,
      abi: ffi.Abi.current(),
    );
    return (backend: (lib: lib, flags: flags), failure: null);
  } on UnsupportedError catch (error) {
    // This host's Linux ABI has no pinned O_* values: fail closed with the
    // cause rather than opening the lock with guessed flags.
    return (
      backend: null,
      failure: (
        fd: -1,
        detail: 'entry at $path ($error)',
        chmodRemedy: false,
        ownEntry: false,
        publishFailed: false,
        linkRefused: false,
      ),
    );
  }
}

/// Publishes the lock at [path] through a fresh temporary (see
/// [jitCreateAndPublishLock]), retrying with a new name when the temporary's
/// own name is taken. A taken name is all but impossible (names are unique per
/// call); giving up still fails closed.
JitLockOpen _jitCreateAndPublish(
  ffi.DynamicLibrary lib,
  String path,
  JitOpenFlags flags,
  JitTempReady? onTempReady,
) {
  var published = _jitPublishOnce(lib, path, flags, onTempReady);
  for (var attempt = 1; published.retry && attempt < 3; attempt++) {
    published = _jitPublishOnce(lib, path, flags, onTempReady);
  }
  return published.result;
}

/// One publish attempt (see [_jitCreateAndPublish]): creates a fresh temporary,
/// makes it 0666 and publishes it at [path], keeping the published descriptor.
/// [retry] is true only when the temporary's own name was taken. A temporary
/// that cannot be created, or a publish the kernel refuses for any reason but
/// a lost race, reports the publish itself (see [_jitPublishFailure]), never
/// an entry that may not be there.
({JitLockOpen result, bool retry}) _jitPublishOnce(
  ffi.DynamicLibrary lib,
  String path,
  JitOpenFlags flags,
  JitTempReady? onTempReady,
) {
  final temp = _jitTempPath(path);
  final created = _jitOpen(lib, temp, flags.create, 0x1b6);
  if (created.fd < 0) {
    if (created.errno == _eexist) {
      // Our temporary's own name is taken: retry with a new one.
      return (result: _jitLockFailure(path, accessDenied: false), retry: true);
    }
    return (
      result: _jitPublishFailure(path, errno: created.errno),
      retry: false,
    );
  }
  final fd = created.fd;
  _jitFchmod(lib, fd, 0x1b6);
  onTempReady?.call(temp, fd);
  int renameErrno;
  try {
    renameErrno = _jitRenameOnce(lib, temp, path);
  } on UnsupportedError {
    // This host's Linux ABI has no pinned no-replace rename: the link path
    // below publishes instead.
    renameErrno = -1;
  }
  if (renameErrno == 0) {
    // Renamed over the lock path atomically: the temporary is the lock now,
    // so its descriptor is adopted without unlinking anything.
    return (result: _jitAdoptFd(lib, path, fd), retry: false);
  }
  if (renameErrno < 0) {
    // No atomic rename on this host: the legacy link path publishes instead.
    return _jitPublishLink(lib, path, temp, fd, flags);
  }
  _jitUnlink(lib, temp);
  _jitClose(lib, fd);
  if (renameErrno != _eexist) {
    return (result: _jitPublishFailure(path, errno: renameErrno), retry: false);
  }
  // Lost the publish race: open the winner's lock without creating.
  return _jitOpenWinner(lib, path, flags);
}

/// The legacy publish where the atomic rename is unavailable (see
/// [_jitPublishOnce]): hard-links [temp] over [path] and unlinks it, keeping
/// the linked descriptor. A peer can observe the lock with link count 2
/// between the two calls, and adopts it then only while a same-entry temporary
/// sibling is still beside it (see [_jitAdoptFd]).
({JitLockOpen result, bool retry}) _jitPublishLink(
  ffi.DynamicLibrary lib,
  String path,
  String temp,
  int fd,
  JitOpenFlags flags,
) {
  int linkErrno;
  try {
    linkErrno = _jitLink(lib, temp, path);
  } on ArgumentError {
    // This libc has no `link`: nothing was published, so close the temporary
    // and fail closed describing the lock as found.
    _jitClose(lib, fd);
    _jitUnlink(lib, temp);
    return (result: _jitLockFailure(path, accessDenied: false), retry: false);
  }
  _jitUnlink(lib, temp);
  if (linkErrno == 0) return (result: _jitAdoptFd(lib, path, fd), retry: false);
  _jitClose(lib, fd);
  if (linkErrno != _eexist) {
    return (result: _jitPublishFailure(path, errno: linkErrno), retry: false);
  }
  // Lost the publish race: open the winner's lock without creating.
  return _jitOpenWinner(lib, path, flags);
}

/// Opens the race winner's lock after a lost publish race (see
/// [_jitPublishOnce] and [_jitPublishLink]): the winner's lock opens without
/// creating, as today.
({JitLockOpen result, bool retry}) _jitOpenWinner(
  ffi.DynamicLibrary lib,
  String path,
  JitOpenFlags flags,
) {
  final winner = _jitOpen(lib, path, flags.noCreate, 0);
  if (winner.fd >= 0) {
    return (result: _jitAdoptFd(lib, path, winner.fd), retry: false);
  }
  return (
    result: _jitLockFailure(path, accessDenied: winner.errno == _eacces),
    retry: false,
  );
}

/// Renames [temp] over [path] without replacing an existing entry (see
/// [jitRenameCall]): 0 when the lock is now published at [path], -1 when the
/// rename is unavailable on this host (an unpinned ABI, a missing symbol,
/// ENOSYS or EINVAL — the kernel or libc predates it) and the caller falls
/// back to the link path, otherwise the refusal `errno` (EEXIST when another
/// publisher won). The caller unlinks the temporary on every path but the
/// publish.
int _jitRenameOnce(ffi.DynamicLibrary lib, String temp, String path) {
  final rename = _jitBindRename(
    lib,
    jitRenameCall(isMacOS: Platform.isMacOS, abi: ffi.Abi.current()),
  );
  if (rename == null) return -1;
  final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
  final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
  final tempPtr = _jitCString(malloc, temp);
  try {
    final pathPtr = _jitCString(malloc, path);
    try {
      if (rename(tempPtr, pathPtr) == 0) return 0;
      // Read `errno` before any other libc call: freeing comes after.
      final errno = _jitErrno(lib);
      return errno == _enosys || errno == _einval ? -1 : errno;
    } finally {
      free(pathPtr);
    }
  } finally {
    free(tempPtr);
  }
}

/// Binds the no-replace rename (see [jitRenameCall]): a closure renaming a
/// temporary over the lock path and returning the raw result, or null where
/// the symbol is missing. Each missing-symbol guard wraps only its lookup,
/// never a rename.
int Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>)? _jitBindRename(
  ffi.DynamicLibrary lib,
  ({String symbol, int noReplace}) call,
) {
  if (Platform.isMacOS) {
    try {
      final rename = lib.lookupFunction<_RenamexNative, _RenamexDart>(
        call.symbol,
      );
      return (temp, path) => rename(temp, path, call.noReplace);
    } on ArgumentError {
      // This libc has no `renamex_np`: the caller takes the link path.
      return null;
    }
  }
  try {
    final rename = lib.lookupFunction<_Renameat2Native, _Renameat2Dart>(
      call.symbol,
    );
    // AT_FDCWD for both sides.
    return (temp, path) => rename(-100, temp, -100, path, call.noReplace);
  } on ArgumentError {
    // This libc has no `renameat2`: the caller takes the link path.
    return null;
  }
}

/// Disambiguates temporary lock names within this process (see [_jitTempPath]).
int _jitTempSequence = 0;

/// A fresh temporary name owned by this call for the lock at [path]: the
/// lock's file name plus the process, the time and a random part, so a
/// leftover from a killed process is recognisable and never collides with a
/// live call.
String _jitTempPath(String path) =>
    '$path.${pid}.${DateTime.now().microsecondsSinceEpoch}.'
    '${Random().nextInt(1 << 31)}.${_jitTempSequence++}.tmp';

/// Hard-links [from] over [to], returning 0 or the `errno`.
int _jitLink(ffi.DynamicLibrary lib, String from, String to) {
  final link = lib.lookupFunction<_LinkNative, _LinkDart>('link');
  final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
  final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
  final fromPtr = _jitCString(malloc, from);
  try {
    final toPtr = _jitCString(malloc, to);
    try {
      final rc = link(fromPtr, toPtr);
      // Read `errno` before any other libc call: freeing comes after.
      return rc == 0 ? 0 : _jitErrno(lib);
    } finally {
      free(toPtr);
    }
  } finally {
    free(fromPtr);
  }
}

/// Removes [path] without following it, ignoring cleanup errors.
void _jitUnlink(ffi.DynamicLibrary lib, String path) {
  try {
    final unlink = lib.lookupFunction<_UnlinkNative, _UnlinkDart>('unlink');
    final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
    final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
    final pathPtr = _jitCString(malloc, path);
    try {
      unlink(pathPtr);
    } finally {
      free(pathPtr);
    }
  } on ArgumentError {
    // This libc has no `unlink`: nothing to clean up.
  }
}

/// Takes the lock without blocking, returning true when [fd] now holds an
/// exclusive `fcntl` whole-file write lock. False means another process holds
/// it (or the call failed); the caller polls until its deadline instead of
/// hanging forever.
bool jitTryExclusiveLock(int fd) {
  if (Platform.isWindows || fd < 0) return false;
  final lib = ffi.DynamicLibrary.process();
  final fcntl = lib.lookupFunction<_FcntlNative, _FcntlDart>('fcntl');
  final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
  final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
  final buf = malloc(32);
  if (buf == ffi.nullptr) return false;
  try {
    buf.asTypedList(32).fillRange(0, 32, 0);
    // A whole-file write lock: type F_WRLCK with start and length zero. The
    // `struct flock` layout and constants differ by OS: on Linux the type is a
    // little-endian i16 at offset 0 and F_WRLCK is 1 (F_SETLK is 6), while on
    // macOS the start/len are two i64 at offsets 0/8, the PID an i32 at offset
    // 16 and the type an i16 at offset 20, where F_WRLCK is 3 (F_SETLK is 8).
    // Darwin numbers F_RDLCK 1, F_UNLCK 2, F_WRLCK 3; Linux numbers F_RDLCK 0,
    // F_WRLCK 1, F_UNLCK 2, so Linux's 1 written on macOS would take a shared
    // read lock and let two trainings share one key. [jitFlockLockType] and
    // [jitFlockTypeOffset] pin the value and the field. `fcntl` is variadic
    // (`int fcntl(int, int, ...)`), so its `struct flock` pointer binds through
    // `ffi.VarArgs`: a fixed binding passes the pointer in a register that
    // `fcntl` never reads on Apple arm64. All supported hosts are little-endian.
    final view = ByteData.sublistView(buf.asTypedList(32));
    final isMacOS = Platform.isMacOS;
    final abi = ffi.Abi.current();
    view.setInt16(
      jitFlockTypeOffset(isMacOS: isMacOS, abi: abi),
      jitFlockLockType(isMacOS: isMacOS, abi: abi),
      Endian.little,
    );
    final cmd = isMacOS ? 8 : 6;
    return fcntl(fd, cmd, buf) == 0;
  } finally {
    free(buf);
  }
}

/// Releases the exclusive lock on [fd] and closes it, ignoring cleanup
/// errors. Null and Windows descriptors are a no-op.
void jitUnlockAndClose(int fd) {
  if (Platform.isWindows || fd < 0) return;
  try {
    final lib = ffi.DynamicLibrary.process();
    final fcntl = lib.lookupFunction<_FcntlNative, _FcntlDart>('fcntl');
    final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
    final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
    final close = lib.lookupFunction<_CloseNative, _CloseDart>('close');
    final buf = malloc(32);
    if (buf != ffi.nullptr) {
      try {
        buf.asTypedList(32).fillRange(0, 32, 0);
        // Unlock: F_UNLCK with the same per-OS layout as [jitTryExclusiveLock].
        final view = ByteData.sublistView(buf.asTypedList(32));
        if (Platform.isMacOS) {
          view.setInt16(20, 2, Endian.little);
          fcntl(fd, 8, buf);
        } else {
          view.setInt16(0, 2, Endian.little);
          fcntl(fd, 6, buf);
        }
      } finally {
        free(buf);
      }
    }
    close(fd);
  } on ArgumentError {
    // Ignore cleanup errors.
  }
}

/// The PID holding an exclusive `fcntl` lock on [path], for the lock-wait
/// notices and the deadline error. Null where no process holds one, where the
/// path cannot be opened, or where the platform has no suitable call: the
/// callers then say "unknown".
///
/// Queries with `fcntl(2)` `F_GETLK` for a conflicting write lock over the
/// whole file: the kernel reports the lock the training's own try-lock
/// refuses, with the holder's PID. Asking for [jitFlockLockType] (`F_WRLCK`)
/// catches a competing reader as well as a writer; asking for Linux's value 1
/// on Darwin would be `F_RDLCK` and miss another reader. An unconflicted
/// lookup leaves `l_type` as `F_UNLCK` (2 on both OSes), which reports no
/// holder. The `struct flock` layout differs by OS: on Linux the type is a
/// little-endian i16 at offset 0 and the PID a little-endian i32 at the offset
/// [jitFlockPidOffset] pins, on macOS the start/len are two i64 at offsets 0/8,
/// the PID an i32 at offset 16 and the type an i16 at offset 20 (see
/// [jitFlockTypeOffset]).
/// All supported hosts are little-endian. Metadata only: the file opens
/// read-only with O_NOFOLLOW (a symlink or FIFO at the path reports no holder
/// instead of blocking) and is never read.
int? jitLockHolderPid(String path) {
  if (Platform.isWindows) return null;
  try {
    final lib = ffi.DynamicLibrary.process();
    final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
    final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
    final open = lib.lookupFunction<_OpenNative, _OpenDart>('open');
    final close = lib.lookupFunction<_CloseNative, _CloseDart>('close');
    final fcntl = lib.lookupFunction<_FcntlNative, _FcntlDart>('fcntl');
    final pathPtr = _jitCString(malloc, path);
    try {
      final buf = malloc(32);
      if (buf == ffi.nullptr) return null;
      try {
        buf.asTypedList(32).fillRange(0, 32, 0);
        // `open` is variadic (`int open(const char *, int, ...)`): the mode
        // slot is passed explicitly so the call marshals as variadic. The
        // flags open read-only without `O_CREAT`, so the kernel ignores it;
        // O_NOFOLLOW never follows a final symlink and O_NONBLOCK never blocks
        // on a FIFO (see [jitReadFlags]).
        final fd = open(
          pathPtr,
          jitReadFlags(isMacOS: Platform.isMacOS, abi: ffi.Abi.current()),
          0,
        );
        if (fd < 0) return null;
        try {
          final view = ByteData.sublistView(buf.asTypedList(32));
          final isMacOS = Platform.isMacOS;
          final abi = ffi.Abi.current();
          final typeOffset = jitFlockTypeOffset(isMacOS: isMacOS, abi: abi);
          view.setInt16(
            typeOffset,
            jitFlockLockType(isMacOS: isMacOS, abi: abi),
            Endian.little,
          );
          final cmd = isMacOS ? 7 : 5;
          if (fcntl(fd, cmd, buf) != 0) return null;
          final type = view.getInt16(typeOffset, Endian.little);
          if (type == 2) return null;
          final holderPid = view.getInt32(
            jitFlockPidOffset(
              isMacOS: Platform.isMacOS,
              abi: ffi.Abi.current(),
            ),
            Endian.little,
          );
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
  } on UnsupportedError {
    // This host's Linux ABI has no pinned O_* values or `struct flock`
    // layout: no holder available, and the callers then say "unknown".
    return null;
  }
}

// `errno` values distinguishing the open failures (see [jitOpenLock]):
// EACCES for a mode-denied open, ENOENT for a missing lock, EEXIST for a
// lost create race; ENOSYS and EINVAL for a rename the host predates (see
// [_jitRenameOnce]). All five read the same on Linux and macOS.
const _eacces = 13;
const _enoent = 2;
const _eexist = 17;
const _enosys = 38;
const _einval = 22;

/// The current thread's `errno` from libc: `__errno_location` on Linux,
/// `__error` on macOS. Callers read it before any other libc call.
int _jitErrno(ffi.DynamicLibrary lib) {
  if (Platform.isMacOS) {
    final error = lib.lookupFunction<_ErrnoNative, _ErrnoDart>('__error');
    return error().value;
  }
  final error = lib.lookupFunction<_ErrnoNative, _ErrnoDart>(
    '__errno_location',
  );
  return error().value;
}

/// One libc `open` of [path]: the descriptor, or -1 with the `errno` the
/// caller classifies. Never creates unless [flags] says so, never follows the
/// final component.
({int fd, int errno}) _jitOpen(
  ffi.DynamicLibrary lib,
  String path,
  int flags,
  int mode,
) {
  final open = lib.lookupFunction<_OpenNative, _OpenDart>('open');
  final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
  final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
  final pathPtr = _jitCString(malloc, path);
  try {
    final fd = open(pathPtr, flags, mode);
    // Read `errno` before any other libc call: freeing comes after.
    final errno = fd < 0 ? _jitErrno(lib) : 0;
    return (fd: fd, errno: errno);
  } finally {
    free(pathPtr);
  }
}

/// Keeps an opened lock descriptor only when it is a regular file with link
/// count 1 — or link count 2 while a same-entry temporary sibling shows the
/// publish is still in flight (see [_jitIsPublishWindow]). Anything else is
/// closed and fails closed with its path, type, owner and link count: a hard
/// link planted at the lock path names another entry pointing at the same
/// file, so the descriptor is dropped without touching permissions (relaxing
/// them would widen the linked-to file for its owner).
JitLockOpen _jitAdoptFd(ffi.DynamicLibrary lib, String path, int fd) {
  JitStat? info;
  try {
    info = _jitFstatFd(lib, fd);
  } on ArgumentError catch (error) {
    // A decoder out-of-range error is a RangeError (an ArgumentError): never
    // swallow it as a missing call. Only a missing lookup lands here.
    if (error is RangeError) rethrow;
    // This libc has no stat call for a descriptor: nothing to keep.
    info = null;
  }
  if (info == null || info.kind != 'regular file') {
    _jitClose(lib, fd);
    return _jitLockFailure(path, accessDenied: false);
  }
  if (info.nlink == 1 ||
      (info.nlink == 2 && _jitIsPublishWindow(path, info.id))) {
    return (
      fd: fd,
      detail: '',
      chmodRemedy: false,
      ownEntry: true,
      publishFailed: false,
      linkRefused: false,
    );
  }
  _jitClose(lib, fd);
  return _jitLockFailure(path, accessDenied: false, linkCount: info.nlink);
}

/// Whether the lock at [path] with identity [id] is mid-publish (see
/// [_jitAdoptFd]): a directory sibling fits the temporary scheme (see
/// [jitIsTempSibling]) and stats to the same identity. Both sides consult the
/// same call family (see [_jitFstatFd] and [jitStatEntry]), so equal ids name
/// the same entry; a planted link has no such sibling and stays refused.
/// False where the directory cannot be listed: the caller fails closed.
bool _jitIsPublishWindow(String path, JitFileId id) {
  final sep = Platform.pathSeparator;
  final cut = path.lastIndexOf(sep);
  final dir = cut < 0 ? '.' : path.substring(0, cut);
  final lockName = cut < 0 ? path : path.substring(cut + 1);
  try {
    for (final entry in Directory(dir).listSync(followLinks: false)) {
      if (!jitIsTempSibling(entry.path.split(sep).last, lockName)) continue;
      if (jitStatEntry(entry.path)?.id == id) return true;
    }
  } on FileSystemException {
    // The directory cannot be listed: not a recognizable window.
    return false;
  }
  return false;
}

/// Whether [fd] still names the entry at [path]: the descriptor's own device
/// and inode against the path's, without following symlinks on either side.
/// False where either side cannot be statted: the caller reopens rather than
/// trusting an unverified lock. Both sides consult the same call family on any
/// host (see [_jitFstatFd] and [jitStatEntry]), so equal ids name the same
/// entry; any divergence fails closed.
bool jitFdMatchesPath(int fd, String path) {
  if (Platform.isWindows || fd < 0) return false;
  final lib = ffi.DynamicLibrary.process();
  JitStat? held;
  try {
    held = _jitFstatFd(lib, fd);
  } on ArgumentError catch (error) {
    // As in [_jitAdoptFd]: a decoder out-of-range error must propagate, never
    // read as a missing call.
    if (error is RangeError) rethrow;
    // This libc has no stat call for a descriptor: nothing verified.
    held = null;
  }
  if (held == null) return false;
  final current = jitStatEntry(path);
  if (current == null) return false;
  // Record equality compares every identity field: any divergence fails
  // closed, so only the exact same entry still matches the held descriptor.
  return held.id == current.id;
}

/// Stats an open descriptor itself: `statx` with `AT_EMPTY_PATH` on Linux
/// (whose `struct statx` layout is architecture-independent), falling back to
/// `fstat` with the 64-bit `struct stat` layout where `statx` is unavailable
/// or refuses the descriptor (glibc older than 2.28; see
/// [jitLinuxStatOffsets]), and to `__fxstat64` where the plain symbol is
/// missing (see [jitLinuxStat64Calls]); on macOS `fstat` with the 64-bit `struct stat`
/// layout (see [jitFstatSymbol]). Null when the descriptor cannot be statted.
JitStat? _jitFstatFd(ffi.DynamicLibrary lib, int fd) {
  final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
  final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
  final buf = malloc(256);
  if (buf == ffi.nullptr) return null;
  try {
    buf.asTypedList(256).fillRange(0, 256, 0);
    if (Platform.isLinux) return _jitLinuxFstatFd(lib, fd, buf);
    if (Platform.isMacOS) {
      final fstat = _jitBindMacFstat(lib);
      if (fstat == null) return null;
      if (fstat(fd, buf) != 0) return null;
      return jitDecodeMacStat(buf.asTypedList(64));
    }
    return null;
  } finally {
    free(buf);
  }
}

/// Binds the macOS `fstat` reading the 64-bit layout (see [jitFstatSymbol]),
/// or null where the symbol is missing: the guard wraps only the lookup, so a
/// decoder out-of-range error can never read as a missing call.
_FstatDart? _jitBindMacFstat(ffi.DynamicLibrary lib) {
  final symbol = jitFstatSymbol(
    isMacOS: true,
    isX64: ffi.Abi.current() == ffi.Abi.macosX64,
  );
  try {
    return lib.lookupFunction<_FstatNative, _FstatDart>(symbol);
  } on ArgumentError {
    // This libc has no such `fstat`: the descriptor cannot be statted.
    return null;
  }
}

/// Stats [fd] on Linux (see [_jitFstatFd]): `statx` with `AT_EMPTY_PATH`
/// first, `fstat` with the 64-bit `struct stat` layout where `statx` is
/// unavailable or refuses the descriptor (see [jitLinuxStatOffsets]),
/// `__fxstat64` with `_STAT_VER` where the plain symbol is missing (see
/// [jitLinuxStat64Calls]). Null when none stats the descriptor.
JitStat? _jitLinuxFstatFd(
  ffi.DynamicLibrary lib,
  int fd,
  ffi.Pointer<ffi.Uint8> buf,
) {
  final statx = _jitBindStatx(lib);
  if (statx != null) {
    final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
    final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
    final empty = malloc(1);
    if (empty == ffi.nullptr) return null;
    try {
      empty.asTypedList(1)[0] = 0;
      const emptyPath = 0x1000;
      const basicStats = 0x7ff;
      if (statx(fd, empty, emptyPath, basicStats, buf) == 0) {
        return jitDecodeStatx(buf.asTypedList(256));
      }
    } finally {
      free(empty);
    }
  }
  final calls = jitLinuxStat64Calls(abi: ffi.Abi.current());
  if (calls == null) return null;
  final statted = _jitStat64Fallback(
    plain: () => lib.lookupFunction<_FstatNative, _FstatDart>('fstat')(fd, buf),
    versioned: () => lib.lookupFunction<_Fxstat64Native, _Fxstat64Dart>(
      calls.fstat,
    )(calls.ver, fd, buf),
  );
  if (!statted) return null;
  return jitDecodeLinuxStat(buf.asTypedList(64), abi: ffi.Abi.current());
}

/// The fail-closed opening for [path]: its type and owner for the error, and
/// whether the `chmod 0666` remedy applies. That remedy applies only when the
/// lock's own mode is what denies us access (a regular file the open refused
/// for writing); a symlink, directory, FIFO or other entry, or any other
/// failure, wants its owner (or root) to remove it instead. [linkCount] is
/// the entry's hard-link count where a link was refused (see [_jitAdoptFd]),
/// else 0: a refused entry names its count in the detail, and the error names
/// removing the extra links instead of opening for writing.
JitLockOpen _jitLockFailure(
  String path, {
  required bool accessDenied,
  int linkCount = 0,
}) {
  final info = jitStatEntry(path);
  if (info == null) {
    return (
      fd: -1,
      detail: 'entry at $path of unknown ownership',
      chmodRemedy: false,
      ownEntry: false,
      publishFailed: false,
      linkRefused: false,
    );
  }
  final owner = jitUserName(info.uid);
  final who = owner == null ? 'uid ${info.uid}' : 'uid ${info.uid} ($owner)';
  final refused = linkCount > 1;
  return (
    fd: -1,
    detail: refused
        ? '${info.kind} at $path owned by $who with $linkCount hard links'
        : '${info.kind} at $path owned by $who',
    chmodRemedy: accessDenied && info.kind == 'regular file',
    ownEntry: info.uid == jitOwnUid(),
    publishFailed: false,
    linkRefused: refused,
  );
}

/// The fail-closed opening where the publish itself failed (see
/// [_jitPublishOnce]): the temporary could not be created, or the rename (or
/// `link` where rename is unavailable) refused it for any reason but a lost
/// race. Where an entry is now at [path] it is
/// described as in [_jitLockFailure] (a directory refusing the link still
/// wants removal); where nothing is there the detail says the lock could not
/// be published, with the `errno`, rather than inventing an entry of unknown
/// ownership with an owner to remove it. The `chmod 0666` remedy never
/// applies: a mode-denied winner surfaces through the open, not the publish.
JitLockOpen _jitPublishFailure(String path, {required int errno}) {
  final info = jitStatEntry(path);
  if (info == null) {
    return (
      fd: -1,
      detail: 'the lock at $path could not be published there (errno $errno)',
      chmodRemedy: false,
      ownEntry: false,
      publishFailed: true,
      linkRefused: false,
    );
  }
  final owner = jitUserName(info.uid);
  final who = owner == null ? 'uid ${info.uid}' : 'uid ${info.uid} ($owner)';
  return (
    fd: -1,
    detail:
        'the ${info.kind} at $path owned by $who blocks the lock publish '
        '(errno $errno)',
    chmodRemedy: false,
    ownEntry: info.uid == jitOwnUid(),
    publishFailed: true,
    linkRefused: false,
  );
}

void _jitFchmod(ffi.DynamicLibrary lib, int fd, int mode) {
  final fchmod = lib.lookupFunction<_FchmodNative, _FchmodDart>('fchmod');
  fchmod(fd, mode);
}

void _jitClose(ffi.DynamicLibrary lib, int fd) {
  final close = lib.lookupFunction<_CloseNative, _CloseDart>('close');
  close(fd);
}

/// Allocates a zero-terminated UTF-8 copy of [path] with libc `malloc`.
/// The caller frees it with libc `free`.
ffi.Pointer<ffi.Uint8> _jitCString(
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
