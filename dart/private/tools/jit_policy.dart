// Pure host facts for the shared JIT training lock (see `jit_lock.dart`):
// pinned flag values, call choices, stat-layout decoders and name shapes as
// pure functions of the OS and ABI, so tests pin them without syscalls. Only
// `dart:ffi`'s ABI enum is imported: nothing here touches a host.
import 'dart:ffi' as ffi;

/// A path-based stat result: the entry kind (see [jitEntryKind]), its owner
/// uid, its full POSIX mode, its hard-link count and its file identity (see
/// [JitFileId]), without following symlinks.
typedef JitStat = ({String kind, int uid, int mode, int nlink, JitFileId id});

/// A file identity for the held-lock re-check (see `jitFdMatchesPath`): the
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

/// The `lstat` symbol reading the 64-bit `struct stat` layout (see
/// `jitStatEntry`): a pure function of OS and architecture. On Intel macOS the
/// plain `lstat` symbol is the legacy 32-bit-inode variant (whose owner and
/// type fields sit elsewhere), so the 64-bit one is bound explicitly; every
/// other host reads the 64-bit layout through the plain symbol.
String jitLstatSymbol({required bool isMacOS, required bool isX64}) {
  if (isMacOS && isX64) return 'lstat\$INODE64';
  return 'lstat';
}

/// The `fstat` symbol reading the 64-bit `struct stat` layout (see
/// `_jitFstatFd`): a pure function of OS and architecture, the same choice as
/// [jitLstatSymbol]. On Intel macOS the plain `fstat` symbol is the legacy
/// 32-bit-inode variant (whose owner and type fields sit elsewhere), so the
/// 64-bit one is bound explicitly; every other host reads the 64-bit layout
/// through the plain symbol.
String jitFstatSymbol({required bool isMacOS, required bool isX64}) {
  if (isMacOS && isX64) return 'fstat\$INODE64';
  return 'fstat';
}

/// Offsets of the link count, mode and owner uid in the Linux 64-bit `struct
/// stat` (see `_jitFstatFd`): a pure function of the architecture. x86_64 lays
/// them out as a little-endian u64 link count at 16, a little-endian u32 mode
/// at 24 and a little-endian u32 uid at 28; aarch64 and 64-bit RISC-V follow
/// the asm-generic layout instead (a little-endian u32 mode at 16, a
/// little-endian u32 link count at 20, a little-endian u32 uid at 24). The
/// device (u64 at 0) and inode (u64 at 8) match in both. A 32-bit ABI returns
/// null, and the caller fails closed rather than decoding a layout that
/// differs per ABI and per glibc large-file redirection. All supported hosts
/// are little-endian.
({int nlink, int mode, int uid})? jitLinuxStatOffsets({required ffi.Abi abi}) {
  switch (abi) {
    case ffi.Abi.linuxX64:
      return (nlink: 16, mode: 24, uid: 28);
    case ffi.Abi.linuxArm64:
    case ffi.Abi.linuxRiscv64:
      return (nlink: 20, mode: 16, uid: 24);
    default:
      return null;
  }
}

/// Decodes 64 bytes of Linux 64-bit `struct stat` (see [jitLinuxStatOffsets]):
/// a pure function of the bytes and the ABI, so tests pin the layout without
/// the syscall. On x86_64 the link count is 64 bits wide and only its low half
/// is kept (no host links a file more than 2^32 times); on aarch64 and 64-bit
/// RISC-V it is 32 bits wide. The identity is the device number's halves (u64
/// at 0) with the inode (u64 at 8). Null on a 32-bit ABI (see
/// [jitLinuxStatOffsets]).
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

/// The versioned 64-bit stat calls for a glibc without plain `fstat`/`lstat`
/// (see `_jitLinuxFstatFd` and `_jitLinuxStatPath`): a pure function of the
/// ABI. Plain `fstat`/`lstat` are real symbols only since glibc 2.33 (older
/// glibc inlines them), while `statx` needs 2.28 — so where both are missing
/// the callers fall back to `__fxstat64`/`__lxstat64` (GLIBC_2.2.5) with
/// glibc's `_STAT_VER`: 1 on x86_64 (`_STAT_VER_LINUX`), 0 on aarch64 and
/// 64-bit RISC-V (generic). Their buffer layout is the 64-bit `struct stat`
/// (see [jitLinuxStatOffsets]). Null on a 32-bit ABI, where `stat64` is not
/// `stat` and the caller fails closed.
({String fstat, String lstat, int ver})? jitLinuxStat64Calls({
  required ffi.Abi abi,
}) => switch (abi) {
  ffi.Abi.linuxX64 => (fstat: '__fxstat64', lstat: '__lxstat64', ver: 1),
  ffi.Abi.linuxArm64 ||
  ffi.Abi.linuxRiscv64 => (fstat: '__fxstat64', lstat: '__lxstat64', ver: 0),
  _ => null,
};

