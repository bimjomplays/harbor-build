import SwiftUI

/// A Stremio sign-in made before any profile exists; attached to the first profile that gets created.
/// Kept in the Keychain, not in memory: setup now resumes after a relaunch
/// (upstream's useAuth session is in storage from the moment of sign-in), and a sign-in made before
/// the app was killed was otherwise gone while the recap carried on without it.
enum PendingStremio {
    /// Not an engine key (no `harbor.` prefix): the bundle never sees it before a profile owns it.
    private static let key = "tv.onboarding.pending-stremio"

    static var session: ProfilesStore.StremioSession? {
        get {
            guard let raw = SecretStore.get(key), let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ProfilesStore.StremioSession.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue), let raw = String(data: data, encoding: .utf8) {
                try? SecretStore.set(raw, for: key)
            } else {
                SecretStore.remove(key)
            }
        }
    }
}

/// The onboarding step to resume at after a relaunch (OnboardingView writes it, AppModel clears it).
enum OnboardingResume {
    /// bp-onboarding.tsx RESUME_KEY: its own key, apart from the finished flag (`harbor.onboarding.bp`
    /// here is AppModel's). Written on every move: a power cut mid-setup is the common case on a TV.
    static let key = "tv.onboarding.step"

    /// bp-onboarding.tsx clearResume, with the finished flag (AppModel.finishOnboarding).
    static func clear() { Prefs.remove(key) }
}
