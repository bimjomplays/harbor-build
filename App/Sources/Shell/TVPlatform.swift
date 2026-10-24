import Foundation

/// The TV's answers for `Platform.hooks` (App/Shared/App/Platform.swift): the screensaver, the
/// overlay windows and the PiP browse layer all live in the tvOS target only.
@MainActor
struct TVPlatformHooks: PlatformHooks {
    var screensaverActive: Bool { ScreensaverModel.shared.active }
    func wakeScreensaver() { ScreensaverModel.shared.wake() }
    var mainWindowUncovered: Bool { HarborOverlayWindow.noCoverPresented }
    var pipBrowseUp: Bool { PiPBrowse.shared.isUp }
    func pipLayerUncovered(for app: AppModel) -> Bool {
        PiPBrowse.shared.layerApp === app && PiPBrowse.shared.noCoverPresented
    }
    func installActivityMonitor() { ActivityMonitor.install() }
    func pipBrowsePlaybackOpening(_ id: UUID?) { PiPBrowse.shared.playbackOpening(id) }
    func pipBrowseRelease(_ id: UUID, keepBrowsing: Bool) { PiPBrowse.shared.release(id, keepBrowsing: keepBrowsing) }
    func pipBrowseRestore(_ id: UUID) { PiPBrowse.shared.restore(id) }
    func pipBrowseOwns(_ id: UUID) -> Bool { PiPBrowse.shared.owns(id) }
    func pipBrowseStepAside(id: UUID, toggle: @escaping () -> Void, end: @escaping () -> Void, returned: @escaping () -> Void) {
        PiPBrowse.shared.stepAside(PiPBrowse.Owner(id: id, toggle: toggle, end: end, returned: returned))
    }
}

extension BPSound: Feedback {}
