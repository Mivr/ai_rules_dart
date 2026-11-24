/// The plugin's Dart API.
String hello(String name) => 'hello, $name';

/// The Linux implementation, registered by the generated registrant.
class HelloPluginLinux {
  /// Registers the implementation.
  static void registerWith() {}
}
