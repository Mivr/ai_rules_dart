import 'package:flutter/services.dart';

/// Method-channel client for the plugin-local ObjC target fixture.
class SpmObjcPlugin {
  /// Creates an [SpmObjcPlugin] instance.
  const SpmObjcPlugin();

  static const MethodChannel _channel = MethodChannel('rules_flutter/spm_objc');

  /// Asks the Swift target for a value computed by the separate ObjC
  /// target, proving both targets of the plugin's manifest were built.
  Future<String?> computedValue() {
    return _channel.invokeMethod<String>('computedValue');
  }
}
