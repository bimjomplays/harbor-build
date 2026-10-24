import SwiftUI

/// PlayerSession: saves, scrobbles and closing (use-resume-autosave, scrobble-hook.ts, use-exit-snapshot.ts).
extension PlayerSession {
    /// lib/trakt/scrobble-hook.ts: "start" when playing, "pause" on pause, "stop" at the end.
    func scrobbleTick() {
        // Not before playback has started at the resume spot: a "pause" at 0 % rewrote the
        // tracker's saved progress the same way the save tick did.
        guard let context, !context.playlistVod, !isLive, clock.snap.duration > 150, !resumeGuard.armed else { return }
        let paused = clock.snap.paused
        if scrobbleState == nil, !paused, clock.snap.position > 1 { sendScrobble("start") }
        else if scrobbleState == "start", paused, !lastScrobblePaused { sendScrobble("pause") }
        else if scrobbleState == "pause", !paused { sendScrobble("start") }
        lastScrobblePaused = paused
        _ = context
    }

    func sendScrobble(_ action: String) {
        guard let context else { return }
        scrobbleState = action
        let progress = clock.snap.duration > 0 ? clock.snap.position / clock.snap.duration * 100 : 0
        let ep: AnyJSON = context.season.map { s in
            .object(["season": .number(Double(s)), "episode": .number(Double(context.episode ?? 1)),
                     "imdbId": context.imdbId.map { .string($0) } ?? .null,
                     "imdbSeason": .number(Double(s)), "imdbEpisode": .number(Double(context.episode ?? 1))])
        } ?? .null
        let year = context.meta.releaseInfo.flatMap { Double($0.prefix(4)) }
        let info: AnyJSON = .object(["title": .string(context.meta.name), "year": year.map { .number($0) } ?? .null, "imdb": context.imdbId.map { .string($0) } ?? .null])
        Task {
            _ = try? await HarborEngine.shared.callJSON("trakt.scrobble", [.string(action), .string(context.meta.id), ep, .number(progress)])
            _ = try? await HarborEngine.shared.callJSON("simkl.scrobble", [.string(action), .string(context.meta.id), ep, .number(progress), info])
        }
    }

    /// use-resume-autosave.ts: every 4 s (TICK_MS) while playing, only if moved ≥ 1.5 s since the last save.
    /// The 4 s was never enforced: the 1 s tick saved whenever the position had moved
    /// 1.5 s, so every other second, and each save rewrote the whole `harbor.resume` map and the local
    /// Continue Watching list (both through to disk) and, signed in to Stremio, did a library GET + PUT.
    /// A pause saves at once and counts as a flush (use-resume-autosave persistNow(true) and
    /// use-stremio-sync's write on "paused"); the engine keeps the cloud write to its 30 s tick otherwise.
    func saveTick(flush: Bool) async {
        guard let c = controller, let context else { return }
        let s = c.snapshot()
        // Nothing is saved before playback has started at the spot it was sent to: the early
        // position (0, the file's first frames) would overwrite the saved progress, here and in Stremio.
        guard resumeGuard.allowsSave(position: s.position, duration: s.duration) else { return }
        let pausedNow = s.paused && !lastSavePaused
        lastSavePaused = s.paused
        let due = Date().timeIntervalSince(lastSaveAt) >= 4
        let flushing = flush || (pausedNow && s.position > 0)
        guard s.duration > 0, flushing || (!s.paused && due && abs(s.position - lastSavedPos) >= 1.5) else { return }
        lastSavedPos = s.position
        lastSaveAt = Date()
        _ = await context.save(positionSec: s.position, durationSec: s.duration, flush: flushing)
        homeServerTick(s, flush: flush)
    }

    /// progress-sync.ts: every 15 s while playing, on pause, and when leaving; titles under 150 s never.
    func homeServerTick(_ s: (position: Double, duration: Double, paused: Bool), flush: Bool) {
        guard let context, context.homeServer != nil, s.duration >= 150 else { return }
        let now = Date().timeIntervalSince1970
        let pausedNow = s.paused && !lastHomePaused
        lastHomePaused = s.paused
        guard flush || pausedNow || (!s.paused && now - lastHomeReport >= 15) else { return }
        lastHomeReport = now
        let watched = s.position / s.duration >= 0.9
        Task { await context.reportHomeServer(positionSec: s.position, durationSec: s.duration, watched: watched) }
    }

    /// request-player-close.ts: Back leaves at once unless playerConfirmLeave is on.
    func requestClose() {
        if !isLive, SettingsBridge.shared.slice.playerConfirmLeave ?? true {
            leaveRemember = false
            let wasPlaying: Bool = controller.map { !$0.snapshot().paused } ?? true
            leaveResumes = wasPlaying
            leaveConfirm = true
            controller?.setPaused(true)
            if let c = controller { takeSnap(c.snapshot()) }
            hideTask?.cancel()
            focusLater(.chip("Keep watching"))
        } else {
            finish(natural: false)
        }
    }

    /// bp-leave-confirm close (Keep watching, Back): the dialog goes, and the video plays again
    /// only if it was playing when it opened.
    func keepWatching() {
        leaveConfirm = false
        if leaveResumes { controller?.setPaused(false) }
        if let c = controller { takeSnap(c.snapshot()) }
        focus = .surface
        wake()
    }

