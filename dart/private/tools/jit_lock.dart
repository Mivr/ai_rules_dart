// Opens and locks the shared JIT training lock by file descriptor.
//
// The keyed training lock (see `app_jit_snapshot.dart`) is one fixed path per
// output shared by every user on the host: it must open for a second user
// after the first created it. Linux's `fs.protected_regular` refuses O_CREAT
// on another user's file in sticky world-writable /tmp, so an existing lock
// opens without O_CREAT (read-write, O_NOFOLLOW), and only a missing lock is
// created (O_CREAT|O_EXCL|O_NOFOLLOW, then 0666 through the descriptor
// whatever the umask). Losing the create race falls back to the no-create
// open. After opening, the descriptor is statted and anything but a regular
// file is refused; a lock of our own is repaired to 0666 through the
// descriptor. No path-based check precedes the open and no chmod by path
// touches the lock, so a symlink, directory, FIFO or other non-regular entry
// at the lock path is never followed and never created through: the open
// fails closed instead.
//
// The exclusive lock is an `fcntl` whole-file write lock on the descriptor,
// the same domain `File.lockSync` takes, so trainings using either contend.
// All metadata reads (stat, owner name) never read entry content.
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

/// A path-based stat result: the entry kind (see [jitEntryKind]), its owner
/// uid and its full POSIX mode, without following symlinks.
typedef JitStat = ({String kind, int uid, int mode});

/// The flags opening the lock: without O_CREAT for an existing lock, with
/// O_CREAT|O_EXCL to create a missing one. Both carry O_NOFOLLOW and
/// O_NONBLOCK and never follow the final component.
typedef JitOpenFlags = ({int noCreate, int create});

