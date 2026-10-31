/// Whole-tree child CPU measurement interface and Linux FFI implementation.
library;

import 'dart:ffi';
import 'dart:io';

/// Interface for measuring child CPU seconds.
abstract interface class ChildCpuClock {
  /// Returns accumulated child (reaped descendants) user + sys CPU seconds.
  double getChildCpuSeconds();
}

/// Linux `struct timeval`.
final class _Timeval extends Struct {
  @Int64()
  external int tvSec;

  @Int64()
  external int tvUsec;
}

/// Linux `struct rusage` (144 bytes on 64-bit Linux, padded for safety).
final class _Rusage extends Struct {
  external _Timeval ruUtime;
  external _Timeval ruStime;

  @Int64()
  external int r0;
  @Int64()
  external int r1;
  @Int64()
  external int r2;
  @Int64()
  external int r3;
  @Int64()
  external int r4;
  @Int64()
  external int r5;
  @Int64()
  external int r6;
  @Int64()
  external int r7;
  @Int64()
  external int r8;
  @Int64()
  external int r9;
  @Int64()
  external int r10;
  @Int64()
  external int r11;
  @Int64()
  external int r12;
  @Int64()
  external int r13;
  @Int64()
  external int r14;
  @Int64()
  external int r15;
}

typedef _GetrusageC = Int32 Function(Int32 who, Pointer<_Rusage> usage);
typedef _GetrusageDart = int Function(int who, Pointer<_Rusage> usage);
typedef _CallocC = Pointer<Void> Function(IntPtr count, IntPtr size);
typedef _CallocDart = Pointer<Void> Function(int count, int size);

/// Real Linux child CPU clock using `getrusage(RUSAGE_CHILDREN)`.
final class LinuxChildCpuClock implements ChildCpuClock {
  /// Creates a Linux child CPU clock.
  const LinuxChildCpuClock();

  static const int _rusageChildren = -1;

  static final (_GetrusageDart, Pointer<_Rusage>)? _ffiState = _initLinuxFfi();

  static (_GetrusageDart, Pointer<_Rusage>)? _initLinuxFfi() {
    if (!Platform.isLinux) return null;
    try {
      final lib = DynamicLibrary.process();
      final fn = lib.lookupFunction<_GetrusageC, _GetrusageDart>('getrusage');
      final calloc = lib.lookupFunction<_CallocC, _CallocDart>('calloc');
      final raw = calloc(1, 256);
      if (raw.address == 0) return null;
      return (fn, Pointer<_Rusage>.fromAddress(raw.address));
    } on ArgumentError catch (e) {
      stderr.writeln('getrusage FFI lookup failed: $e');
      return null;
    }
  }

  @override
  double getChildCpuSeconds() {
    final state = _ffiState;
    if (state == null) return 0.0;
    final (fn, ptr) = state;
    final ret = fn(_rusageChildren, ptr);
    if (ret != 0) {
      throw StateError('getrusage(RUSAGE_CHILDREN) failed with code $ret');
    }

    final uSec = ptr.ref.ruUtime.tvSec;
    final uUsec = ptr.ref.ruUtime.tvUsec;
    final sSec = ptr.ref.ruStime.tvSec;
    final sUsec = ptr.ref.ruStime.tvUsec;
    return (uSec + sSec) + (uUsec + sUsec) / 1e6;
  }
}

/// Fake child CPU clock for unit tests and fallback.
final class FakeChildCpuClock implements ChildCpuClock {
  /// Creates a fake clock with optional sequential values.
  FakeChildCpuClock([List<double>? values])
    : _values = values != null ? List.of(values) : <double>[];

  final List<double> _values;
  double _current = 0.0;

  /// Sets the next CPU value to return.
  void setNext(double value) => _current = value;

  @override
  double getChildCpuSeconds() {
    if (_values.isNotEmpty) {
      return _values.removeAt(0);
    }
    return _current;
  }
}
