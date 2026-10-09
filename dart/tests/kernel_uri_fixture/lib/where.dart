/// The first frame of the caller's stack trace, which names the caller's
/// library by the URI the compiler gave it.
String callerFrame() => StackTrace.current.toString().split('\n')[1];
