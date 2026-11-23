import Flutter
import UIKit
import spm_objc_plugin_objc

public class SpmObjcPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "rules_flutter/spm_objc", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(SpmObjcPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    // Computed by the separate ObjC target, so the test proves that target
    // was compiled and linked even though only the Swift target's directory
    // was globbed by the spoke.
    case "computedValue":
      result("\(SpmObjcPluginValue.answer())")
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
