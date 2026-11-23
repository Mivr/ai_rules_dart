import FlutterMacOS

// The headers-only module the plugin's ObjC half publishes.
import mixed_plugin_objc

@objc public class MixedPlugin: NSObject {
  @objc public func greeting() -> String {
    return "mixed ObjC + Swift"
  }
}
