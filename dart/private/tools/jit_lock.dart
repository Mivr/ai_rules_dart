// Opens and locks the shared JIT training lock by file descriptor.
//
// The keyed training lock (see `app_jit_snapshot.dart`) is one fixed path per
// output shared by every user on the host: it must open for a second user
// after the first created it. Linux's `fs.protected_regular` refuses O_CREAT
// on another user's file in sticky world-writable /tmp, so an existing lock
// opens without O_CREAT (read-write, O_NOFOLLOW), and only a missing lock is
// published: a uniquely named temporary in the same directory is created
// (O_CREAT|O_EXCL|O_NOFOLLOW), made 0666 through its descriptor whatever the
// umask, and hard-linked over the lock path, so the lock appears at its final
// 0666 mode atomically and never at a mode another user cannot open. Losing
// the publish race falls back to the no-create open. After opening, the
// descriptor is statted and kept only when it is a regular file with link count
// 1: a hard link planted at the lock path has another entry pointing at the
// same file, so adopting it would serialize nothing and, worse, the adopted
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

/// A path-based stat result: the entry kind (see [jitEntryKind]), its owner
/// uid, its full POSIX mode, its hard-link count and its file identity (see
/// [JitFileId]), without following symlinks.
typedef JitStat = ({String kind, int uid, int mode, int nlink, JitFileId id});

/// A file identity for the held-lock re-check (see [jitFdMatchesPath]): the
/// device and inode the stat layouts report, without following symlinks. The
/// halves' meaning is layout-specific (`statx` reports the device major and
/// minor numbers, the `struct stat` layouts the device number's low and high
/// halves), so an id only ever compares against one from the same call family
/// on the same host; any divergence fails closed.
typedef JitFileId = ({int devA, int devB, int inoLo, int inoHi});

/// The flags opening the lock: without O_CREAT for an existing lock, with
/// O_CREAT|O_EXCL to create a missing one. Both carry O_NOFOLLOW, O_NONBLOCK
/// and O_CLOEXEC and never follow the final component.
typedef JitOpenFlags = ({int noCreate, int create});