/// The result of opening the lock: a held descriptor [fd] (nonnegative), or a
/// fail-closed [detail] naming the entry plus which remedy applies.
/// [chmodRemedy] is true only when the lock's own mode is what denies us
/// access (a regular file we cannot open for writing); anything else wants
/// the entry removed. [ownEntry] tells a mode-denied remedy whether the entry
/// is ours to chmod ourselves.
typedef JitLockOpen = ({
  int fd,
  String detail,
  bool chmodRemedy,
  bool ownEntry,
});

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
typedef _LstatDart = int Function(
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

/// The `lstat` symbol reading the 64-bit `struct stat` layout (see
/// [jitStatEntry]): a pure function of OS and architecture. On Intel macOS the
/// plain `lstat` symbol is the legacy 32-bit-inode variant (whose owner and
/// type fields sit elsewhere), so the 64-bit one is bound explicitly; every
/// other host reads the 64-bit layout through the plain symbol.
String jitLstatSymbol({required bool isMacOS, required bool isX64}) {
  if (isMacOS && isX64) return 'lstat\$INODE64';
  return 'lstat';
}

/// The flags opening the lock (see [JitOpenFlags]): a pure function of the OS.
/// Linux and macOS number O_CREAT, O_EXCL, O_NOFOLLOW and O_NONBLOCK
/// differently; O_RDWR is 2 on both.
JitOpenFlags jitOpenFlags({required bool isMacOS}) {
  if (isMacOS) {
    // O_RDWR|O_NOFOLLOW|O_NONBLOCK, plus O_CREAT|O_EXCL to create.
    return (
      noCreate: 0x2 | 0x100 | 0x4,
      create: 0x2 | 0x100 | 0x4 | 0x200 | 0x800,
    );
  }
  // O_RDWR|O_NOFOLLOW|O_NONBLOCK, plus O_CREAT|O_EXCL to create.
  return (
    noCreate: 0x2 | 0x40000 | 0x800,
    create: 0x2 | 0x40000 | 0x800 | 0x40 | 0x80,
  );
}

/// Our uid, for telling our own lock (whose mode we repair) from another
/// user's, and our own stale directories from theirs.
int jitOwnUid() {
  if (Platform.isWindows) return -1;
  final lib = ffi.DynamicLibrary.process();
  final geteuid = lib.lookupFunction<_GeteuidNative, _GeteuidDart>('geteuid');
  return geteuid();
}

/// Names a POSIX file-type bit pattern for the fail-closed error.
String jitEntryKind(int mode) {
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
/// [jitEntryKind]), its owner uid and its full mode for the fail-closed
/// error. Null when the entry cannot be statted or the platform has no
/// suitable call.
///
/// On Linux this is `statx(2)`, whose `struct statx` layout is the same on
/// every architecture (the uid is a little-endian u32 at offset 20, the mode
/// a little-endian u16 at offset 28); on macOS it is `lstat(2)` with the
/// 64-bit `struct stat` layout (the mode at offset 4, the uid at offset 16;
/// see [jitLstatSymbol]). All supported hosts are little-endian. Metadata
/// only: the entry's content is never read.
JitStat? jitStatEntry(String path) {
  if (Platform.isWindows) return null;
  try {
    final lib = ffi.DynamicLibrary.process();
    final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
    final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
    final pathPtr = _jitCString(malloc, path);
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
          final mode = _jitU16(bytes, 28);
          return (
            kind: jitEntryKind(mode),
            uid: _jitU32(bytes, 20),
            mode: mode,
          );
        }
        if (Platform.isMacOS) {
          final symbol = jitLstatSymbol(
            isMacOS: true,
            isX64: ffi.Abi.current() == ffi.Abi.macosX64,
          );
          final lstat = lib.lookupFunction<_LstatNative, _LstatDart>(symbol);
          if (lstat(pathPtr, buf) != 0) return null;
          final bytes = buf.asTypedList(64);
          final mode = _jitU16(bytes, 4);
          return (
            kind: jitEntryKind(mode),
            uid: _jitU32(bytes, 16),
            mode: mode,
          );
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

/// Opens the lock at [path] by file descriptor, for the caller to take with
/// [jitTryExclusiveLock] and release with [jitUnlockAndClose].
///
/// An existing lock opens read-write with O_NOFOLLOW and without O_CREAT and
/// is kept only when it is a regular file; a missing lock is created with
/// O_CREAT|O_EXCL|O_NOFOLLOW at 0666 and made 0666 through the descriptor
/// whatever the umask, so a second user opens the first user's lock even
/// under `fs.protected_regular`. Losing the create race falls back to the
/// no-create open. A lock of our own is repaired to 0666 through the
/// descriptor. Nothing is followed and nothing is created through: a symlink,
/// directory, FIFO or other non-regular entry fails closed with its path,
/// type and owner in [JitLockOpen.detail].
JitLockOpen jitOpenLock(String path) {
  if (Platform.isWindows) {
    return (
      fd: -1,
      detail: 'entry at $path of unknown ownership',
      chmodRemedy: false,
      ownEntry: false,
    );
  }
  final lib = ffi.DynamicLibrary.process();
  final flags = jitOpenFlags(isMacOS: Platform.isMacOS);
  final first = _jitOpen(lib, path, flags.noCreate, 0);
  if (first.fd >= 0) return _jitAdoptFd(lib, path, first.fd);
  if (first.errno != _enoent) {
    return _jitLockFailure(path, accessDenied: first.errno == _eacces);
  }
  final created = _jitOpen(lib, path, flags.create, 0x1b6);
  if (created.fd >= 0) {
    _jitFchmod(lib, created.fd, 0x1b6);
    return _jitAdoptFd(lib, path, created.fd);
  }
  if (created.errno == _eexist) {
    // Lost the create race: open the winner's lock without creating.
    final retry = _jitOpen(lib, path, flags.noCreate, 0);
    if (retry.fd >= 0) return _jitAdoptFd(lib, path, retry.fd);
    return _jitLockFailure(path, accessDenied: retry.errno == _eacces);
  }
  return _jitLockFailure(path, accessDenied: created.errno == _eacces);
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
    // `struct flock` layout differs by OS: on Linux the type is a
    // little-endian i16 at offset 0 (F_SETLK is 6), on macOS the start/len are
    // two i64 at offsets 0/8, the PID an i32 at offset 16 and the type an i16
    // at offset 20 (F_SETLK is 8). `fcntl` is variadic
    // (`int fcntl(int, int, ...)`), so its `struct flock` pointer binds through
    // `ffi.VarArgs`: a fixed binding passes the pointer in a register that
    // `fcntl` never reads on Apple arm64. All supported hosts are little-endian.
    final view = ByteData.sublistView(buf.asTypedList(32));
    final int cmd;
    if (Platform.isMacOS) {
      view.setInt16(20, 1, Endian.little);
      cmd = 8;
    } else {
      view.setInt16(0, 1, Endian.little);
      cmd = 6;
    }
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
/// refuses, with the holder's PID. The `struct flock` layout differs by OS:
/// on Linux the type is a little-endian i16 at offset 0 and the PID a
/// little-endian i32 at offset 20+4, on macOS the start/len are two i64 at
/// offsets 0/8, the PID an i32 at offset 16 and the type an i16 at offset 20.
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
        // on a FIFO.
        final readFlags = Platform.isMacOS
            ? (0x0 | 0x100 | 0x4)
            : (0 | 0x40000 | 0x800);
        final fd = open(pathPtr, readFlags, 0);
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

// `errno` values distinguishing the open failures (see [jitOpenLock]):
// EACCES for a mode-denied open, ENOENT for a missing lock, EEXIST for a
// lost create race. All three read the same on Linux and macOS.
const _eacces = 13;
const _enoent = 2;
const _eexist = 17;

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

/// Keeps an opened lock descriptor only when it is a regular file, repairing
/// a lock of our own to 0666 through it. Anything else is closed and fails
/// closed with its path, type and owner.
JitLockOpen _jitAdoptFd(ffi.DynamicLibrary lib, String path, int fd) {
  JitStat? info;
  try {
    info = _jitFstatFd(lib, fd);
  } on ArgumentError {
    // This libc has no stat call for a descriptor: nothing to keep.
    info = null;
  }
  if (info == null || info.kind != 'regular file') {
    _jitClose(lib, fd);
    return _jitLockFailure(path, accessDenied: false);
  }
  if (info.uid == jitOwnUid()) {
    _jitFchmod(lib, fd, 0x1b6);
  }
  return (fd: fd, detail: '', chmodRemedy: false, ownEntry: true);
}

/// Stats an open descriptor itself: `statx` with `AT_EMPTY_PATH` on Linux
/// (whose `struct statx` layout is architecture-independent), `fstat` on
/// macOS (one 64-bit `struct stat` layout on both architectures). Null when
/// the descriptor cannot be statted.
JitStat? _jitFstatFd(ffi.DynamicLibrary lib, int fd) {
  final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
  final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
  final buf = malloc(256);
  if (buf == ffi.nullptr) return null;
  try {
    buf.asTypedList(256).fillRange(0, 256, 0);
    if (Platform.isLinux) {
      final statx = lib.lookupFunction<_StatxNative, _StatxDart>('statx');
      final empty = malloc(1);
      if (empty == ffi.nullptr) return null;
      try {
        empty.asTypedList(1)[0] = 0;
        const emptyPath = 0x1000;
        const basicStats = 0x7ff;
        if (statx(fd, empty, emptyPath, basicStats, buf) != 0) return null;
      } finally {
        free(empty);
      }
      final bytes = buf.asTypedList(64);
      final mode = _jitU16(bytes, 28);
      return (kind: jitEntryKind(mode), uid: _jitU32(bytes, 20), mode: mode);
    }
    if (Platform.isMacOS) {
      final fstat = lib.lookupFunction<_FstatNative, _FstatDart>('fstat');
      if (fstat(fd, buf) != 0) return null;
      final bytes = buf.asTypedList(64);
      final mode = _jitU16(bytes, 4);
      return (kind: jitEntryKind(mode), uid: _jitU32(bytes, 16), mode: mode);
    }
    return null;
  } finally {
    free(buf);
  }
}

/// The fail-closed opening for [path]: its type and owner for the error, and
/// whether the `chmod 0666` remedy applies. That remedy applies only when the
/// lock's own mode is what denies us access (a regular file the open refused
/// for writing); a symlink, directory, FIFO or other entry, or any other
/// failure, wants its owner (or root) to remove it instead.
JitLockOpen _jitLockFailure(String path, {required bool accessDenied}) {
  final info = jitStatEntry(path);
  if (info == null) {
    return (
      fd: -1,
      detail: 'entry at $path of unknown ownership',
      chmodRemedy: false,
      ownEntry: false,
    );
  }
  final owner = jitUserName(info.uid);
  final who = owner == null ? 'uid ${info.uid}' : 'uid ${info.uid} ($owner)';
  return (
    fd: -1,
    detail: '${info.kind} at $path owned by $who',
    chmodRemedy: accessDenied && info.kind == 'regular file',
    ownEntry: info.uid == jitOwnUid(),
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

int _jitU32(List<int> bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

int _jitU16(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);
