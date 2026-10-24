import Foundation

/// What the shared models need from the screen they run on. The TV
/// answers from its overlay windows, screensaver and PiP browse layer (Shell/TVPlatform.swift);
/// the phone has none of those, so the defaults below say "nothing is up, nothing covers the shell".
@MainActor
protocol PlatformHooks {
    /// The screensaver is showing (the TV's idle saver; never on the phone).
    var screensaverActive: Bool { get }
    /// Any activity wakes the saver; a deep link arriving under it must not sit unseen.
    func wakeScreensaver()
    /// Nothing is presented over the main window's root (no cover or sheet is up).
    var mainWindowUncovered: Bool { get }
    /// The PiP browse layer is up (its own Home runs above the player's cover).
    var pipBrowseUp: Bool { get }
    /// Nothing is presented over the PiP browse layer's shell, and `app` is that layer's model.
    func pipLayerUncovered(for app: AppModel) -> Bool
    /// Starts the remote/touch activity tracking the idle timers read.
    func installActivityMonitor()
    /// A player is opening (`id` is its Now Playing claim; nil for Multiview): the film in Picture in
    /// Picture that the PiP browse layer was browsing over stops and saves first.
    func pipBrowsePlaybackOpening(_ id: UUID?)
    /// The player `id` is closing: the layer goes down with it, or stays up for browsing (`keepBrowsing`).
    func pipBrowseRelease(_ id: UUID, keepBrowsing: Bool)
    /// The PiP window's restore button: the player `id` comes back in front of the layer.
    func pipBrowseRestore(_ id: UUID)
    /// The browse layer is open to player `id` (it stepped aside for it).
    func pipBrowseOwns(_ id: UUID) -> Bool
    /// Player `id` steps aside for the browse layer: `toggle` is the remote's Play/Pause meanwhile,
    /// `end` stops and saves for good, `returned` runs once the layer went down on Back.
    func pipBrowseStepAside(id: UUID, toggle: @escaping () -> Void, end: @escaping () -> Void, returned: @escaping () -> Void)
}

/// UI sounds (the TV's BPSound). The phone plays none yet; haptics hang here later.
@MainActor
protocol Feedback: AnyObject {
    /// bp-settings-commit.ts auditionSound: the sound theme being tried, not yet committed.
    var audition: String? { get set }
}

/// Defaults for a platform with no saver, no PiP browse layer and no overlay windows.
@MainActor
struct DefaultPlatformHooks: PlatformHooks {
    var screensaverActive: Bool { false }
    func wakeScreensaver() {}
    var mainWindowUncovered: Bool { true }
    var pipBrowseUp: Bool { false }
    func pipLayerUncovered(for app: AppModel) -> Bool { false }
    func installActivityMonitor() {}
}

/// The PiP browse layer is TV-only: a platform without one (the phone) inherits these, so a new
/// requirement here never breaks its conformer.
extension PlatformHooks {
    func pipBrowsePlaybackOpening(_ id: UUID?) {}
    func pipBrowseRelease(_ id: UUID, keepBrowsing: Bool) {}
    func pipBrowseRestore(_ id: UUID) {}
    func pipBrowseOwns(_ id: UUID) -> Bool { false }
    func pipBrowseStepAside(id: UUID, toggle: @escaping () -> Void, end: @escaping () -> Void, returned: @escaping () -> Void) {}
}

@MainActor
final class SilentFeedback: Feedback {
    var audition: String?
}

@MainActor
enum Platform {
    #if os(tvOS)
    static var hooks: PlatformHooks = TVPlatformHooks()
    static var feedback: Feedback = BPSound.shared
    #else
    static var hooks: PlatformHooks = DefaultPlatformHooks()
    static var feedback: Feedback = SilentFeedback()
    #endif
}
