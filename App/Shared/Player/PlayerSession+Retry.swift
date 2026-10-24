import SwiftUI

/// PlayerSession: retries, live channels and the next stream (use-auto-retry.ts, use-live-channel-overlay.ts, views/player.tsx autoNextStreamOnStall, use-stub-detection.ts).
extension PlayerSession {
    /// views/player.tsx `src.autoFired && !src.isLive`, plus a caller that can reopen the
    /// picker; a stream swapped in place (the kid switcher) was chosen by hand.
    var autoPickLive: Bool {
        pick?.autoPicked == true && onPickAgain != nil && !isLive && switched == nil
            && !playbackStarted && !sentBack && !finishing
            // Not while the viewer is choosing another source in the switcher over it.
            && panel != .sources
    }

    /// lib/player/stall-wait.ts hasPlaybackStartedForStallCheck: paused, a position, or a picture.
    func notePlaybackStarted() {
        guard !playbackStarted, let c = controller else { return }
        // Upstream's "paused" is a snapshot status: mpv.ts sets it at file-loaded, the
        // html5 bridge only from readyState >= 3, so it means an open stream that is paused. The
        // TV's snap.paused is the pause flag, set before anything opens (held for the resume prompt,
        // pausedAfterSwitch), which counted a stream that never connected as started and turned the
        // stall skip off. A pause counts once the engine reports the file open.
        let opened = status.state == "playing" || status.state == "buffering/paused"
        if (clock.snap.paused && opened) || clock.snap.position > 0 || c.videoWidth() > 0 { playbackStarted = true }
    }

    /// views/player.tsx (opt-in autoNextStreamOnStall): an auto-picked stream that has not started
    /// within the wait is marked dead and the picker fires the next candidate. First load only.
    func stallTick() {
        notePlaybackStarted()
        guard autoPickLive, prefs.autoNextStreamOnStall, status.state != "error",
              Date().timeIntervalSince(openedAt) >= prefs.autoNextStreamOnStallSec else { return }
        sendBackToPicker(auto: true, markDead: true)
    }

    /// views/player.tsx: `snap.status === "error"` on an auto pick that never played (not gated by
    /// the setting) marks it dead and fires the next candidate instead of the source error card.
    func autoNextOnError() {
        notePlaybackStarted()
        guard autoPickLive else { return }
        sendBackToPicker(auto: true, markDead: true)
    }

    /// use-stub-detection.ts (under instantPlay): a movie or episode whose file is under
    /// SHORT_PLAYBACK_SEC while playing is checked once; the engine marks a stub dead, records the
    /// event for the next picker's notice and forgets the remembered pick (onStubEject), and the
    /// picker comes back firing on its own, up to MAX_AUTORETRY_ATTEMPTS (5), then the player just closes.
    func stubTick() {
        guard prefs.instantPlay, !stubChecked, onPickAgain != nil, !isLive, switched == nil, !sentBack, !finishing,
              let context,
              clock.snap.duration > 0, clock.snap.duration < 180, status.state == "playing" else { return }
        stubChecked = true
        struct StubInput: Encodable {
            var meta: Meta; var url: String; var title: String; var ref: AnyJSON?
            var durationSec: Double; var playing: Bool; var season: Int?; var episode: Int?
        }
        let input = StubInput(meta: context.meta, url: url.absoluteString, title: title, ref: pick?.streamRef,
                              durationSec: clock.snap.duration, playing: true, season: context.season, episode: context.episode)
        let nextAttempt = (pick?.attempt ?? 0) + 1
        Task { @MainActor [self] in
            let flagged: Bool = (try? await HarborEngine.shared.call("deadStreams.flagStub", [input])) ?? false
            guard flagged, !sentBack, !finishing else { return }
            if nextAttempt > 5 { finish(natural: false); return }
            sendBackToPicker(auto: true, markDead: false)
        }
    }

