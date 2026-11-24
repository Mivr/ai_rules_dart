/// Base configuration interface for testing override parity.
abstract class BaseConfig {
  /// Configures options with two boolean flags.
  // Ignored to define multi-bool method on base class.
  // ignore: avoid_positional_boolean_parameters
  void configure(bool a, bool b);
}

/// Helper function with a single positional boolean parameter.
void helper(bool flag) {
  if (flag) {}
}