    func acknowledgeResume(_ resume: Bool) {
        guard let sec = resumePending else { return }
        resumePending = nil
        // Start over is the viewer's choice of 0:00; Resume re-arms the guard below (startAt).
        if !resume || sec <= 0 { resumeGuard.viewerMoved() }
        if resume, sec > 0 {
            controller?.seek(to: sec)
            // The engine opened at 0 under the fork: a Try again, the move
            // to mpv or an early-end reload started from there instead of the spot just resumed.
            startAt = sec
        }
        controller?.setPaused(false)
        focus = .surface
        scheduleHide()
    }

    /// use-queue-nav playPrev: the previous episode's picker opens once the player has closed.
    func previousEpisode() {
        guard let go = onPreviousEpisode else { return }
        finish(natural: false, reopening: true)
        go()
    }

    /// `natural`: the file played to its end (saved as finished). `advance`: the caller should move
    /// on to the next episode (defaults to `natural`, the way onClose always read).
    /// `reopening`: the caller opens another player right away, from its picker (another episode or
    /// source; defaults to an advance with a next episode).
    /// `sendingBack`: sendBackToPicker's close (onStubEject / the auto-next open the picker without
    /// closePlayer), which takes no exit frame.
    func finish(natural: Bool, advance: Bool? = nil, reopening: Bool? = nil, sendingBack: Bool = false) {
        // "Play now" and the file's own end can both land in the last second; close once.
        guard !finishing else { return }
        finishing = true
        // Closing while the PiP browse layer is over this player: the layer goes down too, so what
        // the caller opens next (the next episode, the picker) is on screen. Closes that leave the
        // viewer browsing released the layer before this.
        Platform.hooks.pipBrowseRelease(nowPlayingId, keepBrowsing: false)
        if scrobbleState != nil {
            let progress = clock.snap.duration > 0 ? (natural ? 100 : clock.snap.position / clock.snap.duration * 100) : 0
            sendScrobble(progress >= 90 ? "stop" : "pause")
        }
        // use-player-exit.ts closePlayer → captureExitSnapshot, first: the frame is taken now,
        // while the engine is still up, and saved off the main thread; the close never waits for it.
        // Not for a stream sent back to the picker (a stub, a stall, an auto
        // pick that failed): use-player-exit onStubEject and views/player.tsx's auto-next open the
        // picker without closePlayer, so no frame is taken; here a stub's placeholder picture
        // replaced the title's Continue Watching frame. A frame kept while it played stays.
        // Keyed by this close, not by sentBack: a send-back refused past the fifth
        // attempt (or with no stream ref to mark) keeps the player, and sentBack with it, so a
        // stream that then played and was closed by hand took no frame either.
        if !isLive, !sendingBack {
            let live: (position: Double, duration: Double, paused: Bool) = controller?.snapshot() ?? clock.snap
            exitSnapshot.captureOnExit(controller: controller, context: context, position: live.position, duration: live.duration)
        }
        // Nothing plays on under a closing player (Next episode, Play now, Sources
        // and a Back without the leave dialog kept the film and its sound going through the close).
        controller?.setPaused(true)
        // bp-player-scrub's pending nudge dies with the player: committed
        // 420 ms after the last press, it seeked the closing video.
        seekCommit?.cancel()
        pendingSeek = nil
        let advancing: Bool = advance ?? natural
        Task { @MainActor [self] in
            // use-player-exit closePlayer saves the spot locally and leaves; the
            // Stremio library write goes on by itself. Here the close waited for the whole flushed
            // save (a Stremio GET + PUT, the home server's report and stop): seconds on a slow
            // connection, up to the request timeout on one that had just dropped, with the viewer
            // stuck on the error card or the last frame. The engine's local write lands first (its
            // calls run in order), so the close waits for the saves at most 2 s; they finish after.
            let saved = PlayerCloseFlag()
            Task { @MainActor [self] in
                await closeSaves(natural: natural)
                saved.done = true
            }
            var waited = 0
            while !saved.done, waited < 40 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waited += 1
            }
            SleepTimer.shared.playerClosed(advancing: advancing)
            // use-still-watching counts auto-advanced episodes in a row: a close that doesn't advance ends the run.
            if !advancing { StillWatching.reset() }
            onClose(advancing)
            // The watched check on the tiles reads the flags this session just wrote.
            await CardMarksStore.shared.remark()
        }
    }

    /// The close's saves: the finished spot (a natural end) or the last one, then the home server's
    /// report and session stop. The spot is read before the first wait: once the close has gone on
    /// without them, the torn-down engine reads 0.
    func closeSaves(natural: Bool) async {
        let s: (position: Double, duration: Double, paused: Bool)? = controller?.snapshot()
        if natural, let context, let s, s.duration > 0 {
            _ = await context.save(positionSec: s.duration, durationSec: s.duration, flush: true)
            if s.duration >= 150 { await context.reportHomeServer(positionSec: s.duration, durationSec: s.duration, watched: true) }
        } else {
            await saveTick(flush: true)
        }
        // Closed before the start seek landed: the server keeps the spot it gave.
        if let context, context.homeServer != nil, let s { await context.stopHomeServerSession(positionSec: resumeGuard.reported(position: s.position)) }
    }
}

/// PlayerSession.finish: the close's saves are done.
@MainActor
private final class PlayerCloseFlag {
    var done = false
}
