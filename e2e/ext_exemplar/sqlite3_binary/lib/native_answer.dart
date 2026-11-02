@DefaultAsset('package:native_answer/native_answer.dart')
library;

import 'dart:ffi';

/// Returns the number the Bazel-built `native_answer` library answers with.
@Native<Int32 Function()>(symbol: 'native_answer')
external int nativeAnswer();
