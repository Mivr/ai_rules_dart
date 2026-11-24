import UIKit

/// The share sheet's view controller. It records that something was shared in
/// the App Group, where the app can pick it up, and closes.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UserDefaults(suiteName: "group.com.rulesflutter.ios.example")?
            .set("shared", forKey: "note")
        extensionContext?.completeRequest(returningItems: nil)
    }
}
