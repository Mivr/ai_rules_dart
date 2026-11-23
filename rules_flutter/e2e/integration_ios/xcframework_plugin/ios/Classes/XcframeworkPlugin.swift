import Flutter
import TinyKit
import UIKit

public class XcframeworkPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "rules_flutter/xcframework", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(XcframeworkPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    // Called through the C declaration in the imported TinyKit framework,
    // so the simulator only sees 42 when its static library linked.
    case "tinykitAnswer":
      result(Int(tinykit_answer()))
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
