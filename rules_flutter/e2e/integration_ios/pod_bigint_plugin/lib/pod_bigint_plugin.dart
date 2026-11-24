import 'package:flutter/services.dart';

/// Method-channel client for the native CocoaPods BigInt plugin.
class PodBigintPlugin {
  /// Creates a [PodBigintPlugin] instance.
  const PodBigintPlugin();

  static const MethodChannel _channel = MethodChannel(
    'rules_flutter/pod_bigint',
  );

  /// Asks the native side to compute `2^100` and `-0` with BigInt at run
  /// time, proving the plugin's CocoaPods pod linked into its Apple
  /// library.
  Future<String?> computeBig() {
    return _channel.invokeMethod<String>('computeBig');
  }
}
