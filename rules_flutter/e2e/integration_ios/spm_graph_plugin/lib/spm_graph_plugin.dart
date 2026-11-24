import 'package:flutter/services.dart';

/// Method-channel client for the native graph plugin.
class SpmGraphPlugin {
  /// Creates a [SpmGraphPlugin] instance.
  const SpmGraphPlugin();

  static const MethodChannel _channel = MethodChannel(
    'rules_flutter/spm_graph',
  );

  /// Asks the native side to count 2-combinations of four items with
  /// swift-algorithms and to evaluate `e` with swift-numerics at run
  /// time, proving the transitive SwiftPM graph linked into its Apple
  /// library.
  Future<String?> computeGraph() {
    return _channel.invokeMethod<String>('computeGraph');
  }
}
