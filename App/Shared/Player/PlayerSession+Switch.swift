import SwiftUI

/// PlayerSession: switching the stream in place.
extension PlayerSession {
    /// use-anime4k.ts: ask the engine which chain applies, then hand mpv the shader paths.
    func applyAnime4k(srcWidth: Int) async {
        guard let context, let c = controller else { return }
        // A run that is overtaken (the viewer picks a mode or Off in the panel
        // while the first run still downloads the shaders, a reload) must not land its older chain
        // on mpv afterwards, nor on a controller that has been replaced.
        anime4kRun += 1
        let run = anime4kRun
        let current = { [self] in run == anime4kRun && (controller as AnyObject?) === (c as AnyObject) }
        let display = Int(UIScreen.main.nativeBounds.width)
        let meta: AnyJSON = .object(["id": .string(context.meta.id), "genres": .array((context.meta.genres ?? []).map { .string($0) })])
        let p = ProfilesStore.shared.active
        // The TV's own choice, off until the viewer picks one here: the
        // synced desktop setting ran the HQ chain at 4K and anime played like a slideshow.
        let tvChoice: String = UserDefaults.standard.string(forKey: Self.anime4kKey) ?? "off"
        guard let choice: Anime4KChoice = try? await HarborEngine.shared.call("anime4k.choose", [p?.id ?? "default", p?.linked ?? true, meta, srcWidth, display, tvChoice]) else { return }
        guard current() else { return }
        if choice.active {
            // The shaders live in Caches now: a set the system purged is fetched again here.
            if Anime4KStore.shared.paths(for: choice.files) == nil { await Anime4KStore.shared.ensure() }
            guard current() else { return }
            if let paths = Anime4KStore.shared.paths(for: choice.files) {
                anime4k = choice
                anime4kNote = nil
                c.setShaders(paths)
            } else {
                // Not downloaded (offline?): never claim a mode that mpv is not running.
                var off = choice; off.active = false
                anime4k = off
                anime4kNote = Anime4KStore.shared.note ?? "Anime4K shaders are not downloaded yet."
                c.setShaders([])
            }
        } else {
            anime4k = choice
            c.setShaders([])
        }
    }

    func setAnime4k(_ override: String) {
        UserDefaults.standard.set(override, forKey: Self.anime4kKey)
        anime4kAppliedFor = -1
        closePanel()
    }

    /// TransportKids toggleSub: off when one is on, else the first subtitle track.
    func toggleKidSubtitles() {
        guard let c = controller else { return }
        let subs = c.tracks().filter { $0.type == "sub" }
        if subs.contains(where: { $0.selected }) { c.select(track: nil, type: "sub"); c.rememberSubtitle(nil) }
        else if let first = subs.first { c.select(track: first, type: "sub"); c.rememberSubtitle(first) }
        kidSubs = c.tracks().filter { $0.type == "sub" }
    }

    /// The PlayEpisode the switcher searches with.
    func kidsEpisode(_ context: PlaybackContext) -> AnyJSON? {
        guard let s = context.season else { return nil }
        var ep: [String: AnyJSON] = ["season": .number(Double(s)), "episode": .number(Double(context.episode ?? 1))]
        if let v = context.videoId { ep["videoId"] = .string(v) }
        if let i = context.imdbId { ep["imdbId"] = .string(i) }
        return .object(ep)
    }