/// The result of opening the lock: a held descriptor [fd] (nonnegative), or a
/// fail-closed [detail] naming the entry plus which remedy applies.
/// [chmodRemedy] is true only when the lock's own mode is what denies us
/// access (a regular file we cannot open for writing); anything else wants
/// the entry removed. [ownEntry] tells a mode-denied remedy whether the entry
/// is ours to chmod ourselves. [publishFailed] is true only when the publish
/// itself failed (see [_jitPublishFailure]): there may be no entry at all, so
/// neither the `chmod 0666` remedy nor an owner-removal remedy applies.
typedef JitLockOpen = ({
  int fd,
  String detail,
  bool chmodRemedy,
  bool ownEntry,
  bool publishFailed,
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

/// The `fstat` symbol reading the 64-bit `struct stat` layout (see
/// [_jitFstatFd]): a pure function of OS and architecture, the same choice as
/// [jitLstatSymbol]. On Intel macOS the plain `fstat` symbol is the legacy
/// 32-bit-inode variant (whose owner and type fields sit elsewhere), so the
/// 64-bit one is bound explicitly; every other host reads the 64-bit layout
/// through the plain symbol.
String jitFstatSymbol({required bool isMacOS, required bool isX64}) {
  if (isMacOS && isX64) return 'fstat\$INODE64';
  return 'fstat';
}

/// Offsets of the link count, mode and owner uid in the Linux 64-bit `struct
/// stat` (see [_jitFstatFd]): a pure function of the architecture. The 64-bit
/// Linux ABIs (x86_64, arm64, 64-bit RISC-V) share one layout for these fields
/// (the link count a little-endian u64 at 16, the mode a little-endian u32 at
/// 24, the uid a little-endian u32 at 28); a 32-bit ABI returns null, and the
/// caller fails closed rather than decoding a layout that differs per ABI and
/// per glibc large-file redirection. All supported hosts are little-endian.
({int nlink, int mode, int uid})? jitLinuxStatOffsets({required ffi.Abi abi}) {
  switch (abi) {
    case ffi.Abi.linuxX64:
    case ffi.Abi.linuxArm64:
    case ffi.Abi.linuxRiscv64:
      return (nlink: 16, mode: 24, uid: 28);
    default:
      return null;
  }
}

/// Decodes 64 bytes of Linux 64-bit `struct stat` (see [jitLinuxStatOffsets]):
/// a pure function of the bytes and the ABI, so tests pin the layout without
/// the syscall. The link count is 64 bits wide; only its low half is kept (no
/// host links a file more than 2^32 times). The identity is the device
/// number's halves (u64 at 0) with the inode (u64 at 8). Null on a 32-bit ABI
/// (see [jitLinuxStatOffsets]).
JitStat? jitDecodeLinuxStat(List<int> bytes, {required ffi.Abi abi}) {
  final offsets = jitLinuxStatOffsets(abi: abi);
  if (offsets == null) return null;
  final mode = _jitU32(bytes, offsets.mode);
  return (
    kind: jitEntryKind(mode),
    uid: _jitU32(bytes, offsets.uid),
    mode: mode,
    nlink: _jitU32(bytes, offsets.nlink),
    id: (
      devA: _jitU32(bytes, 0),
      devB: _jitU32(bytes, 4),
      inoLo: _jitU32(bytes, 8),
      inoHi: _jitU32(bytes, 12),
    ),
  );
}

/// O_CLOEXEC for the lock and every temporary descriptor (see [jitOpenFlags]
/// and [jitReadFlags]): a pure function of the OS. The value is 0x80000 on
/// Linux (02000000, the same on every ABI) and 0x1000000 on macOS. Without it
/// a spawned training subprocess would inherit the lock descriptor, keeping
/// the file description open in the child past our close.
int jitCloexecFlag({required bool isMacOS}) => isMacOS ? 0x1000000 : 0x80000;

/// The flags opening the lock (see [JitOpenFlags]): a pure function of the OS
/// and ABI. O_RDWR is 2, O_CREAT is 0x40 (Linux) or 0x200 (macOS), O_EXCL is
/// 0x80 (Linux) or 0x800 (macOS), and O_NONBLOCK is 0x800 (Linux) or 0x4
/// (macOS). O_CLOEXEC rides on both (see [jitCloexecFlag]), so no spawned
/// training subprocess inherits the lock or a temporary. O_NOFOLLOW is 0x100
/// on macOS but architecture-specific on Linux:
/// 0x20000 on x86_64, IA-32 and RISC-V (asm-generic), 0x8000 on 32-bit ARM and
/// arm64, whose headers keep the 32-bit numbering for compat (0x20000 there is
/// O_LARGEFILE, which would follow symlinks). A Linux ABI whose values are not
/// pinned here throws [UnsupportedError]: the caller fails closed rather than
/// opening with guessed flags (0x40000 would be O_NOATIME, which the kernel
/// refuses with EPERM on a file the caller does not own, locking a second
/// user out of the first user's lock again).
JitOpenFlags jitOpenFlags({required bool isMacOS, required ffi.Abi abi}) {
  final cloexec = jitCloexecFlag(isMacOS: isMacOS);
  if (isMacOS) {
    // O_RDWR|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC, plus O_CREAT|O_EXCL to create.
    return (
      noCreate: 0x2 | 0x100 | 0x4 | cloexec,
      create: 0x2 | 0x100 | 0x4 | 0x200 | 0x800 | cloexec,
    );
  }
  final nofollow = _linuxNoFollow(abi);
  // O_RDWR|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC, plus O_CREAT|O_EXCL to create.
  return (
    noCreate: 0x2 | nofollow | 0x800 | cloexec,
    create: 0x2 | nofollow | 0x800 | 0x40 | 0x80 | cloexec,
  );
}

/// Linux O_NOFOLLOW by ABI (see [jitOpenFlags]). Throws [UnsupportedError] for
/// a Linux ABI whose headers are not pinned here: opening with guessed flags
/// is worse than failing closed.
int _linuxNoFollow(ffi.Abi abi) {
  switch (abi) {
    case ffi.Abi.linuxX64:
    case ffi.Abi.linuxIA32:
    case ffi.Abi.linuxRiscv32:
    case ffi.Abi.linuxRiscv64:
      // asm-generic headers number O_NOFOLLOW 0400000.
      return 0x20000;
    case ffi.Abi.linuxArm:
    case ffi.Abi.linuxArm64:
      // 32-bit ARM headers number O_NOFOLLOW 0100000, and arm64 keeps that
      // numbering for compat (its 0400000 is O_LARGEFILE).
      return 0x8000;
    default:
      throw UnsupportedError(
        'app_jit_snapshot: no pinned O_NOFOLLOW for Linux ABI $abi, '
        'refusing to open the training lock',
      );
  }
}

/// The read-only flags for the holder-PID lookup (see [jitLockHolderPid]):
/// O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC without O_CREAT, so a symlink or FIFO at
/// the path reports no holder instead of blocking or being followed, and no
/// spawned training subprocess inherits the lookup descriptor. Throws as
/// [jitOpenFlags] on a Linux ABI whose values are not pinned.
int jitReadFlags({required bool isMacOS, required ffi.Abi abi}) {
  final cloexec = jitCloexecFlag(isMacOS: isMacOS);
  if (isMacOS) return 0x0 | 0x100 | 0x4 | cloexec;
  return _linuxNoFollow(abi) | 0x800 | cloexec;
}

/// Our uid, for telling our own entries from another user's: only our own
/// lock gets the `chmod 0666` remedy, and only our own stale directories get
/// removed.
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
/// [jitEntryKind]), its owner uid, its full mode and its hard-link count for
/// the fail-closed error. Null when the entry cannot be statted or the platform
/// has no suitable call.
///
/// On Linux this is `statx(2)`, whose `struct statx` layout is the same on
/// every architecture (the link count is a little-endian u32 at offset 16, the
/// uid a little-endian u32 at offset 20, the mode a little-endian u16 at offset
/// 28), falling back to `lstat(2)` with the 64-bit `struct stat` layout where
/// `statx` is unavailable (see [jitLinuxStatOffsets]); on macOS it is `lstat(2)`
/// with the 64-bit `struct stat` layout (the mode at offset 4, the link count
/// at offset 6, the uid at offset 16; see [jitLstatSymbol]). All supported
/// hosts are little-endian. Metadata only: the entry's content is never read.
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
        if (Platform.isLinux) return _jitLinuxStatPath(lib, pathPtr, buf);
        if (Platform.isMacOS) {
          final symbol = jitLstatSymbol(
            isMacOS: true,
            isX64: ffi.Abi.current() == ffi.Abi.macosX64,
          );
          final lstat = lib.lookupFunction<_LstatNative, _LstatDart>(symbol);
          if (lstat(pathPtr, buf) != 0) return null;
          return _jitDecodeMacStat(buf.asTypedList(64));
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

/// Stats [pathPtr] on Linux (see [jitStatEntry]): `statx(2)` first, `lstat(2)`
/// with the 64-bit `struct stat` layout where `statx` is unavailable or
/// refuses the entry (see [jitLinuxStatOffsets]). Null when neither stats the
/// entry.
JitStat? _jitLinuxStatPath(
  ffi.DynamicLibrary lib,
  ffi.Pointer<ffi.Uint8> pathPtr,
  ffi.Pointer<ffi.Uint8> buf,
) {
  try {
    final statx = lib.lookupFunction<_StatxNative, _StatxDart>('statx');
    const atFdcwd = -100;
    const nofollow = 0x100;
    const basicStats = 0x7ff;
    if (statx(atFdcwd, pathPtr, nofollow, basicStats, buf) == 0) {
      return _jitDecodeStatx(buf.asTypedList(64));
    }
  } on ArgumentError {
    // No `statx` in this libc (glibc older than 2.28): fall through to lstat.
  }
  try {
    final lstat = lib.lookupFunction<_LstatNative, _LstatDart>('lstat');
    if (lstat(pathPtr, buf) != 0) return null;
  } on ArgumentError {
    // Neither call exists on this libc: nothing statted.
    return null;
  }
  return jitDecodeLinuxStat(buf.asTypedList(64), abi: ffi.Abi.current());
}

/// Decodes 64 bytes of `struct statx` (Linux, architecture-independent; see
/// [jitStatEntry]): a pure function of the bytes, shared by the path and
/// descriptor stats. The identity is the device major and minor (u32 at 136
/// and 140) with the inode (u64 at 32).
JitStat _jitDecodeStatx(List<int> bytes) {
  final mode = _jitU16(bytes, 28);
  return (
    kind: jitEntryKind(mode),
    uid: _jitU32(bytes, 20),
    mode: mode,
    nlink: _jitU32(bytes, 16),
    id: (
      devA: _jitU32(bytes, 136),
      devB: _jitU32(bytes, 140),
      inoLo: _jitU32(bytes, 32),
      inoHi: _jitU32(bytes, 36),
    ),
  );
}

/// Decodes 64 bytes of macOS 64-bit `struct stat` (see [jitStatEntry]): a pure
/// function of the bytes, shared by the path and descriptor stats. The
/// identity is the device number's halves (u64 at 0; read unsigned, compared
/// as bits) with the inode (u64 at 8).
JitStat _jitDecodeMacStat(List<int> bytes) {
  final mode = _jitU16(bytes, 4);
  return (
    kind: jitEntryKind(mode),
    uid: _jitU32(bytes, 16),
    mode: mode,
    nlink: _jitU16(bytes, 6),
    id: (
      devA: _jitU32(bytes, 0),
      devB: _jitU32(bytes, 4),
      inoLo: _jitU32(bytes, 8),
      inoHi: _jitU32(bytes, 12),
    ),
  );
}

/// Opens the lock at [path] by file descriptor, for the caller to take with
/// [jitTryExclusiveLock] and release with [jitUnlockAndClose].
///
/// An existing lock opens read-write with O_NOFOLLOW and without O_CREAT and
/// is kept only when it is a regular file with link count 1; a missing lock is
/// published at 0666 through a uniquely named temporary linked over the lock
/// path (see [jitCreateAndPublishLock]), so the lock never exists at a mode
/// another user cannot open, whatever the umask or the scheduling. Losing the
/// publish race falls back to the no-create open. An adopted lock is never
/// chmodded: only the temporary the publisher created itself with O_EXCL ever
/// has its permissions changed. Nothing is followed and nothing is created
/// through: a symlink, directory, FIFO, hard link or other non-regular entry
/// fails closed with its path, type and owner in [JitLockOpen.detail].
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
/// its descriptor whatever the umask, then hard-linked over [path], which
/// fails with EEXIST when another process published first (then that lock
/// opens without O_CREAT, as today). The temporary is unlinked on every path,
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
/// makes it 0666, links it over [path] and unlinks it, keeping the linked
/// descriptor. [retry] is true only when the temporary's own name was taken.
/// A temporary that cannot be created, or a `link` the kernel refuses for any
/// reason but a lost race, reports the publish itself (see
/// [_jitPublishFailure]), never an entry that may not be there.
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
  final winner = _jitOpen(lib, path, flags.noCreate, 0);
  if (winner.fd >= 0) {
    return (result: _jitAdoptFd(lib, path, winner.fd), retry: false);
  }
  return (
    result: _jitLockFailure(path, accessDenied: winner.errno == _eacces),
    retry: false,
  );
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

/// The `l_pid` offset in `struct flock` for the holder-PID lookup (see
/// [jitLockHolderPid]): a pure function of the OS and ABI. On macOS the PID is
/// a little-endian i32 at 16; on Linux a little-endian i32 at 24 on the 64-bit
/// ABIs, where `l_start`/`l_len` are 64 bits wide, and at 12 on the 32-bit
/// ones, where they are 32 bits wide (reading at the 64-bit offset there would
/// return padding as the PID). Throws [UnsupportedError] for a Linux ABI whose
/// layout is not pinned here, and the caller reports no holder.
int jitFlockPidOffset({required bool isMacOS, required ffi.Abi abi}) {
  if (isMacOS) return 16;
  switch (abi) {
    case ffi.Abi.linuxX64:
    case ffi.Abi.linuxArm64:
    case ffi.Abi.linuxRiscv64:
      return 24;
    case ffi.Abi.linuxIA32:
    case ffi.Abi.linuxArm:
    case ffi.Abi.linuxRiscv32:
      return 12;
    default:
      throw UnsupportedError(
        'app_jit_snapshot: no pinned struct flock layout for Linux ABI $abi, '
        'refusing to read the training lock holder',
      );
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
/// little-endian i32 at the offset [jitFlockPidOffset] pins, on macOS the
/// start/len are two i64 at offsets 0/8, the PID an i32 at offset 16 and the
/// type an i16 at offset 20.
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

/// Keeps an opened lock descriptor only when it is a regular file with link
/// count 1. Anything else is closed and fails closed with its path, type and
/// owner: a hard link planted at the lock path names another entry pointing at
/// the same file, so the descriptor is dropped without touching permissions
/// (relaxing them would widen the linked-to file for its owner).
JitLockOpen _jitAdoptFd(ffi.DynamicLibrary lib, String path, int fd) {
  JitStat? info;
  try {
    info = _jitFstatFd(lib, fd);
  } on ArgumentError {
    // This libc has no stat call for a descriptor: nothing to keep.
    info = null;
  }
  if (info == null || info.kind != 'regular file' || info.nlink != 1) {
    _jitClose(lib, fd);
    return _jitLockFailure(path, accessDenied: false);
  }
  return (
    fd: fd,
    detail: '',
    chmodRemedy: false,
    ownEntry: true,
    publishFailed: false,
  );
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
  } on ArgumentError {
    // This libc has no stat call for a descriptor: nothing verified.
    held = null;
  }
  if (held == null) return false;
  final current = jitStatEntry(path);
  if (current == null) return false;
  final a = held.id;
  final b = current.id;
  return a.devA == b.devA &&
      a.devB == b.devB &&
      a.inoLo == b.inoLo &&
      a.inoHi == b.inoHi;
}

/// Stats an open descriptor itself: `statx` with `AT_EMPTY_PATH` on Linux
/// (whose `struct statx` layout is architecture-independent), falling back to
/// `fstat` with the 64-bit `struct stat` layout where `statx` is unavailable
/// or refuses the descriptor (glibc older than 2.28; see
/// [jitLinuxStatOffsets]); on macOS `fstat` with the 64-bit `struct stat`
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
      final symbol = jitFstatSymbol(
        isMacOS: true,
        isX64: ffi.Abi.current() == ffi.Abi.macosX64,
      );
      final fstat = lib.lookupFunction<_FstatNative, _FstatDart>(symbol);
      if (fstat(fd, buf) != 0) return null;
      return _jitDecodeMacStat(buf.asTypedList(64));
    }
    return null;
  } finally {
    free(buf);
  }
}

/// Stats [fd] on Linux (see [_jitFstatFd]): `statx` with `AT_EMPTY_PATH`
/// first, `fstat` with the 64-bit `struct stat` layout where `statx` is
/// unavailable or refuses the descriptor (see [jitLinuxStatOffsets]). Null
/// when neither stats the descriptor.
JitStat? _jitLinuxFstatFd(
  ffi.DynamicLibrary lib,
  int fd,
  ffi.Pointer<ffi.Uint8> buf,
) {
  try {
    final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
    final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
    final statx = lib.lookupFunction<_StatxNative, _StatxDart>('statx');
    final empty = malloc(1);
    if (empty == ffi.nullptr) return null;
    try {
      empty.asTypedList(1)[0] = 0;
      const emptyPath = 0x1000;
      const basicStats = 0x7ff;
      if (statx(fd, empty, emptyPath, basicStats, buf) == 0) {
        return _jitDecodeStatx(buf.asTypedList(64));
      }
    } finally {
      free(empty);
    }
  } on ArgumentError {
    // No `statx` in this libc (glibc older than 2.28): fall through to fstat.
  }
  try {
    final fstat = lib.lookupFunction<_FstatNative, _FstatDart>('fstat');
    if (fstat(fd, buf) != 0) return null;
  } on ArgumentError {
    // Neither call exists on this libc: nothing statted.
    return null;
  }
  return jitDecodeLinuxStat(buf.asTypedList(64), abi: ffi.Abi.current());
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
      publishFailed: false,
    );
  }
  final owner = jitUserName(info.uid);
  final who = owner == null ? 'uid ${info.uid}' : 'uid ${info.uid} ($owner)';
  return (
    fd: -1,
    detail: '${info.kind} at $path owned by $who',
    chmodRemedy: accessDenied && info.kind == 'regular file',
    ownEntry: info.uid == jitOwnUid(),
    publishFailed: false,
  );
}

/// The fail-closed opening where the publish itself failed (see
/// [_jitPublishOnce]): the temporary could not be created, or `link` refused
/// it for any reason but a lost race. Where an entry is now at [path] it is
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
