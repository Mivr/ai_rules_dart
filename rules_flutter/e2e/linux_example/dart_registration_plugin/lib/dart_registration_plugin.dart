/// A pure-Dart plugin registered by the generated Dart plugin registrant.
///
/// The registrant calls [DartRegistrationPlugin.registerWith] before the
/// application's `main()`; the kernel-consistency test only needs the
/// registrant to exist and be linked into the modular debug kernel.
library;

/// Pure-Dart plugin whose registration records that it ran.
class DartRegistrationPlugin {
  static bool _registered = false;

  /// Whether the generated registrant has run.
  static bool get isRegistered => _registered;

  /// Called by the generated Dart plugin registrant before `main()`.
  static void registerWith() {
    _registered = true;
  }
}