/// Decodes a 256-byte `struct statx` buffer (Linux, architecture-independent;
/// see `jitStatEntry`): a pure function of the bytes, shared by the path and
/// descriptor stats. The identity is the device major and minor (u32 at 136
/// and 140) with the inode (u64 at 32). The buffer must hold the whole struct:
/// passing the first 64 bytes reads past the end (the device sits at 136),
/// and the resulting out-of-range error must never read as a missing call.
JitStat jitDecodeStatx(List<int> bytes) {
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

/// Decodes 64 bytes of macOS 64-bit `struct stat` (see `jitStatEntry`): a pure
/// function of the bytes, shared by the path and descriptor stats. The
/// identity is the device number's halves (u64 at 0; read unsigned, compared
/// as bits) with the inode (u64 at 8).
JitStat jitDecodeMacStat(List<int> bytes) {
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

/// The read-only flags for the holder-PID lookup (see `jitLockHolderPid`):
/// O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC without O_CREAT, so a symlink or FIFO at
/// the path reports no holder instead of blocking or being followed, and no
/// spawned training subprocess inherits the lookup descriptor. Throws as
/// [jitOpenFlags] on a Linux ABI whose values are not pinned.
int jitReadFlags({required bool isMacOS, required ffi.Abi abi}) {
  final cloexec = jitCloexecFlag(isMacOS: isMacOS);
  if (isMacOS) return 0x0 | 0x100 | 0x4 | cloexec;
  return _linuxNoFollow(abi) | 0x800 | cloexec;
}

/// The atomic no-replace rename publishing the lock (see `_jitPublishOnce`):
/// a pure function of the OS and ABI. Linux renames with `renameat2` and
/// RENAME_NOREPLACE (1, the same on every ABI); macOS with `renamex_np` and
/// RENAME_EXCL (4). Both refuse with EEXIST when another publisher won, and
/// both move the temporary to the lock path atomically, so no peer ever
/// observes the published lock with a second hard link. Throws
/// [UnsupportedError] for a Linux ABI whose call is not pinned here: the
/// caller falls back to the link path rather than renaming with guessed
/// values.
({String symbol, int noReplace}) jitRenameCall({
  required bool isMacOS,
  required ffi.Abi abi,
}) {
  if (isMacOS) return (symbol: 'renamex_np', noReplace: 0x4);
  switch (abi) {
    case ffi.Abi.linuxX64:
    case ffi.Abi.linuxIA32:
    case ffi.Abi.linuxArm:
    case ffi.Abi.linuxArm64:
    case ffi.Abi.linuxRiscv32:
    case ffi.Abi.linuxRiscv64:
      // RENAME_NOREPLACE is 1 in the asm-generic and 32-bit ARM headers alike.
      return (symbol: 'renameat2', noReplace: 0x1);
    default:
      throw UnsupportedError(
        'app_jit_snapshot: no pinned no-replace rename for Linux ABI $abi, '
        'refusing to publish the training lock by rename',
      );
  }
}

/// Whether [name] fits the publish-temporary scheme for the lock file
/// [lockName] (see `_jitTempPath`): `<lock>.<pid>.<micros>.<rand>.<seq>.tmp`
/// with four nonempty decimal middle parts. Pure, so tests pin the shape a
/// publish-window sibling must have (see `_jitIsPublishWindow`): a planted
/// link with any other name never counts as a window, whatever its identity.
bool jitIsTempSibling(String name, String lockName) {
  final head = '$lockName.';
  // Slicing the middle needs the head plus `.tmp`: anything shorter cannot
  // fit the scheme, and slicing it would throw.
  if (name.length < head.length + 4) return false;
  if (!name.startsWith(head) || !name.endsWith('.tmp')) return false;
  final middle = name.substring(head.length, name.length - 4).split('.');
  return middle.length == 4 &&
      middle.every((part) => part.isNotEmpty && _jitDecimalDigits(part));
}

/// Whether [part] is all decimal digits (see [jitIsTempSibling]): a numeric
/// parse would also accept a sign, which the temporary scheme never emits.
bool _jitDecimalDigits(String part) {
  for (var i = 0; i < part.length; i++) {
    final unit = part.codeUnitAt(i);
    if (unit < 0x30 || unit > 0x39) return false;
  }
  return true;
}

/// The `l_pid` offset in `struct flock` for the holder-PID lookup (see
/// `jitLockHolderPid`): a pure function of the OS and ABI. On macOS the PID is
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

int _jitU32(List<int> bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

int _jitU16(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);
