import SwiftUI

/// PlayerSession: what the screen's lifecycle, timer and engine callbacks drive (the closures that
/// PlayerScreen's body used to carry). A screen forwards its events here and draws what changes.
extension PlayerSession {
    // MARK: engines reporting in

    /// NativePlayerView.onReady (`token`: the reloadToken the view was built under).
    func nativeReady(_ c: any PlayerEngineControlling, token: Int) {
        // Delivered a main-queue turn after creation: a player
        // replaced meanwhile (a reload, the engine switch) must not claim it.
        guard engine == .native, token == reloadToken else { return }
        controller = c
        engineReplaced()
        // AVPlayer has no audio offset (BpAudioLane locked): the readout says 0 again.
        audioDelay = 0
        applyRate(c)
        // The rail's mute outlives the stream, as
        // it does on upstream's one bridge (a load keeps the muted flag).
        if muted { c.setMuted(true) }
        if resumePending != nil || pausedAfterSwitch { c.setPaused(true); pausedAfterSwitch = false }
    }

    /// MPVPlayerView.onReady.
    func mpvReady(_ c: any PlayerEngineControlling, token: Int) {
        // onReady lands a main-queue turn after the controller is
        // made: one replaced meanwhile (two reloads, the switch to AVPlayer) is
        // not made current, and does not use up pausedAfterSwitch.
        guard engine != .native, token == reloadToken else { return }
        controller = c
        engineReplaced()
        // A retry, a quality / kid switch or the move to mpv
        // starts a new mpv at audio-delay 0 while the Audio dialog still read the
        // viewer's offset: it carries over, as it does in upstream's one mpv.
        if audioDelay != 0 { c.setAudioDelay(audioDelay) }
        applyRate(c)
        // A source switched in place, a retry or a
        // live reconnect starts a new engine unmuted while the rail still
        // read "Muted" until the next tick: the mute carries over, as the
        // muted flag does across upstream's bridge.load().
        if muted { c.setMuted(true) }
        if resumePending != nil || pausedAfterSwitch { c.setPaused(true); pausedAfterSwitch = false }
    }

    // MARK: the screen appearing and going

    /// use-player-media: a torrent served by the TV's engine belongs to this player while it is
    /// open, and is removed once it closes (TorrentEngine; a no-op for every other URL).
    func appeared() {
        if !openedOnce {
            openedOnce = true
            // A player opened from the PiP browse layer: the one in PiP stops and saves first.
            inBrowseLayer = Platform.hooks.pipBrowseUp
            Platform.hooks.pipBrowsePlaybackOpening(nowPlayingId)
            // settings.tsx setSnapshotRetentionDays: expired frames go (all of them at 0 days).
            ExitSnapshotStore.pruneSoon(retentionDays: ExitSnapshotSettings.current.days)
        }
        // The stream playing now, as onDisappear releases it: after a kid / quality
        // switch, a re-appear used to re-own the original torrent and leave the playing one to
        // be removed under the player.
        focus = .surface; scheduleHide(); PlaybackState.shared.claim(nowPlayingId); TorrentEngine.shared.playerOpened(url: switched?.url ?? url)
        SleepTimer.shared.playerOpened(url: url)
        // use-sleep-timer.ts registerSleepFireHandler: a minutes timer running out pauses this player.
        // The handlers live in singletons: they hold the session weakly.
        SleepTimer.shared.register(nowPlayingId) { [weak self] in self?.sleepFired() }
        beginNowPlaying()
        // An addon install deep link closes this player first, with
        // no "Keep watching?" dialog (finish(natural: false), like the curfew lock's own forced
        // close, curfewChanged).
        PlaybackState.shared.setCloseHandler(nowPlayingId) { [weak self] in self?.finish(natural: false) }
    }

    func disappeared() {
        PlaybackState.shared.setCloseHandler(nowPlayingId, nil)
        SleepTimer.shared.unregister(nowPlayingId)
        skipHideTask?.cancel()
        seekCommit?.cancel()
        // The nudge it held goes with it: a player that comes back (the PiP browse
        // layer) showed the uncommitted spot on the bar and counted the next nudge from it.
        pendingSeek = nil
        seekRun = 0
        // media-session.ts clearMediaControls.
        VideoNowPlaying.shared.end(nowPlayingId)
        // A player torn down while it owned the PiP browse layer (the tree rebuilt) takes it down.
        Platform.hooks.pipBrowseRelease(nowPlayingId, keepBrowsing: false)
        PlaybackState.shared.release(nowPlayingId); TorrentEngine.shared.playerClosed(url: switched?.url ?? url)
    }

