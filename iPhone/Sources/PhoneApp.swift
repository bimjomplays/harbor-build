import SwiftUI

@main
struct PhoneApp: App {
    /// Portrait everywhere, landscape while the player is up (PhoneOrientation).
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            // The root sets the colour scheme from the active theme.
            PhoneRootView()
        }
    }
}
