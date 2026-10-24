import SwiftUI

/// PlayerSession: skip pill and up next (skip-pill-container.tsx, bp-skip-pill.tsx, bp-up-next.tsx, use-auto-next-episode.ts).
extension PlayerSession {
    /// skip-intro/index.ts activeSegment: the segment the playhead is inside (realActiveSkip).
    var realActiveSkip: SkipSegment? {
        segments.first { clock.snap.position >= $0.startSec && clock.snap.position < $0.endSec - 0.75 }
    }

    /// skip-pill-container syntheticOutro: inside the up-next lead, a title with no real outro gets
    /// one that runs to the end.
    var syntheticOutro: SkipSegment? {
        guard realActiveSkip == nil, hasNextEpisodeNow, clock.snap.duration > 0, leadSec > 0 else { return nil }
        let remaining = clock.snap.duration - clock.snap.position
        guard remaining <= leadSec, remaining >= 0.5, !segments.contains(where: { isOutro($0) }) else { return nil }
        return SkipSegment(kind: "outro", startSec: max(0, clock.snap.duration - leadSec), endSec: clock.snap.duration, source: "chapters")
    }

    /// skip-pill-container buttonKey: the real segment the pill is showing, when showSkipButton is on.
    var skipButtonKey: String? {
        guard let seg = realActiveSkip, SettingsBridge.shared.slice.showSkipButton ?? true else { return nil }
        return "\(seg.kind):\(Int(seg.startSec.rounded())):\(Int(seg.endSec.rounded()))"
    }

    /// skip-pill-container displaySkip: the real segment, unless showSkipButton is off or its pill
    /// was hidden (skipButtonHideSec ran out, or the viewer pressed its ✕).
    var displaySkip: SkipSegment? {
        guard let key = skipButtonKey, key != skipAutoHiddenKey, !skipDismissedKeys.contains(key) else { return nil }
        return realActiveSkip
    }

    /// skip-pill-container activeSkip: what the pill (or the up-next card) is about.
    var activeSkip: SkipSegment? { displaySkip ?? syntheticOutro }

    /// skip-pill-container.tsx effects on the 1 s tick: auto-skip (autoSkipIntro / Recap / Outro / Ad,
    /// once per segment), then the pill's skipButtonHideSec timer, keyed to the segment it shows.
    func skipTick() {
        let s = SettingsBridge.shared.slice
        let playingIn = status.state == "playing" && resumePending == nil ? realActiveSkip : nil
        if let seg = playingIn, autoSkippedId != seg.id, autoSkipSeen == seg.id {
            let want = (seg.kind == "intro" && (s.autoSkipIntro ?? false))
                || (seg.kind == "recap" && (s.autoSkipRecap ?? false))
                || (isOutro(seg) && (s.autoSkipOutro ?? false))
                || (seg.kind == "ad" && (s.autoSkipAd ?? false))
            if want {
                autoSkippedId = seg.id
                skipTo(seg.endSec, auto: true)
            }
        }
        autoSkipSeen = playingIn?.id
        let key = skipButtonKey
        if key != prevSkipKey {
            // prevSkipKeyRef: the segment we left gets its pill back if the viewer returns to it.
            if let previous = prevSkipKey {
                if skipAutoHiddenKey == previous { skipAutoHiddenKey = nil }
                skipDismissedKeys.remove(previous)
            }
            prevSkipKey = key
            skipHideTask?.cancel()
            let hideSec = s.skipButtonHideSec ?? 0
            if let key, hideSec > 0 {
                skipHideTask = Task { [self] in
                    try? await Task.sleep(for: .seconds(hideSec))
                    if !Task.isCancelled { skipAutoHiddenKey = key }
                }
            }
        }
        // A pill that went away takes the ring back to the stage.
        if activeSkip == nil, focus == .chip("skip") || focus == .chip("skip-dismiss") { focus = .surface }
        // So does the up-next card (a seek back out of the lead, its outro's pill hidden).
        if !showUpNextCard, focus == .chip("upnext-play") || focus == .chip("upnext-keep") { focus = .surface }
    }

    /// player-overlay-layers onSkip = seekTo. `auto`: an auto-skip, not the viewer's move, so a
    /// resume spot not reached yet still holds the saves.
    func skipTo(_ sec: Double, auto: Bool = false) {
        if !auto { resumeGuard.viewerMoved() }
        let target = clock.snap.duration > 0 ? min(sec, clock.snap.duration) : sec
        controller?.seek(to: target)
        clock.seeked(to: target)
    }