    /// stream-switcher onPick: the picked stream replaces this one in place at the same position
    /// (use-bridge-load hasExplicitStart), through the engine rule again; a torrent stays owned by
    /// the player while it plays (use-player-media).
    /// `spot`: where the new stream starts (the source switcher's resume spot; the position
    /// otherwise), `hints`: the picked stream's facts for the engine rule, `ref`: its PlayerStreamRef.
    /// `replacesSrc`: the switch replaces the PlayerSrc itself (a home-server
    /// quality, replacePlayerSrc), so src.url moves with it (srcURL).
    func switchStream(to next: URL, headers nextHeaders: [String: String], subtitles nextSubtitles: [SeedSubtitle] = [],
                              from spot: Double? = nil, hints: PlayerStreamHints? = nil, ref: AnyJSON? = nil,
                              replacesSrc: Bool = false) {
        let here: Double = clock.snap.position > 5 ? clock.snap.position : 0
        // use-stream-switcher `startAtSec: resumeAt > 5 ? resumeAt : undefined`.
        let at: Double = spot.map { $0 > 5 ? $0 : 0 } ?? here
        let owned = switched?.url ?? url
        if next != owned {
            TorrentEngine.shared.playerOpened(url: next)
            TorrentEngine.shared.playerClosed(url: owned)
        }
        // A home-server quality keeps the release: switchMediaServerQuality spreads the
        // PlayerSrc (its streamRef stays), so subtitleStreamKey and the release key do not move.
        let nextFilename: String? = replacesSrc ? (switched?.filename ?? streamHints?.filename) : hints?.filename
        switched = SwitchedStream(url: next, headers: nextHeaders, subtitles: nextSubtitles, ref: ref, filename: nextFilename)
        if replacesSrc { replacedSrc = next }
        // use-auto-retry.ts resets its early-end reload per source.
        truncatedReloaded = false
        // The error card's early-end reason goes with the old stream now:
        // it was cleared only by the reload token, which moves once the engine rule has run, so a
        // swap from the error card (Pick another source, the second early end) brought the card
        // back for that moment, and its onAppear pulled the ring onto a chip that then went.
        endedEarly = nil
        status = MPVPlayerController.Status()
        loadingSince = Date()
        controller = nil
        clock.resetForSwap()
        subDelay = 0
        anime4kAppliedFor = -1
        startAt = nil
        let target = playURL
        Task { [self] in
            guard await settleEngine(for: target, hints: hints) else { return }
            // A player that began to close meanwhile (Back, the leave
            // dialog, the curfew) opens no new engine: it would play the new stream, with sound,
            // under the close (finish paused only the old one).
            guard !finishing else { return }
            startAt = at
            reloadToken += 1
        }
        // A new stream is opening: the ring stays on the stage (its chip goes
        // under the Connecting card / the kid loader), not back on Quality or the kid switcher.
        panelOpener = nil
        closePanel()
    }

    /// bp-ten-foot.tsx sources slot `!resuming && !src.isLive`, for a title the stream search can run
    /// for again (PlayerSourcesPanel). Not a playlist item, and not a home-server copy (the session
    /// reports to its server, and the switcher lists no copies): those keep the picker's reopen.
    /// A kid profile has its own switcher (KidsStreamSwitcher).
    var canSwitchInPlace: Bool {
        guard let context, !isLive, tuned == nil, !isKid else { return false }
        return !context.playlistVod && context.homeServer == nil
    }

    /// use-stream-switcher onSwitchStream: the switcher's resolved pick (resolved through the
    /// picker's own path, remembered for next time as savePlayback does) replaces the stream in
    /// place, at use-stream-switcher's resumeAt: where playback is (the last good spot once the
    /// engine has died), or, from a stub, the spot this player opened at (the saved resume).
    /// Upstream plays the new stream (b.play()).
    func switchSource(_ stream: ScoredStream?, _ r: StreamsModel.Resolved) {
        // As the kid switcher: a resolve that lands after the viewer closed the switcher,
        // or after the player began to close, does not swap the video under them.
        guard panel == .sources, !finishing else { return }
        guard let link = r.data, let next = PlayableURL.make(link.url) else { return }
        let stub: Bool = clock.snap.duration > 0 && clock.snap.duration < 180
        let at: Double = stub ? (startAt ?? 0) : switchSpot
        let hints = PlayerStreamHints(notWebReady: link.notWebReady, container: stream?.container,
                                      hdrFormat: stream?.hdrFormat, filename: link.filename)
        switchStream(to: next, headers: link.headers ?? [:], subtitles: link.subtitles ?? [],
                     from: at, hints: hints, ref: sourceRef(r.streamRef, playing: next))
    }

    /// The picked stream's PlayerStreamRef, with the torrent and file the TV's engine actually
    /// serves when it is a local P2P stream (use-stream-switcher `fileIdx: r.data.fileIdx ?? …`).
    func sourceRef(_ ref: AnyJSON?, playing next: URL) -> AnyJSON? {
        var o: [String: AnyJSON] = [:]
        if case .object(let base)? = ref { o = base }
        if let t = TorrentEngine.streamRef(next) {
            o["infoHash"] = .string(t.infoHash)
            o["fileIdx"] = .number(Double(t.fileIdx))
        }
        return o.isEmpty ? nil : AnyJSON.object(o)
    }
}
