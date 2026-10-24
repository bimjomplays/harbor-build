import SwiftUI

/// PlayerSession: seeking and scrubbing (bp-player-scrub.tsx, speed-menu.tsx).
extension PlayerSession {
    /// bp-player-scrub.tsx nudge(): each press adds a step to one pending seek, committed 420 ms after
    /// the last; a held direction ramps the step 1× → 3× (after 10) → 6× (after 26).
    func nudgeSeek(ahead: Bool) {
        guard controller != nil else { return }
        // A swipe on the touch surface also arrives as a move command: the scrub owns it.
        if Date().timeIntervalSince(lastScrubAt) < 0.35 { return }
        let run = seekRun
        seekRun = run + 1
        let scale: Double = run < 10 ? 1 : (run < 26 ? 3 : 6)
        let delta = (ahead ? prefs.seekForwardStepSec : -prefs.seekBackStepSec) * scale
        let base = pendingSeek ?? clock.snap.position
        let cap = clock.snap.duration > 0 ? clock.snap.duration - 1 : base + delta
        pendingSeek = max(0, min(cap, base + delta))
        wake()
        commitSeek(after: 420)
    }

    /// The pending seek lands `ms` after the last press or swipe (0: now).
    func commitSeek(after ms: Int) {
        seekCommit?.cancel()
        seekCommit = Task { [self] in
            if ms > 0 { try? await Task.sleep(for: .milliseconds(ms)) }
            if Task.isCancelled { return }
            if let target = pendingSeek {
                resumeGuard.viewerMoved()
                controller?.seek(to: target)
                clock.seeked(to: target)
            }
            pendingSeek = nil
            seekRun = 0
        }
    }

    /// Siri Remote swipe scrubbing (RemoteScrubCatcher): the playhead
    /// follows the swipe; it lands half a second after the finger lifts, with the time bubble over
    /// the bar.
    func scrubSwipe(_ fraction: CGFloat) {
        let duration: Double = clock.snap.duration
        guard controller != nil, duration > 0 else { return }
        lastScrubAt = Date()
        if scrubBase == nil {
            seekCommit?.cancel()
            scrubBase = pendingSeek ?? clock.snap.position
        }
        // A 40 % swipe on the remote read as half the screen's width; a full
        // swipe now moves 10 % of the film (1 to 10 minutes).
        let span: Double = min(600, max(60, duration * 0.1))
        let target: Double = (scrubBase ?? 0) + Double(fraction) * span
        pendingSeek = max(0, min(duration - 1, target))
        wake()
    }

    func scrubSwipeEnded() {
        lastScrubAt = Date()
        scrubBase = nil
        if pendingSeek != nil { commitSeek(after: 500) }
    }

    /// Scrubbing makes sense while the video or the scrubber holds the ring, with nothing over them.
    var scrubEnabled: Bool {
        guard !isLive, panel == nil, !leaveConfirm, resumePending == nil, !pipActive, !stillPrompt else { return false }
        return focus == .surface || focus == .chip("scrubber")
    }

    /// Select on the focused scrubber: lands a pending seek at once, else play / pause.
    func scrubberSelect() {
        if pendingSeek != nil { commitSeek(after: 0) } else { togglePause() }
        wake()
    }

    /// use-bp-playback seekBy: one step, clamped inside the file.
    func seekBy(_ delta: Double) {
        let target = clock.snap.position + delta
        let clamped = clock.snap.duration > 0 ? min(clock.snap.duration - 1, max(0, target)) : max(0, target)
        resumeGuard.viewerMoved()
        controller?.seek(to: clamped)
        clock.seeked(to: clamped)
    }

    /// bridge setRate for a new engine: the rate this player is at (defaultPlaybackSpeed to start).
    func applyRate(_ c: any PlayerEngineControlling) {
        if abs(rate - 1) > 0.001 { c.setRate(rate) }
    }

    /// speed-menu.tsx onRate; shell-layer.tsx remembers it for the show (writePlayerPrefs rate).
    func setRate(_ value: Double) {
        guard value.isFinite, value > 0 else { return }   //
        rate = value
        controller?.setRate(value)
        if let m = trackMemory { TrackPlanner.send("player.rememberRate", [m, value]) }
    }
}
