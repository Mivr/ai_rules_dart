/// Which of Flutter's three build modes a run's app was built in.
///
/// The names are upstream's, and so is the line between them: debug is a JIT
/// app, profile and release are AOT. A device needs to know which, not only
/// "AOT or not": an iOS device attaches a debugger to a debug app and to
/// nothing else, and a profile app may serve a VM service where a release app
/// never does.
library;

enum BuildMode {
  /// A `-c dbg` build: a JIT kernel on the debug engine.
  debug,

  /// A `--profile` run: AOT on the profile engine, built `-c opt` with
  /// `--@rules_flutter//flutter:profile`.
  profile,

  /// Any other build: AOT, on the release engine.
  release;

  /// Whether the app serves a Dart VM service, so a launch waits for one.
  /// Release is the only mode that never does.
  bool get servesVmService => this != release;
}
