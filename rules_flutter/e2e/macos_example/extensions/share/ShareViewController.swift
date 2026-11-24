import AppKit
import Security

/// The share sheet's view controller. It records that something was shared in
/// the App Group, where the app can pick it up, and closes.
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        UserDefaults(suiteName: appGroup)?.set("shared", forKey: "note")
        extensionContext?.completeRequest(returningItems: nil)
    }
}

/// The App Group, read from this bundle's signed entitlements: the ad hoc and
/// team-signed builds use different ids.
private let appGroup: String = {
    let task = SecTaskCreateFromSelf(nil)
    let key = "com.apple.security.application-groups" as CFString
    let groups = task.flatMap { SecTaskCopyValueForEntitlement($0, key, nil) }
    return (groups as? [String])?.first ?? ""
}()
