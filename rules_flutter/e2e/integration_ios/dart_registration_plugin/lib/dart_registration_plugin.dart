/// A pure-Dart plugin registered by the generated Dart plugin registrant.
///
/// The registrant calls [DartRegistrationPlugin.registerWith] before the
/// application's `main()`, which installs the [RegisteredGreeter]
/// implementation below. The integration test reads
/// [DartRegistrationPlugin.startupEvents] to prove the registration ran
/// first.
library;

/// The event [DartRegistrationPlugin.registerWith] records.
const String registerEvent = 'registerWith';

/// The event the integration test records when its own `main()` starts.
const String testMainEvent = 'testMain';

/// The Dart-side implementation plugin registration installs.
class RegisteredGreeter {
  /// Creates the greeter registration installs.
  const RegisteredGreeter();

  /// The message the application can use once registration has run.
  String greet() => 'registered by the generated Dart registrant';
}

/// Pure-Dart plugin whose registration installs [RegisteredGreeter].
class DartRegistrationPlugin {
  /// The startup events observed so far, in order.
  static final List<String> startupEvents = <String>[];

  static RegisteredGreeter? _greeter;

  /// Whether the generated registrant installed the implementation.
  static bool get isRegistered => _greeter != null;

  /// Called by the generated Dart plugin registrant before `main()`.
  static void registerWith() {
    startupEvents.add(registerEvent);
    _greeter = const RegisteredGreeter();
  }

  /// The message of the installed implementation.
  ///
  /// Throws when the generated registrant did not run.
  static String greet() {
    final greeter = _greeter;
    if (greeter == null) {
      throw StateError('DartRegistrationPlugin.registerWith() has not run');
    }
    return greeter.greet();
  }
}
