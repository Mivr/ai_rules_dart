/// A first-party FFI plugin: its iOS metadata declares `ffiPlugin` and its
/// `native_deps` carry a C library the iOS runner links into the app binary.
library;

import 'dart:ffi';
import 'dart:io';

/// The C symbol [FfiPlugin.answer] calls.
const String answerSymbol = 'rules_flutter_ffi_answer';

/// FFI access to the plugin's first-party C library.
class FfiPlugin {
  static final int Function() _answer = DynamicLibrary.process()
      .lookupFunction<Int32 Function(), int Function()>(answerSymbol);

  /// Returns the number the linked C function answers.
  static int answer() {
    if (!Platform.isIOS) {
      throw UnsupportedError('FfiPlugin.answer() is only wired for iOS');
    }
    return _answer();
  }
}
