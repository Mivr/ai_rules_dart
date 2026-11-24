/// Adds two integers in C.
@DefaultAsset('package:native_add/native_add.dart')
library;

import 'dart:ffi';

/// `a + b`, computed by the package's native library.
@Native<Int32 Function(Int32, Int32)>()
external int add(int a, int b);
