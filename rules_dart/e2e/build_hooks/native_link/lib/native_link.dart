/// Multiplies in C; a package with a build hook and a link hook.
@DefaultAsset('package:native_link/native_link.dart')
library;

import 'dart:ffi';

import 'package:meta/meta.dart' show RecordUse;

/// `a * b`, computed by the package's native library.
@Native<Int32 Function(Int32, Int32)>()
external int multiply(int a, int b);

/// A factor the link hook records when the program constructs it as a
/// constant.
@RecordUse()
final class Factor {
  /// The value.
  final int value;

  /// A constant factor.
  const Factor(this.value);

  /// This factor times [other], in C.
  int times(int other) => multiply(value, other);
}
