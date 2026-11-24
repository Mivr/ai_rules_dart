/// Copies one file byte for byte and sets its POSIX mode, with no host tools.
///
/// Run by the local-SDK repository rules on the SDK's own bundled Dart VM, as
/// `dart copy_local_file.dart <src> <dst> <executable: true|false>`, so a
/// fetch needs neither `cp` nor `cmd /c copy`. The file imports only the
/// standard library: a repository rule stages exactly this one file by label.
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

/// The mode of an executable copy (`0755`).
const int executableMode = 0x1ed;

/// The mode of a plain, owner-writable copy (`0644`).
const int plainMode = 0x1a4;

typedef _LibcChmod = int Function(ffi.Pointer<ffi.Uint8>, int);
typedef _LibcMalloc = ffi.Pointer<ffi.Uint8> Function(int);

/// Sets the POSIX permission bits [mode] on [path] through libc `chmod(2)`.
void _setMode(String path, int mode) {
  final lib = ffi.DynamicLibrary.process();
  final _LibcMalloc alloc = lib
      .lookupFunction<ffi.Pointer<ffi.Uint8> Function(ffi.Size), _LibcMalloc>(
        'malloc',
      );
  final _LibcChmod chmod = lib
      .lookupFunction<
        ffi.Int Function(ffi.Pointer<ffi.Uint8>, ffi.Uint32),
        _LibcChmod
      >('chmod');
  final List<int> raw = utf8.encode(path);
  final ffi.Pointer<ffi.Uint8> buffer = alloc(raw.length + 1);
  buffer.asTypedList(raw.length + 1)
    ..setAll(0, raw)
    ..[raw.length] = 0;
  final int status = chmod(buffer, mode);
  if (status != 0) {
    throw FileSystemException('chmod failed (status $status)', path);
  }
}

/// Copies [src] to [dst], creating parent directories as needed.
///
/// On non-Windows hosts the copy ends with mode `0755` when [executable] is
/// true and `0644` otherwise, whatever the source's mode was.
void copyLocalFile(String src, String dst, {required bool executable}) {
  final List<int> bytes = File(src).readAsBytesSync();
  final out = File(dst);
  out.parent.createSync(recursive: true);
  if (out.existsSync()) out.deleteSync();
  out.writeAsBytesSync(bytes);
  if (!Platform.isWindows) {
    _setMode(dst, executable ? executableMode : plainMode);
  }
}

/// Runs the tool for [args] (`<src> <dst> <true|false>`); returns the exit code.
int runCopyLocalFile(List<String> args) {
  if (args.length != 3 || (args[2] != 'true' && args[2] != 'false')) {
    stderr.writeln('usage: copy_local_file <src> <dst> <true|false>');
    return 2;
  }
  try {
    copyLocalFile(args[0], args[1], executable: args[2] == 'true');
  } on FileSystemException catch (e) {
    stderr.writeln('copy_local_file: ${e.message}: ${e.path ?? args[0]}');
    return 1;
  }
  return 0;
}

/// Entry point; see the library comment.
void main(List<String> args) {
  exitCode = runCopyLocalFile(args);
}
