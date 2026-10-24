import SwiftUI

/// PlayerSession: picture in Picture (use-pip-mode.ts).
extension PlayerSession {
    /// pip://entered / pip://exited: the chrome stands aside while the picture is in the PiP window,
    /// and comes back with it.
    func pipChanged(_ on: Bool) {
        // A start that failed or timed out reports "off" without ever being on: focus stays put.
        guard on != pipActive else { return }
        pipActive = on
        if on {
            hideTask?.cancel()
            chrome = false
            if panel != nil { panel = nil }
            leaveConfirm = false
            focusLater(.chip("pip-exit"))
            // The player screen steps aside: the viewer browses Harbor while the picture floats.
            if canBrowseDuringPiP { browseHarbor() }
        } else {
            // A closing player needs no ring; Still watching (a natural end in PiP) shows only now.
            guard !finishing else { return }
            if stillPrompt { focusLater(.chip("still-continue")); return }
            focus = .surface
            wake()
        }
    }

    /// A new engine took over from one that was in Picture in Picture (a live
    /// channel that ran out and reloads, the native engine's failure handing the stream to mpv).
    /// The old controller's teardown stops its PiP with its delegate already gone, so no "exited"
    /// ever came: the browse layer stayed up over a player whose sound went on unseen, and the
    /// placard's Exit did nothing on mpv. The player screen comes back to the front instead.
    func engineReplaced() {
        if Platform.hooks.pipBrowseOwns(nowPlayingId) { Platform.hooks.pipBrowseRelease(nowPlayingId, keepBrowsing: false) }
        if pipActive { pipChanged(false) }
    }

    /// PiPBrowse is open to this player: an adult's AVPlayer in the app's own window.
    var canBrowseDuringPiP: Bool {
        engine == .native && browseDuringPiP && !inBrowseLayer && !isKid
    }

    /// The browse layer goes up over this screen, which keeps playing (and saving, scrobbling,
    /// holding Now Playing and its torrent) under it.
    func browseHarbor() {
        // The layer's owner record is a singleton's: it holds the session weakly, and the layer drops it
        // when the player releases it.
        Platform.hooks.pipBrowseStepAside(
            id: nowPlayingId,
            // media-session.ts mediaKeyGate: a press that also arrives as a remote command toggles once.
            toggle: { [weak self] in if VideoNowPlaying.shared.mediaKeyGate() { self?.togglePause() } },
            end: { [weak self] in
                // Another video opens from the layer (or the profile changed): stop here and save.
                guard let self else { return }
                controller?.setPaused(true)
                controller?.stopPictureInPicture()
                finish(natural: false)
            },
            returned: { [weak self] in self?.focusLater(.chip("pip-exit")) })
    }

    /// The PiP window was closed while the viewer browses: stop and save, and let them browse on.
    /// (With the placard in front, the picture just comes back to it, as before.)
    func pipClosedByViewer() {
        guard Platform.hooks.pipBrowseOwns(nowPlayingId) else { return }
        Platform.hooks.pipBrowseRelease(nowPlayingId, keepBrowsing: true)
        controller?.setPaused(true)
        finish(natural: false)
    }
}