    /// AniSkip / SkipDB / TheIntroDB / IntroDB App / chapters through the engine (lib/skip-intro).
    func loadSegments(chapters: [PlayerChapter]) async {
        guard let context, !context.playlistVod, clock.snap.duration > 0 else { return }
        segmentsRun += 1
        let run = segmentsRun
        let p = ProfilesStore.shared.active
        let ep: AnyJSON = context.season.map { s in
            .object(["season": .number(Double(s)), "episode": .number(Double(context.episode ?? 1)),
                     "imdbId": context.imdbId.map { .string($0) } ?? .null,
                     "imdbSeason": .number(Double(s)), "imdbEpisode": .number(Double(context.episode ?? 1))])
        } ?? .null
        let segs: [SkipSegment] = (try? await HarborEngine.shared.call("skip.segments", [p?.id ?? "default", p?.linked ?? true, context.meta, ep, clock.snap.duration, chapters] as [any Encodable])) ?? []
        guard run == segmentsRun else { return }
        // skip-pill-container: new segments start over (auto-skip memory, hidden pills).
        if segs.map(\.id) != segments.map(\.id) {
            autoSkippedId = nil
            skipAutoHiddenKey = nil
            skipDismissedKeys = []
            prevSkipKey = nil
            skipHideTask?.cancel()
        }
        segments = segs
    }

    /// bp-skip-pill isOutroNext: an outro with an episode after it reads "Next Episode" and plays it.
    func isOutroNext(_ seg: SkipSegment) -> Bool { isOutro(seg) && hasNextEp && leadSec > 0 }

    /// player.tsx hasNextEpDisplay = !autoNextCancelled && airedNext.
    var hasNextEp: Bool { upNext != nil && !autoNextCancelled && !isLive }

    var remainingSec: Double { max(0, clock.snap.duration - clock.snap.position) }

    /// skip-pill-container.tsx nextEpisodeLead: 0 = off, > 0 = fixed, -1 = 4 % of the runtime within 15–45 s.
    var leadSec: Double {
        let setting = prefs.nextEpisodeLeadSec
        if setting == 0 { return 0 }
        if setting > 0 { return setting }
        return min(45, max(15, (clock.snap.duration * 0.04).rounded()))
    }

    func isOutro(_ seg: SkipSegment) -> Bool { seg.kind == "outro" || seg.kind == "credits" }

    /// bp-skip-pill asUpNext: the pill turns into the up-next card inside the lead, over a real
    /// outro or the synthetic one. A real outro whose pill is hidden (or showSkipButton off) shows neither.
    var showUpNextCard: Bool {
        guard let seg = activeSkip, isOutroNext(seg) else { return false }
        return remainingSec > 0 && remainingSec <= leadSec
    }

    /// use-episode-navigation goToEpisode: the caller opens the next episode's picker with instant play.
    func playNext() {
        StillWatching.reset()
        finish(natural: false, advance: true)
    }

    func cancelAutoNext() {
        autoNextCancelled = true
        focus = .surface
        wake()
    }

    /// use-auto-next-episode.ts: at a natural end the next episode follows unless the viewer chose
    /// "Keep watching", autoPlayNextEpisode is off, or the file is a stub (under 150 s).
    func endedNaturally() {
        guard !stillPrompt else { return }
        // A live channel's end is liveEnded's (use-auto-end-exit.ts reloads it).
        guard !isLive else { return }
        // use-sleep-timer.ts: "End of episode" (or the last of "End of next episode") stops here.
        let sleepStops = SleepTimer.shared.episodeEnded()
        // use-started-near-end.ts: a stream started at 80% or later stays on
        // its end: no next episode, no Still watching, no close (the sleep count above still runs,
        // as use-sleep-timer does not read the guard).
        if startedNearEndNow { return }
        let advance = !sleepStops && upNext != nil && prefs.autoPlayNextEpisode && !autoNextCancelled && clock.snap.duration >= 150
        // Ended in Picture in Picture: what follows (the next episode, Still watching) has to be on
        // screen, so the browse layer goes down and the picture comes home first; a title that just
        // ends leaves the viewer browsing (the player closes under the layer).
        if pipActive || controller?.isPictureInPictureActive == true {
            Platform.hooks.pipBrowseRelease(nowPlayingId, keepBrowsing: !advance)
            if advance { controller?.stopPictureInPicture() }
        }
        // player.tsx autoAdvance → use-still-watching gateAdvance: enough episodes in a row with no
        // press asks "Still watching?" instead of moving on.
        let s = SettingsBridge.shared.slice
        if advance, StillWatching.gate(enabled: s.stillWatching ?? false, threshold: Int((s.stillWatchingAfter ?? 3).rounded())) {
            stillPrompt = true
            hideTask?.cancel()
            chrome = false
            if panel != nil { panel = nil }
            focusLater(.chip("still-continue"))
            return
        }
        finish(natural: true, advance: advance)
    }

    /// use-still-watching continueWatching: the count starts over and the next episode plays.
    func continueWatching() {
        StillWatching.reset()
        stillPrompt = false
        finish(natural: true, advance: true)
    }

    /// use-still-watching stopWatching: the count starts over and the player closes.
    func stopWatching() {
        StillWatching.reset()
        stillPrompt = false
        finish(natural: true, advance: false)
    }
}