    /// Close, then hand back to the caller's picker. The dead mark lands in the engine first, so
    /// the reopened picker's auto candidates (isStreamDead) already skip this stream.
    func sendBackToPicker(auto: Bool, markDead: Bool) {
        guard let again = onPickAgain, !sentBack, !finishing else { return }
        sentBack = true
        let ref = markDead ? pick?.streamRef : nil
        // MAX_AUTORETRY_ATTEMPTS, and a stream that can't be marked would only fire again: the
        // stream is still marked, but the viewer keeps the error / connecting card and decides.
        if (pick?.attempt ?? 0) + 1 > 5 || (markDead && ref == nil) {
            if let ref { Task { _ = try? await HarborEngine.shared.callJSON("deadStreams.markDead", [ref, .string("load-failed")]) } }
            return
        }
        finish(natural: false, reopening: true, sendingBack: true)
        Task { @MainActor in
            if let ref { _ = try? await HarborEngine.shared.callJSON("deadStreams.markDead", [ref, .string("load-failed")]) }
            again(auto)
        }
    }

    /// use-auto-end-exit.ts, live only: a channel that ran out (mpv's keep-open holds its
    /// last frame, AVPlayer ends the item) is reloaded after LIVE_RELOAD_DELAY_MS (1 s), up to
    /// LIVE_RELOAD_MAX (5) times in LIVE_RELOAD_WINDOW_MS (15 s); past that the player closes after
    /// POST_END_DELAY_MS (800 ms). Only a natural end (isNaturalEnd) counts. Upstream's
    /// `durationSec <= 0` early return is not carried over: the TV snapshots fold a live stream's
    /// infinite duration into 0, which upstream lets through.
    func liveEnded() {
        guard isLive, !finishing else { return }
        if let c = controller {
            let s = c.snapshot()
            guard PlaybackEnd.isNatural(position: s.position, duration: s.duration) else { return }
        }
        let now = Date()
        var recent = liveReloadTimes.filter { now.timeIntervalSince($0) < 15 }
        let token = reloadToken
        liveEndTask?.cancel()
        if recent.count < 5 {
            recent.append(now)
            liveReloadTimes = recent
            liveEndTask = Task { @MainActor [self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                // The effect's cleanup upstream: a status change, a retry or a tune meanwhile cancels it.
                guard !Task.isCancelled, !finishing, token == reloadToken, status.state == "ended" else { return }
                // reloadLive: the same source again (as the live error card's Try again).
                status = MPVPlayerController.Status()
                loadingSince = Date()
                controller = nil
                reloadToken += 1
            }
            return
        }
        liveReloadTimes = recent
        liveEndTask = Task { @MainActor [self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, !finishing, token == reloadToken, status.state == "ended" else { return }
            finish(natural: false)
        }
    }

    /// use-auto-retry.ts:141-160, live only: a channel that errors is loaded
    /// again after 1.5 s, or 4 s once it has played; one reconnect before it ever played, two after
    /// (per channel, never reset by the reconnect itself). The error card waits for the last one
    /// to fail (liveGaveUp). Upstream mounts LiveChannelError on the error at once and swaps it for
    /// the loader when the reconnect fires; here it stays down until the reconnects are spent, so
    /// its onAppear does not pull the ring onto a card that is about to go.
    func liveErrored() {
        guard isLive, !finishing, !liveGaveUp else { return }
        let attempt: Int = liveRetries + 1
        let delay: UInt64 = livePlayed ? 4_000_000_000 : 1_500_000_000
        let token = reloadToken
        liveRetryTask?.cancel()
        liveRetryTask = Task { @MainActor [self] in
            try? await Task.sleep(nanoseconds: delay)
            // The effect's cleanup upstream: the error clearing, a retry or a tune meanwhile cancels it.
            guard !Task.isCancelled, !finishing, token == reloadToken, status.state == "error" else { return }
            liveRetries = attempt
            reloadSame()
        }
    }

    /// use-auto-retry.ts maxAttempts: `livePlayedRef.current ? 2 : 1`.
    var liveGaveUp: Bool { liveRetries >= (livePlayed ? 2 : 1) }

    /// use-auto-retry.ts livePlayedRef: set once the channel has a position or a buffer (hasProgress).
    /// Only with a player: the clock keeps the last channel's reading until the new one's first tick.
    func noteLivePlayed() {
        guard isLive, !livePlayed, controller != nil else { return }
        let progress: Bool = clock.snap.position > 0.5 || clock.buffered > 0.5
        if progress { livePlayed = true }
    }

    /// use-started-near-end.ts: the first reading while playing, with a length and a position, says
    /// whether this stream started at 80% or later (re-watching an ending). Such a stream does not
    /// auto-advance, go on through the queue or close by itself at its end (use-auto-next-episode,
    /// use-queue-advance, use-auto-end-exit). A new src.url (a tuned channel, a home-server quality) takes a new reading.
    /// Keyed by upstream's src.url (srcURL), not the URL playing: player.tsx
    /// passes src.url, which use-stream-switcher's in-place swap leaves alone (it moves liveUrl). A
    /// source switched at 85% of a film took a new reading there, so the end of that film no longer
    /// moved on to the next episode, asked Still watching or closed. Only with a player: the clock
    /// holds the last stream's reading until the new one's first tick.
    func noteStartedNearEnd() {
        let src: URL = srcURL
        guard nearEndCapturedFor != src, status.state == "playing", controller != nil else { return }
        let dur: Double = clock.snap.duration
        let pos: Double = clock.snap.position
        guard dur > 0, pos > 0 else { return }
        nearEndCapturedFor = src
        startedNearEnd = pos / dur >= 0.8
    }

    /// startedNearEndRef.current for the stream on screen (false until its reading is taken).
    var startedNearEndNow: Bool { nearEndCapturedFor == srcURL && startedNearEnd }

    /// use-auto-retry.ts premature EOF (isTruncatedEnd): a stream that
    /// ends well short of its length (the connection dropped and mpv played out its cache, or
    /// AVPlayer's item ran out) sat frozen on its last frame with nothing on screen to press. It is
    /// loaded once more, from where it stopped (reloadSource's resumeAt); a second early end shows
    /// the source error card. Local files and live channels are left alone, as upstream does.
    func truncatedEnd() {
        guard !isLive, !finishing, !playURL.isFileURL, let c = controller else { return }
        let s = c.snapshot()
        guard !PlaybackEnd.isNatural(position: s.position, duration: s.duration) else { return }
        if !truncatedReloaded {
            truncatedReloaded = true
            reloadSame(from: s.position)
            return
        }
        endedEarly = "The stream stopped before the end of the file."
        hideTask?.cancel()
    }

    /// views/player.tsx reloadSource: the same source again from where it was (resumeAt > 5), a
    /// live channel from its edge. Every Try again restarted at the
    /// opening spot (0, or the resume point), so a film that failed an hour in began again.
    /// Once the engine has failed the tick reads 0 from it, so the last saved spot stands in.
    func reloadSame(from position: Double? = nil) {
        if !isLive {
            let at = position ?? (clock.snap.position > 0 ? clock.snap.position : lastSavedPos)
            if at > 5 { startAt = at }
        }
        status = MPVPlayerController.Status()
        loadingSince = Date()
        controller = nil
        reloadToken += 1
    }

    /// switchChannel: the new stream replaces the old one in place; the channel we leave goes on
    /// the "Previous channel" stack (12 deep, no repeats on top).
    func tune(_ ch: LiveModel.Channel) {
        let from = currentChannel
        guard ch.id != from?.id else { closePanel(); return }
        if let from {
            if prevChannels.last?.id != from.id { prevChannels.append(from) }
            if prevChannels.count > 12 { prevChannels.removeFirst() }
        }
        tuned = ch
        liveGuide?.played(ch)
        // use-auto-end-exit.ts resets its reload count per source.
        liveEndTask?.cancel()
        liveReloadTimes = []
        // use-auto-retry.ts resets its live reconnects per source (src.url).
        liveRetryTask?.cancel()
        liveRetries = 0
        livePlayed = false
        status = MPVPlayerController.Status()
        loadingSince = Date()
        controller = nil
        // A new channel is a new source: the engine rule runs again before it plays
        // (use-player-bridge.ts keys the bridge on the source).
        startAt = nil
        let target = playURL
        Task { [self] in
            guard await settleEngine(for: target, hints: nil) else { return }
            // As switchStream: no new engine under a closing player.
            guard !finishing else { return }
            startAt = 0
            reloadToken += 1
        }
        if panel != nil { closePanel() } else { wake() }
    }

    /// goPrevChannel: pop to the last channel that is not the one playing; tuning it pushes the
    /// one we leave, so the button flips between the two most recent channels.
    func goPrevChannel() {
        let playing = currentChannel?.id
        var prev = prevChannels.popLast()
        while let p = prev, p.id == playing { prev = prevChannels.popLast() }
        guard let prev else { return }
        tune(prev)
    }
}
