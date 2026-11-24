import 'package:flutter/services.dart';

/// App-facing client for the federated greeting plugin.
class FederatedGreeting {
  /// Creates a [FederatedGreeting] instance.
  const FederatedGreeting();

  static const MethodChannel _channel = MethodChannel(
    'rules_flutter/federated_greeting',
  );

  /// Requests the greeting string from the active platform plugin.
  Future<String?> getGreeting() {
    return _channel.invokeMethod<String>('getGreeting');
  }
}
