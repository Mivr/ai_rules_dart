import 'package:flutter/services.dart';

/// Method-channel client for the plugin that links the TinyKit framework.
class XcframeworkPlugin {
  /// Creates an [XcframeworkPlugin] instance.
  const XcframeworkPlugin();

  static const MethodChannel _channel = MethodChannel(
    'rules_flutter/xcframework',
  );

  /// Returns the value `tinykit_answer()` computes in the imported framework.
  Future<int?> tinykitAnswer() {
    return _channel.invokeMethod<int>('tinykitAnswer');
  }
}