    /// The curfew lock came on.
    func curfewChanged(_ locked: Bool) {
        if locked { finish(natural: false) }
    }

    /// The app declares background audio (for Picture in Picture); on the TV a film or channel still
    /// stops when the viewer leaves the app (mpv would otherwise keep sounding), unless it is
    /// playing in Picture in Picture, which is how it keeps going over other apps.
    /// The phone (`keepsPlayingInBackground`) keeps playing: the sound goes on
    /// in the background and the picture in PiP when the engine has it. Either way the spot is written
    /// now, and the position is the engine's own, so nothing seeks on return.
    func didEnterBackground() {
        if keepsPlayingInBackground {
            controller?.appBackgrounded(true)
        } else if controller?.isPictureInPictureActive != true {
            controller?.setPaused(true)
        }
        // use-resume-autosave / use-stremio-sync on pagehide: the spot is written now,
        // not left to a tick that may never run once the app is suspended.
        if !finishing { Task { [self] in await saveTick(flush: true) } }
    }

    /// The app is back on screen: the picture returns where the engine let it go, and a torrent that
    /// stopped while the app was away says so (the phone only).
    func willEnterForeground() {
        if keepsPlayingInBackground {
            controller?.appBackgrounded(false)
            let playingNow: Bool = controller.map { !$0.snapshot().paused } ?? false
            backgroundNote = Self.backgroundTorrentNote(isTorrent: TorrentEngine.streamRef(playURL) != nil, playingNow: playingNow)
        }
        wake()
    }

    /// "Torrents in the background keep running only while audio/PiP keeps the
    /// app alive; the readout says when the stream paused." Back on screen with a torrent stream that
    /// is not playing (paused as the app left, or stopped in the background when PiP closed), the
    /// download was not running meanwhile: the line says so. nil for anything else.
    static func backgroundTorrentNote(isTorrent: Bool, playingNow: Bool) -> String? {
        guard isTorrent, !playingNow else { return nil }
        return T("The torrent stream paused while Harbor was in the background. Press play to carry on.")
    }

    // MARK: opening the stream

    /// The screen's `.task`: settles the engine, reads the resume spot and the player prefs, and
    /// lets the engine view build (`startAt` set).
    func start() async {
        // use-player-bridge.ts / player-utils.ts pickBridge: settle the engine before anything loads.
        await settleEngine(for: playURL, hints: streamHints)
        // use-bridge-load: no resume for live or when the viewer turned it off; a saved spot past
        // RESUME_PROMPT_MIN_SEC (30 s) becomes a fork when resumePrompt is on, else a silent seek.
        let slice = SettingsBridge.shared.slice
        var sec = (!isLive && (slice.resumePlayback ?? true)) ? (await context?.startPosition() ?? 0) : 0
        // A source switch or a home-server copy carries its own position (use-bridge-load hasExplicitStart).
        if let x = context?.explicitStartSec, x > 0 { sec = x }
        else if let h = context?.homeServer, h.resumeSec > 0 { sec = h.resumeSec }
        if sec <= 5 { sec = 0 }
        // use-track-autoload.ts prefsAppliedRef: a title starts at the show's remembered rate
        // (player-prefs), else settings.defaultPlaybackSpeed (live has no speed).
        // Not for kid profiles: their transport has no speed control, and player-prefs is keyed by
        // show, not profile (an adult's 1.5x would stick for a kid).
        if !isLive, isKid { rate = 1 }
        else if !isLive {
            let rp = ProfilesStore.shared.active
            let remembered: Double? = try? await HarborEngine.shared.call("player.startRate", [rp?.id ?? "default", rp?.linked ?? true, trackMemory] as [any Encodable])
            if let r = remembered ?? slice.defaultPlaybackSpeed, r.isFinite, r > 0 { rate = r }
        }
        if sec > 30, slice.resumePrompt ?? false, !isLive {
            resumePending = sec
            startAt = 0
            focusLater(.chip("Pick up where you left off"))
        } else {
            startAt = sec
        }
        let profile = ProfilesStore.shared.active
        do {
            let loaded: PlayerPrefs = try await HarborEngine.shared.call("player.prefs", [profile?.id ?? "default", profile?.linked ?? true])
            prefs = loaded
            // A player that closed meanwhile must not claim Now Playing back.
            if !Task.isCancelled, !finishing { beginNowPlaying() }   // the remote's skip intervals follow the seek steps
        } catch {}
    }

