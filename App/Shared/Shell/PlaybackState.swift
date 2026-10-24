import SwiftUI
import Combine
import UIKit
import ObjectiveC

/// Playback and pickers suppress the saver (use-bp-screensaver `suppressed`).
@MainActor
final class PlaybackState: ObservableObject {
    static let shared = PlaybackState()
    @Published private(set) var active = false
    /// The players (and Multiview) that hold playback. Two can overlap for a moment: a video
    /// started from the PiP browse layer opens while the one in Picture in Picture is still
    /// closing, and the late close must not clear the new one's claim (PiPBrowse).
    private var claims: Set<UUID> = []

    /// PlayerScreen's forced close, registered like `ShellFocus.shared.request`: an
    /// addon install link must close it first, as upstream's emitDeepLinkInstall → setView("addons")
    /// resets the whole nav stack (App.tsx), the player's frame included. Keyed so a second player
    /// opening while the first still tears down (the PiP hand-off) never clears the newer one's slot.
    private var closeHandler: (id: UUID, run: () -> Void)?

    func setCloseHandler(_ id: UUID, _ run: (() -> Void)?) {
        if let run { closeHandler = (id, run) }
        else if closeHandler?.id == id { closeHandler = nil }
    }

    /// Ask whatever player is on screen to close now, with no "Keep watching?" dialog (PlayerScreen's
    /// own `requestClose()` asks first; this calls `finish(natural: false)` straight away, like the
    /// curfew lock's forced close already does).
    func forceCloseIfPlaying() { closeHandler?.run() }

    func claim(_ id: UUID) {
        claims.insert(id)
        if !active { active = true }
    }

    func release(_ id: UUID) {
        guard claims.remove(id) != nil else { return }
        if claims.isEmpty, active { active = false }
    }
}
