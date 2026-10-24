import SwiftUI

/// PlayerSession: engines (use-player-bridge.ts, header-warning.tsx).
extension PlayerSession {
    /// source-error-card "Pick another source" has somewhere to go: the in-place switcher, or a
    /// caller that reopens the picker.
    var canPickAnother: Bool { canSwitchInPlace || onChooseAnother != nil }

    /// source-error-card onPickAnother = player.tsx pickAnotherOrGuide →
    /// use-stream-switcher pickAnother: "Always open the in-place switcher overlay. NEVER navigate to
    /// the full picker from here" (the player stays, and the swap resumes at the last good spot).
    /// The card steps aside while the switcher is open and comes back if it closes with no swap.
    /// Where the switcher cannot swap (canSwitchInPlace: a home-server copy, a playlist item, a kid
    /// profile), the player closes and the caller reopens the picker, as before.
    func pickAnotherSource() {
        if canSwitchInPlace {
            open(.sources)
            return
        }
        guard let go = onChooseAnother else { return }
        finish(natural: false, reopening: true)
        go()
    }

    /// use-player-bridge.ts:176-186: in Auto, an html5 decode/codec failure or silent audio moves
    /// the stream to mpv once (autoFallbackTried). A chosen native engine keeps playing and, for
    /// silent audio, shows player.tsx's NoAudioWarning instead.
    func nativeUnsupported(_ reason: String) {
        guard engine == .native, !finishing else { return }
        if engineWant == "auto", !engineFallbackTried {
            engineFallbackTried = true
            switchToMpv()
        } else if reason == "noAudio" {
            noAudioWarning = true
            hideTask?.cancel()
            focusLater(.chip("Use mpv engine"))
        }
    }

    /// header-warning.tsx onUseMpv → update({ playerEngine: "mpv" }), then this stream moves over.
    func useMpvEngine() {
        Task { try? await SettingsBridge.shared.patch(["playerEngine": .string("mpv")]) }
        engineWant = "mpv"
        switchToMpv()
    }

    /// use-player-bridge.ts chosenEngine / pickBridge for the source about to play.
    /// `false` when another channel was tuned while the rule ran; that tune settles its own.
    @discardableResult
    func settleEngine(for target: URL, hints: PlayerStreamHints?) async -> Bool {
        let choice = await PlayerEngineChoice.choose(url: target, isLive: isLive, hints: hints)
        guard playURL == target else { return false }
        engine = PlayerFixtures.engineOverride ?? choice.engine
        engineWant = choice.want
        engineFallbackTried = false
        noAudioWarning = false
        return true
    }

    /// Hands the stream to mpv where the native player left it (or where it was to start).
    func switchToMpv() {
        let at = clock.snap.position > 5 ? clock.snap.position : (startAt ?? 0)
        noAudioWarning = false
        controller = nil
        status = MPVPlayerController.Status()
        loadingSince = Date()
        anime4kAppliedFor = -1
        engine = .mpv
        startAt = at
        reloadToken += 1
        focus = .surface
        wake()
    }
}

extension PlayerSession {
    /// The PiP and AirPlay buttons on mpv, which has neither: this stream moves to
    /// AVPlayer where mpv left it. Only for this stream (the Player setting is not touched), and
    /// the move to mpv for an unsupported codec is not tried again from here.
    func switchToNative() {
        guard engine != .native, !finishing else { return }
        let at = clock.snap.position > 5 ? clock.snap.position : (startAt ?? 0)
        noAudioWarning = false
        controller = nil
        status = MPVPlayerController.Status()
        loadingSince = Date()
        anime4kAppliedFor = -1
        engine = .native
        engineWant = "native"
        engineFallbackTried = true
        startAt = at
        reloadToken += 1
        focus = .surface
        wake()
    }
}
