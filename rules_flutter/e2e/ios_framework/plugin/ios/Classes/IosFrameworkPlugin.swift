import Flutter

/// First-party iOS plugin used by the add-to-app xcframework example.
public class IosFrameworkPlugin: NSObject, FlutterPlugin {
  /// The marker the e2e test looks for in the plugin and registrant binaries.
  public static let marker = "rules_flutter_ios_framework_plugin_marker"

  /// Registers the plugin's method channel with the Flutter engine.
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "rules_flutter/ios_framework_plugin",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(IosFrameworkPlugin(), channel: channel)
  }

  /// Answers the example's single method with the plugin marker.
  public func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    result(IosFrameworkPlugin.marker)
  }
}
