import Algorithms
import Flutter
import RealModule
import UIKit

public class SpmGraphPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "rules_flutter/spm_graph", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(SpmGraphPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    // Computed with the linked graph at run time, so the test proves the
    // transitive products made it into this library's link: 2-combinations
    // of four items via swift-algorithms, then e via swift-numerics.
    case "computeGraph":
      result("\(Array([1, 2, 3, 4].combinations(ofCount: 2)).count) \(Double.exp(1))")
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
