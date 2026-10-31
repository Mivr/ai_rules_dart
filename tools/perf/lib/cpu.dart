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

/// Linux `struct rusage` (160 bytes on x86_64 / arm64).
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

/// Real Linux child CPU clock using `getrusage(RUSAGE_CHILDREN)`.
final class LinuxChildCpuClock implements ChildCpuClock {
  /// Initializes the FFI bindings.
  LinuxChildCpuClock() {
    if (Platform.isLinux) {
      final lib = DynamicLibrary.process();
      _getrusage = lib.lookupFunction<_GetrusageC, _GetrusageDart>('getrusage');
      _ptr = _allocator<_Rusage>();
    }
  }

  static const int _rusageChildren = -1;
  _GetrusageDart? _getrusage;
  Pointer<_Rusage>? _ptr;

  static Pointer<T> _allocator<T extends Struct>() {
    return Pointer<T>.fromAddress(
      // Allocate 256 bytes for rusage struct
      DynamicLibrary.process()
          .lookupFunction<
            Pointer<Void> Function(IntPtr),
            Pointer<Void> Function(int)
          >('malloc')(256)
          .address,
    );
  }

  @override
  double getChildCpuSeconds() {
    final fn = _getrusage;
    final ptr = _ptr;
    if (fn == null || ptr == null) return 0.0;

    final ret = fn(_rusageChildren, ptr);
    if (ret != 0) return 0.0;

    final uSec = ptr.ref.ruUtime.tvSec;
    final uUsec = ptr.ref.ruUtime.tvUsec;
    final sSec = ptr.ref.ruStime.tvSec;
    final sUsec = ptr.ref.ruStime.tvUsec;

    return (uSec + uUsec / 1e6) + (sSec + sUsec / 1e6);
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
