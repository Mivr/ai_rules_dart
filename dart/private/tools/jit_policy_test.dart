// Tests for the lock policy's pure host facts (see `jit_policy.dart`): the
// pinned rename call, the temporary-sibling shape, the `struct flock`
// write-lock type and type offset, and the statx and macOS struct stat
// decoders, all from synthetic inputs, without syscalls.
import 'dart:ffi' as ffi;

import 'package:test/test.dart';

import 'jit_policy.dart';

void main() {
  test('jitRenameCall pins the no-replace rename per OS and ABI', () {
    // Linux renames with `renameat2` and RENAME_NOREPLACE (1, the same on
    // every ABI); macOS with `renamex_np` and RENAME_EXCL (4). Both refuse
    // with EEXIST when another publisher won. An ABI with no pinned call
    // throws, and the publisher falls back to the link path.
    for (final abi in [
      ffi.Abi.linuxX64,
      ffi.Abi.linuxIA32,
      ffi.Abi.linuxArm,
      ffi.Abi.linuxArm64,
      ffi.Abi.linuxRiscv32,
      ffi.Abi.linuxRiscv64,
    ]) {
      expect(jitRenameCall(isMacOS: false, abi: abi), (
        symbol: 'renameat2',
        noReplace: 1,
      ), reason: '$abi renames without replacing');
    }
    for (final abi in [ffi.Abi.macosX64, ffi.Abi.macosArm64]) {
      expect(jitRenameCall(isMacOS: true, abi: abi), (
        symbol: 'renamex_np',
        noReplace: 4,
      ), reason: '$abi renames exclusively');
    }
    expect(
      () => jitRenameCall(isMacOS: false, abi: ffi.Abi.androidArm64),
      throwsUnsupportedError,
      reason: 'unpinned ABI falls back to the link path',
    );
  });

  test('jitIsTempSibling fits only the temporary scheme', () {
    // `<lock>.<pid>.<micros>.<rand>.<seq>.tmp` with four nonempty decimal
    // middle parts; anything else is no publish window, whatever its identity.
    expect(jitIsTempSibling('lock.1234.5678.9.0.tmp', 'lock'), isTrue);
    expect(
      jitIsTempSibling('my.lock.1.22.333.4444.tmp', 'my.lock'),
      isTrue,
      reason: 'dotted lock names still match',
    );
    for (final name in [
      'lock.1234.5678.9.tmp', // Three middle parts (an older shape).
      'lock.1234.5678.9.0.1.tmp', // Five middle parts.
      'lock.1234.5678.9..tmp', // An empty part.
      'lock.1234.5678.9.x.tmp', // A nondigit part.
      'lock.+1234.5678.9.0.tmp', // A sign is no digit.
      'lock.1234.5678.9.0.tm', // A wrong extension.
      'lock.1234.5678.9.0.tmp.bak', // A longer extension.
      'other.1234.5678.9.0.tmp', // Another lock's temporary.
      'lock', // The lock itself.
      'lock.tmp', // A same-extension file.
    ]) {
      expect(jitIsTempSibling(name, 'lock'), isFalse, reason: '$name refused');
    }
  });

  test('jitDecodeStatx reads the full struct from raw bytes', () {
    // Synthetic `struct statx` bytes pin the decoder without the syscall: the
    // link count is a u32 at 16, the uid a u32 at 20, the mode a u16 at 28,
    // the inode a u64 at 32 and the device major/minor two u32 at 136/140.
    // The buffer holds the whole 256-byte struct: decoding from the first 64
    // bytes read past the end.
    final bytes = List<int>.filled(256, 0);
    bytes[16] = 2; // stx_nlink.
    bytes[20] = 0xe9; // stx_uid low byte of 1001.
    bytes[21] = 0x03;
    bytes[28] = 0xa4; // stx_mode low byte of 0100644.
    bytes[29] = 0x81; // stx_mode high byte: 0100000 is a regular file.
    bytes[32] = 0x08; // stx_ino 0x0102030405060708.
    bytes[33] = 0x07;
    bytes[34] = 0x06;
    bytes[35] = 0x05;
    bytes[36] = 0x04;
    bytes[37] = 0x03;
    bytes[38] = 0x02;
    bytes[39] = 0x01;
    bytes[136] = 8; // stx_dev_major.
    bytes[140] = 3; // stx_dev_minor.
    final stat = jitDecodeStatx(bytes);
    expect(stat.kind, 'regular file');
    expect(stat.mode, 0x81a4);
    expect(stat.uid, 1001);
    expect(stat.nlink, 2);
    expect(stat.id, (devA: 8, devB: 3, inoLo: 0x05060708, inoHi: 0x01020304));
  });

  test('jitDecodeMacStat reads the 64-bit layout from raw bytes', () {
    // Synthetic macOS `struct stat` bytes pin the decoder without the syscall:
    // the mode is a u16 at 4, the link count a u16 at 6, the uid a u32 at 16,
    // the device a u64 at 0 and the inode a u64 at 8. The device number is
    // only 4 bytes wide: the high half read at 4 overlaps the mode and link
    // count, and compares as bits.
    final bytes = List<int>.filled(64, 0);
    bytes[0] = 0x11; // st_dev low byte.
    bytes[4] = 0xa4; // st_mode low byte of 0100644.
    bytes[5] = 0x81; // st_mode high byte: 0100000 is a regular file.
    bytes[6] = 3; // st_nlink.
    bytes[8] = 0x2a; // st_ino 42.
    bytes[16] = 0xf5; // st_uid low byte of 501.
    bytes[17] = 0x01;
    final stat = jitDecodeMacStat(bytes);
    expect(stat.kind, 'regular file');
    expect(stat.mode, 0x81a4);
    expect(stat.uid, 501);
    expect(stat.nlink, 3);
    expect(stat.id, (devA: 0x11, devB: 0x381a4, inoLo: 42, inoHi: 0));
  });

  test('jitFlockLockType and jitFlockTypeOffset pin the write lock', () {
    // Darwin's `<sys/fcntl.h>` numbers F_RDLCK 1, F_UNLCK 2 and F_WRLCK 3,
    // and its `struct flock` puts `l_type` at 20, after `l_start`/`l_len`
    // (two i64 at 0/8) and `l_pid` (an i32 at 16). Linux numbers F_RDLCK 0,
    // F_WRLCK 1 and F_UNLCK 2, with `l_type` first at 0 on every ABI. Writing
    // Linux's 1 at Darwin's offset takes a shared read lock, so two
    // trainings of one key would both proceed.
    for (final abi in [ffi.Abi.macosX64, ffi.Abi.macosArm64]) {
      expect(
        jitFlockLockType(isMacOS: true, abi: abi),
        3,
        reason: '$abi asks for F_WRLCK',
      );
      expect(
        jitFlockTypeOffset(isMacOS: true, abi: abi),
        20,
        reason: '$abi writes l_type at 20',
      );
    }
    for (final abi in [
      ffi.Abi.linuxX64,
      ffi.Abi.linuxIA32,
      ffi.Abi.linuxArm,
      ffi.Abi.linuxArm64,
      ffi.Abi.linuxRiscv32,
      ffi.Abi.linuxRiscv64,
    ]) {
      expect(
        jitFlockLockType(isMacOS: false, abi: abi),
        1,
        reason: '$abi asks for F_WRLCK',
      );
      expect(
        jitFlockTypeOffset(isMacOS: false, abi: abi),
        0,
        reason: '$abi writes l_type first',
      );
    }
  });
}
