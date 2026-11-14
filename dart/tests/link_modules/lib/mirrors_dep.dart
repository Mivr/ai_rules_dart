// A dependency package that picks a library by a conditional import on
// `dart.library.mirrors`: a linked module would take the JIT answer.
export 'stub.dart' if (dart.library.mirrors) 'reflective.dart';
