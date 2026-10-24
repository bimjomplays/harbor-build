import UIKit

/// The phone stays portrait; the player turns it landscape while it is up.
/// Info.plist lists all three orientations so the player may use them; the app delegate answers
/// with `mask`, and `lock` asks the scene to rotate to it.
@MainActor
enum PhoneOrientation {
    /// What the app allows now: portrait, or landscape while the player is up.
    private(set) static var mask: UIInterfaceOrientationMask = .portrait

    static func lock(_ new: UIInterfaceOrientationMask) {
        mask = new
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            // Every presented controller re-reads the allowed orientations, the player's cover first.
            for window in scene.windows {
                var vc: UIViewController? = window.rootViewController
                while let c = vc {
                    c.setNeedsUpdateOfSupportedInterfaceOrientations()
                    vc = c.presentedViewController
                }
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: new)) { _ in }
        }
    }
}

/// HarborPhone's app delegate: only the orientation rule (PhoneOrientation).
@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        PhoneOrientation.mask
    }
}
