import BigInt
import Flutter
import UIKit

public class PodBigintPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "rules_flutter/pod_bigint", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(PodBigintPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "computeBig":
      result(
        "\(BigUInt(2).power(100)) \(BigInt("-0", radix: 10)!)"
      )
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