    // MARK: the 1 s tick

    func tick() {
        // The clock takes the snapshot and the buffered end (it keeps lastGoodPos);
        // this body's own state is written only when it changes, so a tick redraws the leaves
        // that show time and not the whole player.
        if let c = controller {
            takeSnap(c.snapshot())
            let nowMuted: Bool = c.isMuted()
            if nowMuted != muted { muted = nowMuted }
            if pipActive, !c.isPictureInPictureActive { pipChanged(false) }
            clock.updateBuffered(c.bufferedSec())
            if isKid, chrome {
                let subs: [MPVPlayerController.Track] = c.tracks().filter { $0.type == "sub" }
                if subs != kidSubs { kidSubs = subs }
            }
        }
        if status.state == "loading" { loadingBeat &+= 1 }
        // Anime4K is an mpv shader chain (html5 bridge: setAnime4kShaders() {}).
        if !isLive, engine == .mpv, let c = controller, status.state != "loading" {
            let w = c.videoWidth()
            if w > 0, w != anime4kAppliedFor { anime4kAppliedFor = w; Task { [self] in await applyAnime4k(srcWidth: w) } }
            // A chain libplacebo refused shows up in mpv's warnings: drop it rather than play blind.
            if let a = anime4k, a.active, status.log.contains(where: { $0.range(of: #"(shader|glsl|hook)"#, options: [.regularExpression, .caseInsensitive]) != nil && $0.range(of: #"(error|fail|invalid|could not)"#, options: [.regularExpression, .caseInsensitive]) != nil }) {
                var off = a; off.active = false
                anime4k = off
                anime4kNote = "mpv rejected the Anime4K shaders on this device; playing without them."
                c.setShaders([])
            }
        }
        // Not once finish() ran: the close pauses the video and saves the spot
        // itself; the tick saw that pause as a new one and flushed a second Stremio write.
        if !finishing { Task { [self] in await saveTick(flush: false) } }
        // Not once finish() ran: the close awaits the flushed save (a Stremio push)
        // before onClose, and the video plays on meanwhile. The next tick turned the closing
        // "pause" scrobble back into "start" (Trakt/Simkl showed the title as watching after
        // the viewer left).
        if !finishing {
            scrobbleTick()
            // use-exit-snapshot's playing tick: the last good frame for the exit.
            exitSnapshot.tick(controller: controller, context: isLive ? nil : context, playing: status.state == "playing",
                              position: clock.snap.position, duration: clock.snap.duration)
        }
        // useSkipSegments also reads the file's chapters (mpv chapter-list).
        // The chapter list is read only when the (whole-second) duration changes: mpv fills it with
        // the duration at file open, and reading it every tick cost two mpv reads per chapter
        // each second. A live stream (its duration grows) has no skip segments to load.
        if clock.snap.duration > 0, !isLive, let c = controller {
            let seconds = clampedInt(clock.snap.duration.rounded())
            if segmentsDuration != seconds {
                segmentsDuration = seconds
                let chapters = c.chapters()
                let key = "\(seconds)|\(chapters.count)"
                if segmentsLoadedFor != key { segmentsLoadedFor = key; Task { [self] in await loadSegments(chapters: chapters) } }
            }
        }
        skipTick()
        nowPlayingTick()
        noteLivePlayed()
        noteStartedNearEnd()
        stallTick()
        stubTick()
    }

    // MARK: state changes the screen watches

    /// views/player.tsx: an auto pick that fails before it ever played goes on to the next source.
    func statusChanged(to state: String) {
        if state == "error" { autoNextOnError() }
        // use-auto-retry.ts: a live channel's error reconnects on its own first.
        if state == "error", isLive { liveErrored() }
        // use-auto-end-exit.ts: a live channel's end reloads it.
        if state == "ended", isLive { liveEnded() }
        // use-auto-retry.ts premature EOF.
        if state == "ended", !isLive { truncatedEnd() }
    }

    /// use-bp-player-chrome restarts the idle wait when `playing` changes: the
    /// wait that ran out while paused never came back, so a video started again without a press
    /// here (the iPhone remote, PiP's own button) kept the chrome up.
    /// isPaused follows the clock's pause flag, written only when it changes (takeSnap).
    func pausedChanged(to paused: Bool) {
        if !paused, chromeShown { scheduleHide() }
    }

    /// A retry or the switch to mpv starts the stall wait over.
    func reloadTokenChanged() {
        endedEarly = nil
        openedAt = Date()
        // The new mpv starts with no shaders: the tick keyed the chain to the
        // picture's width only, so a Try again (or a live-style reload) at the same width never
        // handed the new engine its Anime4K chain while the indicator still claimed the mode.
        anime4kAppliedFor = -1
    }

    /// Subtitles rise over the chrome while it is up (mpv only).
    func chromeShownChanged(to up: Bool) {
        (controller as? MPVPlayerController)?.setSubtitleLift(up)
    }

    func leaveConfirmChanged(to up: Bool) {
        (controller as? MPVPlayerController)?.setSubtitlesHidden(up)
    }

    // MARK: the focus ring

    /// The touch-surface swipe that scrubs is also a focus move for tvOS, which
    /// carried the ring off the scrubber (to the stage or a transport button) mid-scrub. Within a
    /// moment of a swipe, the ring stays where the swipe began.
    func focusMoved(from old: FocusTarget?, to new: FocusTarget?) {
        guard Date().timeIntervalSince(lastScrubAt) < 0.8, old == .chip("scrubber") || old == .surface, new != old else { return }
        let back: FocusTarget? = old
        DispatchQueue.main.async { [self] in if Date().timeIntervalSince(lastScrubAt) < 1.2 { focus = back } }
    }

    /// After a run of swipes the ring was nowhere in the player, and the next
    /// Menu went to tvOS, which closed the app mid-film. A ring that falls out of the player goes
    /// back to the stage.
    func focusLostChanged(_ lost: Bool) {
        guard lost, !finishing else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            if focus == nil, !finishing { focus = .surface }
        }
    }

    /// use-bp-player-chrome.ts: every keypress restarts the idle wait while the chrome is up
    /// ("without it the chrome walks out from under someone who is still pressing buttons").
    /// Moving the ring along the transport or the rail is a press too;
    /// only Select and the stage's arrows restarted it, so the chrome vanished mid-navigation.
    func focusChanged(to target: FocusTarget?) {
        if case .chip(_)? = target, chromeShown { scheduleHide() }
    }

    // MARK: Back

    /// Back / Menu (the remote's exit command): one step out at a time.
    func backPressed() {
        // The close is on its way (it waits on the saves): a second Back asked
        // "Leave the show?" again, or put the chrome away, under a player that was leaving.
        guard !finishing else { return }
        StillWatching.reset()
        if pipActive { controller?.stopPictureInPicture() }                 // back to the full picture first
        else if stillPrompt { stopWatching() }                              // still-watching-prompt: Escape is Stop
        else if resumePending != nil { acknowledgeResume(true) }     // Back takes the default action (bp-resume-prompt)
        else if leaveConfirm { keepWatching() }
        else if panel != nil { closePanel() }
        else if kidsLoading { finish(natural: false) }                   // the kid loader's Cancel (onCancel closes, no leave dialog)
        // bp-connecting pushBpBack(onCancel): Back on a slow start is its
        // "Go back", not a chrome step and then "Leave the show?" over the card.
        else if connectingShown { finish(natural: false) }
        else if noAudioWarning, engine == .native, !failed { noAudioWarning = false; focus = .surface; wake() }  // header-warning "Dismiss"
        else if showUpNextCard, !failed { cancelAutoNext() }            // bp-up-next: Back is "Keep watching"
        else if focus == .chip("skip") || focus == .chip("skip-dismiss") { focus = .surface }
        // Only a transport that is on screen: behind an error card the
        // flag could still be up, so the first Back did nothing the viewer could see.
        // The ring goes back to the stage with it, as the hide timer does: it
        // stayed on a chip that was gone and fell to whatever the focus engine found (the skip
        // pill, the X-Ray rail), so the next Select skipped or opened a card instead of pausing.
        else if chromeShown { hideTask?.cancel(); chrome = false; focus = .surface }
        else { requestClose() }
    }
}
