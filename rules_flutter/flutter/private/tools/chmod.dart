/// Sets POSIX permission bits through libc's `chmod(2)`, with no package
/// dependencies.
///
/// Both the app bundler and the native-library stripper normalize mode bits
/// the host's umask would otherwise leak into their outputs; the helper lives
/// here so the two tools share one copy.
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

typedef _MallocNative = ffi.Pointer<ffi.Uint8> Function(ffi.Size);
typedef _MallocDart = ffi.Pointer<ffi.Uint8> Function(int);
typedef _FreeNative = ffi.Void Function(ffi.Pointer<ffi.Uint8>);
typedef _FreeDart = void Function(ffi.Pointer<ffi.Uint8>);
typedef _ChmodNative = ffi.Int Function(ffi.Pointer<ffi.Uint8>, ffi.Uint32);
typedef _ChmodDart = int Function(ffi.Pointer<ffi.Uint8>, int);

/// Sets POSIX permission bits [mode] on [path] via libc's `chmod(2)`.
void chmodFile(String path, int mode) {
  if (Platform.isWindows) return;
  final lib = ffi.DynamicLibrary.process();
  final _MallocDart malloc = lib.lookupFunction<_MallocNative, _MallocDart>(
    'malloc',
  );
  final _FreeDart free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
  final _ChmodDart chmod = lib.lookupFunction<_ChmodNative, _ChmodDart>(
    'chmod',
  );
  final Uint8List bytes = utf8.encode(path);
  final ffi.Pointer<ffi.Uint8> ptr = malloc(bytes.length + 1);
  if (ptr == ffi.nullptr) {
    throw FileSystemException('malloc failed for chmod', path);
  }
  try {
    ptr.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    final int rc = chmod(ptr, mode);
    if (rc != 0) {
      throw FileSystemException('chmod failed (rc=$rc)', path);
    }
  } finally {
    free(ptr);
  }
}
