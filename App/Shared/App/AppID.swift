import Foundation

/// The TV app's bundle id, read from Info.plist (`HarborBaseID`, set by project.yml). Both apps use it
/// as the keychain service and the log subsystem, so stored sign-ins survive reinstalls.
enum AppID {
    static let base: String = Bundle.main.object(forInfoDictionaryKey: "HarborBaseID") as? String
        ?? Bundle.main.bundleIdentifier ?? "harbor"
}
