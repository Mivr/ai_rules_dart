// Turns a compiled library into its outline, on `package:kernel`'s own AST.
//
// An outline is what a dependant module compiles against: every declaration
// with its (inferred) types, annotations, default values and constants, and
// no executable code. What stays is what the front end reads from a
// dependency:
//
//  * a `const` field keeps its initializer (by now an evaluated constant);
//  * a class with a `const` constructor keeps the initializers of its final
//    instance fields and its `const` constructors' initializer lists, which
//    the dependant's constant evaluator runs;
//  * a `const` (redirecting) factory keeps its body;
//  * a class that can be mixed in stays whole. The VM target copies a mixin's
//    members into each application class when it compiles the application, so
//    a dependant needs the bodies. Such a class is a `mixin`, a `mixin class`,
//    and any class of a library below language version 3.0.
//
// Everything else loses its body or initializer. Nothing here knows the kernel
// binary format.

import 'package:kernel/ast.dart';

/// Whether [cls] can be mixed in by another library.
bool canBeMixedIn(Class cls) =>
    cls.isMixinDeclaration ||
    cls.isMixinClass ||
    cls.enclosingLibrary.languageVersion.major < 3;

/// Strips [library] in place.
void stripToOutline(Library library) {
  library.problemsAsJson = null;
  for (final Field field in library.fields) {
    if (!field.isConst) field.initializer = null;
  }
  library.procedures.forEach(_stripProcedure);
  for (final Class cls in library.classes) {
    if (canBeMixedIn(cls)) continue;
    final bool hasConstConstructor = cls.constructors.any((c) => c.isConst);
    for (final Field field in cls.fields) {
      final bool keep =
          field.isConst ||
          (hasConstConstructor && field.isFinal && !field.isStatic);
      if (!keep) field.initializer = null;
    }
    for (final Constructor constructor in cls.constructors) {
      constructor.function.body = null;
      if (!constructor.isConst) constructor.initializers.clear();
    }
    cls.procedures.forEach(_stripProcedure);
  }
  for (final ExtensionTypeDeclaration declaration
      in library.extensionTypeDeclarations) {
    declaration.procedures.forEach(_stripProcedure);
  }
}

void _stripProcedure(Procedure procedure) {
  if (!procedure.isConst) procedure.function.body = null;
}
