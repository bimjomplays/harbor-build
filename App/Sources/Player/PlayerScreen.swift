import SwiftUI

/// Full-screen playback with Big Picture's player chrome:
/// chrome wakes on any press and hides after 4.6 s; Select = play/pause; Left/Right seek;
/// Menu closes the chrome first, then the player.
///
/// The tvOS face of PlayerSession (App/Shared/Player): the session holds the playback state and
/// logic, shared with the iPhone; this view draws it with the remote's focus ring and gestures.
struct PlayerScreen: View {
    @StateObject private var session: PlayerSession
    @FocusState private var focus: FocusTarget?
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    typealias FocusTarget = PlayerSession.FocusTarget
    typealias Panel = PlayerSession.Panel
    typealias SkipSegment = PlayerSession.SkipSegment
    typealias Anime4KChoice = PlayerSession.Anime4KChoice
    typealias PlayerPrefs = PlayerSession.PlayerPrefs
    static let anime4kKey = PlayerSession.anime4kKey

    init(title: String,
         subtitle: String?,
         url: URL,
         headers: [String: String] = [:],
         context: PlaybackContext? = nil,
         upNext: String? = nil,
         isLive: Bool = false,
         streamHints: PlayerStreamHints? = nil,
         onChooseAnother: (() -> Void)? = nil,
         onSwitchSource: ((Double) -> Void)? = nil,
         onPreviousEpisode: (() -> Void)? = nil,
         liveGuide: LiveModel? = nil,
         liveChannel: LiveModel.Channel? = nil,
         onAddToMultiview: ((LiveModel.Channel) -> Void)? = nil,
         pick: PlayerPickInfo? = nil,
         onPickAgain: ((_ auto: Bool) -> Void)? = nil,
         browseDuringPiP: Bool = true,
         streamSubtitles: [SeedSubtitle] = [],
         pickEpisode: AnyJSON? = nil,
         subtitlePreselect: SubtitlePreselect? = nil,
         onClose: @escaping (_ endedNaturally: Bool) -> Void) {
        _session = StateObject(wrappedValue: PlayerSession(
            title: title,
            subtitle: subtitle,
            url: url,
            headers: headers,
            context: context,
            upNext: upNext,
            isLive: isLive,
            streamHints: streamHints,
            onChooseAnother: onChooseAnother,
            onSwitchSource: onSwitchSource,
            onPreviousEpisode: onPreviousEpisode,
            liveGuide: liveGuide,
            liveChannel: liveChannel,
            onAddToMultiview: onAddToMultiview,
            pick: pick,
            onPickAgain: onPickAgain,
            browseDuringPiP: browseDuringPiP,
            streamSubtitles: streamSubtitles,
            pickEpisode: pickEpisode,
            subtitlePreselect: subtitlePreselect,
            onClose: onClose))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let startAt = session.startAt, session.engine == .native {
                // A report from a native player that is being replaced by mpv is dropped.
                NativePlayerView(url: session.playURL, headers: session.playHeaders, startAt: startAt, isLive: session.isLive,
                                 preferredAudio: SettingsBridge.shared.slice.preferredAudioLangs ?? ["English", "Japanese"],
                                 preferredSubs: SettingsBridge.shared.slice.preferredSubLangs,
                                 trackMemory: session.trackMemory,
                                 seedSubtitles: session.playSeeds,
                                 onStatus: { s in if session.engine == .native { session.applyStatus(s) } },
                                 onEnded: { if session.engine == .native { session.endedNaturally() } },
                                 onUnsupported: { session.nativeUnsupported($0) },
                                 // Delivered a main-queue turn after creation: the session drops a stale engine's report.
                                 onReady: { [token = session.reloadToken] c in session.nativeReady(c, token: token) },
                                 onPictureInPicture: { on in if session.engine == .native { session.pipChanged(on) } },
                                 onPictureInPictureRestore: { if session.engine == .native { Platform.hooks.pipBrowseRestore(session.nowPlayingId) } },
                                 onPictureInPictureClosed: { if session.engine == .native { session.pipClosedByViewer() } })
                    .ignoresSafeArea()
                    .id(session.reloadToken)
            } else if let startAt = session.startAt {
                MPVPlayerView(url: session.playURL, headers: session.playHeaders, startAt: startAt, isLive: session.isLive,
                              preferredAudio: SettingsBridge.shared.slice.preferredAudioLangs ?? ["English", "Japanese"],
                              preferredSubs: SettingsBridge.shared.slice.preferredSubLangs,
                              trackMemory: session.trackMemory,
                              seedSubtitles: session.playSeeds,
                              onStatus: { session.applyStatus($0) }, onEnded: { session.endedNaturally() },
                              // Delivered a main-queue turn after creation: the session drops a stale engine's report.
                              onReady: { [token = session.reloadToken] c in session.mpvReady(c, token: token) })
                    .ignoresSafeArea()
                    .id(session.reloadToken)
            } else {
                // Plain black, not the theme's void: the hosting UIViews are hard-coded black too,
                // and a light theme painted this reload/swap fallback as a bright slab over the
                // video slot .
                Color.black.ignoresSafeArea()
            }
            // stage-overlays.tsx ContentAdvisoryToast (contentAdvisoryToast, off by default).
            if !session.isLive, let context = session.context {
                // Keyed by src.url (a source swapped in place keeps it, as
                // player.tsx passes src.url to useContentAdvisory).
                // (open-items sweep 4) player-overlay-layers.tsx contentAdvisoryPosition: "top-start"
                // unless topLeftOccupied (upstream's stats overlay, or a room's avatar/chat corner),
                // which moves it to "top-end" rather than hiding it. Big Picture has no stats overlay
                //, so the TV's own top-left occupant is the X-Ray
                // rail (drawn while paused, in the same topLeading corner); the toast now moves to the
                // trailing corner while X-Ray is up instead of disappearing.
                ContentAdvisoryLayer(imdbId: context.imdbId, metaId: context.meta.id, playKey: session.srcURL,
                                     playing: session.status.state == "playing", hidden: session.pipActive,
                                     cornerTaken: session.xrayMeta != nil, clock: session.clock)
            }
            // The invisible surface holds focus while the chrome is down so remote presses reach us.
            Button { session.togglePause() } label: { Color.clear.contentShape(Rectangle()) }
                // THE white screen: tvOS's `.plain` button
                // style draws its own focus highlight, and with a screen-sized clear label that is a
                // screen-sized milky platter over the video from the first frame (seen live over the
                // developer tunnel). `.focusEffectDisabled()` alone did not remove it : the
                // highlight belongs to the style, not to the focus effect. A bare custom style draws
                // the label and nothing else.
                .buttonStyle(BPBareButtonStyle())
                .focusEffectDisabled()
                .disabled(session.panel != nil || session.resumePending != nil || session.leaveConfirm || session.pipActive || session.kidsLoading || session.stillPrompt || session.xrayOpen)
                .focused($focus, equals: .surface)
                .onMoveCommand { dir in
                    switch dir {
                    case .left: if session.isLive { session.controller?.seek(-10); session.wake() } else { session.nudgeSeek(ahead: false) }
                    case .right: if session.isLive { session.controller?.seek(10); session.wake() } else { session.nudgeSeek(ahead: true) }
                    case .up where session.showUpNextCard: StillWatching.reset(); focus = .chip("upnext-keep")
                    case .up where session.activeSkip != nil: StillWatching.reset(); focus = .chip("skip")
                    case .up where session.xrayMeta != nil: focus = PlayerXRayOverlay.entry
                    default:
                        // The surface fills the screen, so the focus engine finds
                        // nothing above or below it: Up and Down only woke the chrome and the ring could
                        // never reach a control. They now wake it and put the ring on Play / Pause.
                        let shownBefore: Bool = session.chromeShown
                        session.wake()
                        if !session.isKid {
                            DispatchQueue.main.asyncAfter(deadline: .now() + (shownBefore ? 0.02 : 0.15)) {
                                if focus == .surface, session.chromeShown { focus = .chip("playpause") }
                            }
                        }
                    }
                }
                // bp-player-scrub.tsx role="slider" aria-label t("Seek") aria-valuetext={fmtTime(position)}:
                // the surface is the scrubber the remote drives, so VoiceOver adjusts it the same way.
                // A live channel has no timeline: bp-player-shell's t("Player controls").
                .accessibilityLabel(Text(T(session.isLive ? "Player controls" : "Seek")))
                // Its value reads the clock inside PlayerSeekValue (PlayerClock.swift).
                .modifier(PlayerSeekValue(clock: session.clock, isLive: session.isLive, pending: session.pendingSeek))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: if session.isLive { session.controller?.seek(10); session.wake() } else { session.nudgeSeek(ahead: true) }
                    case .decrement: if session.isLive { session.controller?.seek(-10); session.wake() } else { session.nudgeSeek(ahead: false) }
                    @unknown default: break
                    }
                }
            // The Subtitles and Audio dialogs cover the stage, so the transport steps aside for them.
            if session.chromeShown {
                // transport.tsx: a kid profile gets TransportKids instead of the full transport
                // (`kid && !pipMode`; TransportKids has no PiP control, so a kid never leaves for PiP).
                // The Anime4K sidebar keeps the transport on screen beside it, but out of
                // the ring's reach while it is open (Left from the sidebar reached the rail).
                // (open-items sweep 4) .disabled() dims Buttons but a raw `.focusable()` control (the
                // scrub surface's kin inside the transport) ignores the ambient isEnabled and stayed a
                // candidate, so the ring could still reach the chrome the Subtitles / Sources panels
                // never render in the first place (chromeShown is false for them). allowsHitTesting
                // pulls the whole group out of the focus engine's hit-test tree the same way it does
                // everywhere else this app hides a live-but-unfocusable layer (ContentAdvisoryToast,
                // RoomView's spotlight copy), without hiding it from view.
                Group { if session.isKid { kidsChrome } else { chromeView } }
                    .disabled(session.panel == .anime4k)
                    .allowsHitTesting(session.panel != .anime4k)
                    .transition(.opacity)
            }
            if let resumePending = session.resumePending {
                Group { if session.isKid { kidsResumePrompt } else { resumePrompt(resumePending) } }.transition(.opacity)
            }
            if session.leaveConfirm { leaveConfirmView.transition(.opacity) }
            // Not under an open dialog, like the live error card and the no-audio
            // card: each card's onAppear takes the ring, which went to a chip hidden behind the
            // Subtitles / Audio dialog when the stream failed (or kept connecting) while it was open.
            // The card comes up once the dialog closes.
            // Not under the resume fork or "Leave the show?" either: both
            // sit on the same bottom band, and the card's onAppear pulled the ring out of the fork.
            if session.failed, !session.isLive, !session.pipActive, session.panel == nil, session.resumePending == nil, !session.leaveConfirm { sourceErrorCard.transition(.opacity) }
            // live-channel-error.tsx: every live channel (the Home row, Search, Sports links too, where
            // only the bare transport showed); "Browse channels" only with a guide to browse.
            // Only once use-auto-retry's live reconnects are used up (liveGaveUp).
            if session.status.state == "error", session.isLive, session.liveGaveUp, session.panel == nil, !session.pipActive { liveErrorCard.transition(.opacity) }
            if session.connectingShown { connectingCard.transition(.opacity) }
            // cinematic-player-loader.tsx: a kid gets the sea loader over everything until the first frame.
            if session.kidsLoading { kidsLoader.transition(.opacity) }
            if session.noAudioWarning, session.engine == .native, session.panel == nil, !session.leaveConfirm, !session.pipActive, session.resumePending == nil, !session.failed {
                noAudioCard.transition(.opacity)
            }
            // The up-next card and the skip pill follow the playhead: they are drawn in
            // a leaf that observes the clock (cueLayer), not in this body.
            PlayerClockReader(session.clock) { _ in cueLayer }
            // xray-overlay.tsx: X-Ray while paused (PlayerXRay.swift), when settings.xrayEnabled.
            if let meta = session.xrayMeta { PlayerXRayOverlay(meta: meta, open: $session.xrayOpen, focus: $focus).transition(.opacity) }
            // player.tsx StillWatchingPrompt: over everything but PiP.
            if session.stillPrompt, !session.pipActive {
                StillWatchingPrompt(show: session.context?.meta.name ?? session.title, nextLabel: stillWatchingNextLabel, focus: $focus,
                                    onContinue: { session.continueWatching() }, onExit: { session.stopWatching() })
                    .transition(.opacity)
            }
            if let panel = session.panel {
                panelView(panel).transition(panel == .anime4k ? AnyTransition.move(edge: .trailing).combined(with: .opacity) : AnyTransition.opacity)
            }
            if let a = session.anime4k, a.active, a.indicator, !session.chrome {
                // anime4k-indicator.tsx: a quiet corner pill while a chain is live.
                Text("Anime4K · Mode \(a.mode ?? "")").font(BP.sans(11, .bold)).foregroundStyle(BP.ink)
                    .padding(.horizontal, BP.px(8)).padding(.vertical, BP.px(4))
                    .background(Capsule().fill(BP.void_.opacity(0.7)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(BP.gutter)
            }
            if session.pipActive { pipPlacard.transition(.opacity) }
            // Settings → Playback "Player diagnostics overlay": drawn last so it
            // sits over everything else. Refreshed by `status`, which applyStatus already
            // updates every second off the controller's own poll timer — no new timer here.
            if SettingsBridge.shared.slice.playerDiagnostics ?? false {
                PlayerDiagnosticsOverlay(engine: session.engine, url: session.playURL, status: session.status)
            }
        }
        // After a run of swipes the ring was nowhere in the player, and the next
        // Menu went to tvOS, which closed the app mid-film. A ring that falls out of the player goes
        // back to the stage.
        // The touch-surface swipe that scrubs is also a focus move for tvOS, which
        // carried the ring off the scrubber (to the stage or a transport button) mid-scrub. Within a
        // moment of a swipe, the ring stays where the swipe began.
        .onChange(of: focus) { old, new in session.focusMoved(from: old, to: new) }
        .onChange(of: focus == nil) { _, lost in session.focusLostChanged(lost) }
        // Siri Remote touch-surface scrubbing (RemoteScrub.swift).
        .background(RemoteScrubCatcher(enabled: session.scrubEnabled, onBegan: { session.lastScrubAt = Date() }, onChanged: { f in session.scrubSwipe(f) }, onEnded: { session.scrubSwipeEnded() }))
        // Subtitles rise over the chrome while it is up (mpv only).
        .onChange(of: session.chromeShown) { _, up in session.chromeShownChanged(to: up) }
        .onChange(of: session.leaveConfirm) { _, up in session.leaveConfirmChanged(to: up) }
        // media-session.ts mediaKeyGate: a press that also reaches us as a remote command toggles once.
        .onPlayPauseCommand { if VideoNowPlaying.shared.mediaKeyGate() { session.playPausePressed() } }
        .onExitCommand { session.backPressed() }
        .onAppear {
            // The focus ring lives in this view (@FocusState); the session reads and moves it through the binding.
            let ring = $focus
            session.bindFocus(read: { ring.wrappedValue }, write: { ring.wrappedValue = $0 })
            session.appeared()
        }
        .onDisappear { session.disappeared() }
        .onReceive(CurfewState.shared.$locked) { session.curfewChanged($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in session.didEnterBackground() }
        .task { await session.start() }
        .onReceive(tick) { _ in session.tick() }
        // views/player.tsx: an auto pick that fails before it ever played goes on to the next source.
        .onChange(of: session.status.state) { _, state in session.statusChanged(to: state) }
        // use-bp-player-chrome.ts: every keypress restarts the idle wait while the chrome is up
        // ("without it the chrome walks out from under someone who is still pressing buttons").
        // Moving the ring along the transport or the rail is a press too;
        // only Select and the stage's arrows restarted it, so the chrome vanished mid-navigation.
        .onChange(of: focus) { _, target in session.focusChanged(to: target) }
        // use-bp-player-chrome restarts the idle wait when `playing` changes: the
        // wait that ran out while paused never came back, so a video started again without a press
        // here (the iPhone remote, PiP's own button) kept the chrome up.
        // isPaused follows the clock's pause flag, written only when it changes (takeSnap).
        .onChange(of: session.isPaused) { _, paused in session.pausedChanged(to: paused) }
        // A retry or the switch to mpv starts the stall wait over.
        .onChange(of: session.reloadToken) { _, _ in session.reloadTokenChanged() }
        .animation(.easeOut(duration: 0.32), value: session.chrome)
        .animation(.easeOut(duration: 0.32), value: session.panel == nil)
    }

    /// The up-next card (inside the lead) or the skip pill, drawn by the clock's leaf in the body
    /// (its gate stays in here, so each keeps its own transition when a panel or prompt opens).
    @ViewBuilder private var cueLayer: some View {
        if session.panel == nil, !session.leaveConfirm, session.resumePending == nil, !session.pipActive, !session.stillPrompt, !session.xrayOpen, !session.failed {
            if session.showUpNextCard, let upNext = session.upNext {
                upNextCard(upNext).transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let seg = session.activeSkip {
                skipPill(seg).transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private func skipPill(_ seg: SkipSegment) -> some View {
        let outroNext = session.isOutroNext(seg)
        // bp-skip-pill onDismiss: a real segment's pill carries a ✕ ("Hide this Skip button").
        let dismissKey = session.displaySkip != nil && !outroNext ? session.skipButtonKey : nil
        return VStack {
            Spacer()
            HStack(spacing: BP.px(10)) {
                Spacer()
                Button {
                    if outroNext { session.playNext(); return }
                    session.skipTo(seg.endSec)
                    // The pill leaves with the segment: the ring goes to the stage
                    // (Select means pause again) rather than wherever the focus engine drops it,
                    // a transport chip under the woken chrome.
                    focus = .surface
                    session.wake()
                } label: {
                    HStack(spacing: BP.px(8)) {
                        Image(systemName: outroNext ? "chevron.forward.2" : "forward.fill")
                        Text(T(outroNext ? "Next Episode" : seg.label))
                    }
                }
                // Was `.plain` with a drawn plate: tvOS laid its own milky focus
                // highlight over it. Apple-style frosted pill, white when focused.
                .buttonStyle(PlayerPillStyle())
                .focused($focus, equals: .chip("skip"))
                if let dismissKey {
                    Button {
                        session.skipDismissedKeys.insert(dismissKey)
                        focus = .surface
                        session.wake()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: BP.px(14), weight: .bold))
                    }
                    .buttonStyle(PlayerPillStyle())
                    .focused($focus, equals: .chip("skip-dismiss"))
                    .accessibilityLabel(Text(T("Hide this Skip button")))
                }
            }
            .focusSection()
            .padding(.bottom, session.chrome ? BP.px(300) : BP.px(40)).padding(.trailing, BP.gutter)
        }
        .ignoresSafeArea()
        // bp-skip-pill: a soft target. It never takes the ring on arrival (Select must keep meaning
        // pause); Up from the surface or the transport reaches it, Menu hands the ring back.
    }

    /// still-watching-prompt "S{season} E{episode}" of the episode that would play next.
    private var stillWatchingNextLabel: String? {
        guard session.context?.season != nil, let upNext = session.upNext else { return nil }
        return upNext.components(separatedBy: " · ").first
    }

    /// bp-up-next.tsx BpUpNext: the next episode, a countdown ring, "Play now" and "Keep watching".
    /// It never takes the ring on arrival (Select keeps meaning pause); Up or the chrome reaches it.
    private func upNextCard(_ text: String) -> some View {
        let seconds = Int(session.remainingSec.rounded(.up))
        let progress = session.leadSec > 0 ? min(1, max(0, 1 - Double(seconds) / session.leadSec)) : 0
        let parts = text.components(separatedBy: " · ")
        let epLabel = parts.first ?? text
        let name = parts.dropFirst().joined(separator: " · ")
        let heading = name.isEmpty ? epLabel : name
        return VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(alignment: .top, spacing: BP.px(16)) {
                    ZStack {
                        RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel)
                        Text(epLabel).font(BP.sans(11, .bold)).textCase(.uppercase).tracking(1.8).foregroundStyle(BP.inkSubtle)
                    }
                    .frame(width: BP.px(200), height: BP.px(112))
                    VStack(alignment: .leading, spacing: BP.px(6)) {
                        HStack(alignment: .top) {
                            Text("Up Next").font(BP.sans(11.5, .bold)).textCase(.uppercase).tracking(1.6).foregroundStyle(BP.inkSubtle)
                            Spacer()
                            countdownRing(seconds: seconds, progress: progress)
                        }
                        Text(heading).font(BP.display(20)).foregroundStyle(BP.ink).lineLimit(2)
                        if heading != epLabel {
                            Text(epLabel).font(BP.sans(12, .medium)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                        }
                        HStack(spacing: BP.px(10)) {
                            Button { session.playNext() } label: { Label("Play now", systemImage: "play.fill") }
                                .buttonStyle(BPActionStyle())
                                .focused($focus, equals: .chip("upnext-play"))
                            Button { session.cancelAutoNext() } label: { Label("Keep watching", systemImage: "xmark") }
                                .buttonStyle(BPActionStyle())
                                .focused($focus, equals: .chip("upnext-keep"))
                        }
                        .padding(.top, BP.px(6))
                    }
                }
                .padding(BP.px(18))
                .frame(width: BP.px(600), alignment: .leading)
                // Frosted over the picture, as Apple's own up-next card is.
                .background(
                    RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(Color.black.opacity(0.35)))
                )
                .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.9), radius: 60, y: 40)
                .focusSection()
            }
            .padding(.bottom, session.chrome ? BP.px(300) : BP.px(40)).padding(.trailing, BP.gutter)
        }
        .ignoresSafeArea()
    }

    /// bp-up-next.tsx CountdownRing: whole seconds left, the ring filling toward the jump.
    private func countdownRing(seconds: Int, progress: Double) -> some View {
        ZStack {
            Circle().stroke(BP.edge2, lineWidth: 3.5).accessibilityHidden(true)
            Circle().trim(from: 0, to: progress)
                .stroke(BP.accent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .accessibilityHidden(true)
            Text("\(seconds)").font(BP.sans(15, .bold)).foregroundStyle(BP.ink).monospacedDigit()
        }
        .frame(width: BP.px(46), height: BP.px(46))
        .animation(.linear(duration: 0.2), value: progress)
    }

    private var chromeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            chromeBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        // Apple TV's player: a soft black wash rising from the bottom edge, no
        // hint bar (upstream's BpHintBar suits a gamepad; the Siri Remote's own buttons need none).
        .background(LinearGradient(stops: [.init(color: .clear, location: 0.36), .init(color: Color.black.opacity(0.62), location: 0.66),
                                           .init(color: Color.black.opacity(0.92), location: 1)], startPoint: .top, endPoint: .bottom))
        .ignoresSafeArea()
    }

    /// The episode line over the title at the bottom left,
    /// the panel controls as round glass buttons on the same line at the right, the full-width
    /// scrubber, then the times with the transport centred between them. Same buttons, the same
    /// focus ids and the same two focus sections (rail above, transport below) as before.
    private var chromeBody: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            HStack(alignment: .bottom, spacing: BP.px(20)) {
                VStack(alignment: .leading, spacing: BP.px(5)) {
                    // (open-items sweep) A tuned channel's line watches the guide (TunedChannelSubtitle).
                    if let live = session.liveGuide, let t = session.tuned { TunedChannelSubtitle(live: live, channel: t) }
                    else if let s = session.shownSubtitle {
                        Text(s).font(BP.sans(14, .semibold)).foregroundStyle(Color.white.opacity(0.72)).lineLimit(1)
                    }
                    Text(session.shownTitle).font(BP.display(28)).foregroundStyle(Color.white).lineLimit(1)
                        .shadow(color: Color.black.opacity(0.45), radius: 10, y: 2)
                }
                Spacer(minLength: BP.px(20))
                railRow.fixedSize()
            }
            if !session.isLive {
                // Both observe the clock themselves.
                scrubberControl
            }
            ZStack {
                if session.isLive {
                    HStack {
                        Text("LIVE").font(BP.sans(13, .bold)).foregroundStyle(BP.live)
                        Spacer()
                    }
                } else {
                    PlayerClockReader(session.clock) { c in scrubReadout(c) }
                }
                transportRow
            }
        }
        .padding(.horizontal, BP.gutter)
        .padding(.top, BP.gutter)
        // Inside the TV's safe area, with room under the transport for its focus caption.
        .padding(.bottom, BP.px(66))
    }

    /// bp-player-controls.tsx: the transport. A series gets Previous / Next episode, each dimmed
    /// when there is none; VOD gets Back / Forward by the seek step; Play / Pause is the big one.
    private var transportRow: some View {
        HStack(spacing: BP.px(16)) {
            // bp-player-controls `series = hasPrevEpisode || hasNextEpisode`.
            if session.hasPrevEpisodeNow || session.hasNextEpisodeNow {
                orb("prev", "backward.end.fill", title: T("Previous episode"), below: true) { session.previousEpisode() }
                    .disabled(!session.hasPrevEpisodeNow)
            }
            if !session.isLive { orb("rewind", Self.stepGlyph("gobackward", session.prefs.seekBackStepSec), title: T("Back %llds", Int(session.prefs.seekBackStepSec)), below: true) { session.seekBy(-session.prefs.seekBackStepSec) } }
            orb("playpause", session.isPaused ? "play.fill" : "pause.fill", title: T(session.isPaused ? "Play" : "Pause"), large: true, below: true) { session.togglePause() }
            if !session.isLive { orb("forward", Self.stepGlyph("goforward", session.prefs.seekForwardStepSec), title: T("Forward %llds", Int(session.prefs.seekForwardStepSec)), below: true) { session.seekBy(session.prefs.seekForwardStepSec) } }
            if session.hasPrevEpisodeNow || session.hasNextEpisodeNow {
                orb("next", "forward.end.fill", title: T("Next episode"), below: true) { session.playNext() }
                    .disabled(!session.hasNextEpisodeNow)
            }
        }
        .focusSection()
        // The rail sits at the far right, outside Up's reach from the centred
        // transport: the press found nothing. Up goes to the rail's Subtitles, Down from the rail back.
        .onMoveCommand { dir in
            if dir == .up { focus = .chip(session.isLive ? "Subtitles" : "scrubber") }
        }
    }

    /// bp-player-rail.tsx: Back, one control per panel, then the mute toggle. Round buttons a few
    /// pt wide each, so even a live channel's longest rail fits beside the title without a scroll.
    private var railRow: some View {
        HStack(spacing: BP.px(12)) {
            orb("Back", "chevron.backward", title: T("Back")) { session.requestClose() }
            orb("Subtitles", "captions.bubble", title: T("Subtitles")) { session.open(.subtitles) }
            orb("Audio", "waveform", title: T("Audio")) { session.open(.audio) }
            // speed-menu.tsx "Speed & sleep": its face shows the sleep countdown, else a changed rate.
            // The control observes the sleep timer itself (PlayerSleepReader).
            PlayerSleepReader { t in speedChip(t) }
            // control-renderer.tsx "pip": only when the engine can (capabilities().pictureInPicture);
            // mpv cannot, so the control is not there on that engine.
            if session.controller?.supportsPictureInPicture == true {
                orb("pip", "pip.enter", title: T("Picture in Picture")) { session.controller?.startPictureInPicture() }
            }
            if !session.isLive, session.engine == .mpv { orb("anime4k", "sparkles", title: T(anime4kChipLabel), active: session.anime4k?.active == true) { session.open(.anime4k) } }
            // bp-ten-foot.tsx sources slot: the switcher opens over the film and swaps the
            // stream in place. Where it can't (a home-server copy), the picker reopens at this spot.
            if session.canSwitchInPlace { orb("Sources", "list.bullet", title: T("Sources")) { session.open(.sources) } }
            else if session.onSwitchSource != nil { orb("Sources", "list.bullet", title: T("Sources")) { let go = session.onSwitchSource; let at = session.switchSpot; session.finish(natural: false, reopening: true); go?(at) } }
            // bp-ten-foot.tsx home-server-quality slot: a Plex/Jellyfin/Emby copy switches quality in place.
            if !session.isLive, session.context?.homeServer != nil { orb("hsquality", "dial.medium", title: T("Quality")) { session.open(.homeServerQuality) } }
            // control-renderer.tsx: on a live channel the pick-another control is the "TV Guide".
            if session.isLive, session.liveGuide != nil { orb("tvguide", "list.bullet.rectangle", title: T("TV Guide")) { session.open(.channels) } }
            // use-player-hotkeys playerPrevChannel: back to the last channel watched.
            if session.isLive, !session.prevChannels.isEmpty { orb("prevchannel", "arrow.uturn.backward", title: T("Previous channel")) { session.goPrevChannel() } }
            if session.isLive, let add = session.onAddToMultiview, let ch = session.currentChannel {
                orb("multiview", "rectangle.split.2x2", title: T("Add to Multiview")) { session.finish(natural: false); add(ch) }
            }
            // bp-player-rail: the mute toggle ("Muted" / "Sound on").
            orb("mute", session.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", title: T(session.muted ? "Muted" : "Sound on"), active: session.muted) {
                session.controller?.setMuted(!session.muted)
                session.muted.toggle()
            }
        }
        .focusSection()
        .onMoveCommand { dir in
            if dir == .down { focus = .chip(session.isLive ? "playpause" : "scrubber") }
        }
    }

    /// Apple's numbered skip glyphs ("gobackward.10") for the steps SF Symbols
    /// draws; any other step keeps the plain arrow.
    static func stepGlyph(_ base: String, _ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0, seconds < 1000 else { return base }
        let n: Int = Int(seconds.rounded())
        return [5, 10, 15, 30, 45, 60, 75, 90].contains(n) ? "\(base).\(n)" : base
    }

    /// A chrome control (PlayerOrbStyle). `id` is the focus id the chip of the same control had
    /// (panels hand the ring back to it on close), `title` the already-translated name.
    private func orb(_ id: String, _ icon: String, title: String, active: Bool = false, large: Bool = false, below: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: { action(); session.wake() }) { Label(title, systemImage: icon) }
            .buttonStyle(PlayerOrbStyle(title: title, active: active, large: large, captionBelow: below))
            .focused($focus, equals: .chip(id))
    }

    /// bp-player-scrub.tsx: buffered fill under the played fill; while presses accumulate, a
    /// marker stays where playback really is.
    private func seekBar(_ c: PlayerClock, focused: Bool = false) -> some View {
        let at: Double = c.snap.position
        let duration: Double = c.snap.duration
        let shown: Double = session.pendingSeek ?? at
        let bufferedEnd: Double = max(c.buffered, shown)
        let marked: Bool = session.pendingSeek != nil
        let edge: CGFloat = BP.px(32)
        // Apple TV's scrubber: a taller translucent track, white played fill, and
        // while presses add up a white time bubble over the spot playback will jump to.
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(Color.white.opacity(0.38)).frame(width: g.size.width * fraction(bufferedEnd, of: duration))
                Capsule().fill(Color.white).frame(width: g.size.width * fraction(shown, of: duration))
                if marked {
                    Capsule().fill(BP.accent).frame(width: 3).offset(x: g.size.width * fraction(at, of: duration) - 1.5)
                    Text(fmt(shown))
                        .font(BP.sans(13, .bold)).monospacedDigit().foregroundStyle(Color.black)
                        .padding(.horizontal, BP.px(8)).padding(.vertical, BP.px(3))
                        .background(Capsule().fill(Color.white))
                        .fixedSize()
                        .position(x: bubbleX(g.size.width * fraction(shown, of: duration), width: g.size.width, edge: edge), y: -BP.px(18))
                }
                // The focused scrubber shows its playhead, as Apple's does.
                if focused {
                    Circle().fill(Color.white)
                        .frame(width: BP.px(15), height: BP.px(15))
                        .shadow(color: Color.black.opacity(0.5), radius: 6, y: 2)
                        .position(x: g.size.width * fraction(shown, of: duration), y: g.size.height / 2)
                }
            }
        }
        .frame(height: BP.px(focused ? 9 : 6))
        .animation(BP.easeFast, value: focused)
        .padding(.vertical, BP.px(3))
        // bp-player-scrub.tsx draws the track from the physical left (left-0, left: %) under rtl too;
        // mirrored, the fill ran from the right and the pending-seek mark's offset left the bar.
        .environment(\.layoutDirection, .leftToRight)
        // Decorative: the invisible stage surface (bp-player-scrub role="slider") already carries the
        // real position as its VoiceOver value (PlayerSeekValue); this drawn track would only repeat it.
        .accessibilityHidden(true)
    }

    /// The seek bubble's centre: over the playhead, kept inside the track's ends.
    private func bubbleX(_ x: CGFloat, width: CGFloat, edge: CGFloat) -> CGFloat {
        let hi: CGFloat = max(edge, width - edge)
        return min(max(x, edge), hi)
    }

    private func fraction(_ sec: Double, of duration: Double) -> CGFloat {
        guard duration > 0, sec.isFinite else { return 0 }
        return CGFloat(min(1, max(0, sec / duration)))
    }

    /// bp-player-scrub.tsx readout: position, "{time} left", "Ends {time}".
    /// "Ends" follows the wall clock on its own (every minute), as it did when the
    /// whole player redrew each second: a paused video's clock does not move.
    private func scrubReadout(_ c: PlayerClock) -> some View {
        let duration: Double = c.snap.duration
        let shown: Double = session.pendingSeek ?? c.snap.position
        let remaining: Double = duration > 0 ? max(0, duration - shown) : 0
        let params: String = session.status.state == "loading" ? T("Loading…") : streamFacts
        return HStack(spacing: BP.px(10)) {
            Text(fmt(shown)).foregroundStyle(session.pendingSeek == nil ? Color.white.opacity(0.9) : Color.white)
            if !params.isEmpty { Text(params).font(BP.sans(11.5, .medium)).foregroundStyle(Color.white.opacity(0.4)) }
            Spacer()
            if duration > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("Ends \(Date().addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened))").foregroundStyle(Color.white.opacity(0.5))
                }
                Text(verbatim: "−" + fmt(remaining)).foregroundStyle(Color.white.opacity(0.9))
            }
        }
        .font(BP.sans(15, .semibold))
        .monospacedDigit()
        // Position, "{n} left" and "Ends {time}" are one readout: read as a single stop, not three.
        .accessibilityElement(children: .combine)
    }

    /// The progress bar takes the ring like any control (Apple's player):
    /// Down from the rail lands on it, Left / Right step through the film, Select plays / pauses or
    /// lands a pending seek, and touch-surface swipes scrub while it is focused.
    private var scrubberControl: some View {
        Button { session.scrubberSelect() } label: {
            PlayerClockReader(session.clock) { c in seekBar(c, focused: focus == .chip("scrubber")) }
        }
        .buttonStyle(BPBareButtonStyle())
        .focused($focus, equals: .chip("scrubber"))
        .onMoveCommand { dir in
            switch dir {
            case .left: session.nudgeSeek(ahead: false)
            case .right: session.nudgeSeek(ahead: true)
            case .up: focus = .chip("Subtitles")
            case .down: focus = .chip("playpause")
            default: break
            }
        }
        .accessibilityLabel(Text(T("Seek")))
        .modifier(PlayerSeekValue(clock: session.clock, isLive: session.isLive, pending: session.pendingSeek))
    }

    private func chip(_ label: String, _ icon: String, id: String? = nil, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: { action(); session.wake() }) { Label(T(label), systemImage: icon) }
            .buttonStyle(BPActionStyle(primary: active))
            .bpSelected(active)
            .focused($focus, equals: .chip(id ?? label))
    }

    private var anime4kChipLabel: String {
        guard let a = session.anime4k else { return "Anime4K" }
        if a.choice == "off" { return "Anime4K off" }
        return a.active ? "Anime4K \(a.mode ?? "")" : "Anime4K auto"
    }

    private func anime4kPanel() -> some View {
        let options: [(String, String, String)] = [("auto", "Auto", "Anime only, in the light tier this TV can run."), ("off", "Off", "No shaders (the TV's default)."),
                                                   ("A", "Mode A", "Restore + upscale. The best all-rounder for most anime."), ("B", "Mode B", "Softer restore. Kinder to compressed or noisy sources."),
                                                   ("C", "Mode C", "Denoise + upscale. Lightest, cleanest on already-sharp video."), ("AA", "Mode A+A", "Double restore. Sharpest detail, for high-quality sources."),
                                                   ("BB", "Mode B+B", "Double soft restore. For heavy compression artifacts."), ("CA", "Mode C+A", "Denoise then restore. Balanced cleanup and detail.")]
        let current = session.anime4k?.choice ?? (UserDefaults.standard.string(forKey: Self.anime4kKey) ?? "off")
        return HStack {
            Spacer()
            VStack(alignment: .leading, spacing: BP.px(8)) {
                Text("Anime4K").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.bottom, BP.px(6)).accessibilityAddTraits(.isHeader)
                ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                    Button { session.setAnime4k(o.0) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(T(o.1)).font(BP.sans(14, .semibold)); Spacer(); if current == o.0 { Image(systemName: "checkmark").accessibilityHidden(true) } }
                            Text(T(o.2)).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(BPActionStyle(primary: current == o.0)).bpSelected(current == o.0)
                    .focused($focus, equals: .track(-10 - i))
                }
                if let a = session.anime4k, a.active { BPNote(text: T("Running mode %@ (%@). Stutter? Switch the tier to Fast in Settings.", a.mode ?? "", a.tier == "fast" ? T("Fast") : "HQ")) }
                if let n = session.anime4kNote { BPNote(text: n, tone: BP.danger) }
                if !Anime4KStore.shared.installed { BPNote(text: "The shaders download on first use (about 3 MB).") }
            }
            .padding(BP.px(24))
            .frame(width: BP.px(420), alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(BP.panel.opacity(0.96))
            .focusSection()
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private func panelView(_ which: Panel) -> some View {
        switch which {
        case .anime4k:
            anime4kPanel()
        case .subtitles:
            PlayerSubtitlesPanel(controller: session.controller, context: session.context, title: session.title, subDelay: $session.subDelay) { session.closePanel() }
        case .audio:
            PlayerAudioPanel(controller: session.controller, title: session.title, audioDelay: $session.audioDelay) { session.closePanel() }
        case .channels:
            if let liveGuide = session.liveGuide {
                // The panel's "{n}m left" and airing bars read the wall clock; they moved
                // with the player's per-second redraw, which perf pass 4 removed, so they froze while
                // the guide was open. A minute beat redraws the panel.
                TimelineView(.everyMinute) { _ in
                    LivePlayerGuidePanel(model: liveGuide, current: session.currentChannel, onPick: { session.tune($0) }, onClose: { session.closePanel() })
                }
            }
        case .homeServerQuality:
            if let h = session.context?.homeServer {
                // The spot it switches from is read from the clock's leaf.
                PlayerClockReader(session.clock) { c in homeServerQualityPanel(h, c) }
            }
        case .kidsSources:
            if let context = session.context {
                // The stream's ref marks its row "Playing now" and moves with a swap.
                KidsStreamSwitcher(meta: context.meta, episode: session.kidsEpisode(context), currentURL: session.playURL, current: currentSource,
                                   onPicked: { next, headers, subs, ref in
                                       session.switchStream(to: next, headers: headers, subtitles: subs, ref: session.sourceRef(ref, playing: next))
                                   }, onClose: { session.closePanel() })
            }
        case .speed:
            PlayerSpeedPanel(rate: session.rate, isLive: session.isLive, onRate: { session.setRate($0) }, onClose: { session.closePanel() })
        case .sources:
            if let context = session.context {
                // bp-player-sources.tsx BpPlayerSources (PlayerSourcesPanel.swift).
                PlayerSourcesPanel(meta: context.meta, episode: session.pickEpisode ?? session.kidsEpisode(context), current: currentSource,
                                   onPicked: { stream, resolved in session.switchSource(stream, resolved) }, onClose: { session.closePanel() })
            }
        }
    }

    private func homeServerQualityPanel(_ h: HomeServerSession, _ c: PlayerClock) -> some View {
        HomeServerQualityPanel(session: h, positionSec: c.snap.position, playing: !c.snap.paused,
                               onSwitched: { next, headers, subs in
                                   session.pausedAfterSwitch = session.clock.snap.paused
                                   // bp-ten-foot.tsx replacePlayerSrc(await switchMediaServerQuality(…)): a new PlayerSrc.
                                   session.switchStream(to: next, headers: headers, subtitles: subs, replacesSrc: true)
                               }, onClose: { session.closePanel() })
    }

    /// Drawn inside the clock's leaf: its time bar observes the clock, the body does not.
    private var kidsChrome: some View {
        PlayerClockReader(session.clock) { c in kidsTransport(c) }
    }

    private func kidsTransport(_ c: PlayerClock) -> some View {
        KidsPlayerTransport(title: session.shownTitle, resolution: resolutionLabel, isLive: session.isLive, position: session.pendingSeek ?? c.snap.position,
                            duration: c.snap.duration, buffered: c.buffered, paused: c.snap.paused, muted: session.muted,
                            hasSubtitles: !session.kidSubs.isEmpty, subtitlesOn: session.kidSubs.contains { $0.selected }, canPickAnother: session.kidsCanSwitch,
                            focus: $focus,
                            onBack: { session.requestClose() },
                            onPlayPause: { session.togglePause() },
                            onSeekStep: { session.seekBy($0); session.wake() },
                            onMute: { session.controller?.setMuted(!session.muted); session.muted.toggle(); session.wake() },
                            onSubtitles: { session.toggleKidSubtitles(); session.wake() },
                            onPickAnother: { session.open(.kidsSources) })
    }

    private var kidsLoader: some View {
        let meta = session.context?.meta
        return KidsPlayerLoader(backdrop: meta?.background ?? meta?.poster, logo: meta?.logo, title: session.shownTitle,
                                episodeLine: kidsEpisodeLine,
                                torrentURL: TorrentEngine.streamRef(session.playURL) != nil ? session.playURL : nil,
                                isLocalFile: session.playURL.isFileURL, focus: $focus,
                                onCancel: { session.finish(natural: false) },
                                // The connecting card's Try again (player.tsx onLoaderRetry reloads the same URL).
                                onRetry: { session.reloadSame() })
            .onAppear { session.focusLater(.chip("kids-cancel")) }
            // The ring goes back to the stage once the picture is up (the resume fork and the error
            // card seed their own).
            .onDisappear { if session.resumePending == nil, !session.failed, session.panel == nil, !session.finishing { session.focusLater(.surface) } }
    }

    /// The loader's `S{season} · E{02}{ · name}` line.
    private var kidsEpisodeLine: String? {
        guard let context = session.context, let s = context.season else { return nil }
        var line = "S\(s) · E" + String(format: "%02d", context.episode ?? 1)
        if let sub = session.subtitle, let r = sub.range(of: " · ") { line += " · " + String(sub[r.upperBound...]) }
        return line
    }

    private var kidsResumePrompt: some View {
        KidsResumePrompt(title: session.shownTitle, focus: $focus, onResume: { session.acknowledgeResume(true) }, onStartOver: { session.acknowledgeResume(false) })
            .onAppear { session.controller?.setPaused(true); if let c = session.controller { session.takeSnap(c.snapshot()) } }
    }

    /// The readout's quiet stream line, the way Apple's player names a picture:
    /// "4K · HEVC · HDR" rather than mpv's raw "3840 1604 H.265".
    private var streamFacts: String {
        let tokens: [String] = session.status.videoParams.split(separator: " ").map { String($0) }
        var bits: [String] = []
        if let r = resolutionLabel { bits.append(r) }
        if tokens.count >= 3 {
            // mpv's video-codec is a long name with spaces ("Google VP9", "H.265 / HEVC …").
            let c: String = tokens.dropFirst(2).joined(separator: " ").uppercased()
            if c.contains("265") || c.contains("HEVC") { bits.append("HEVC") }
            else if c.contains("264") || c.contains("AVC") { bits.append("H.264") }
            else if c.contains("AV1") { bits.append("AV1") }
            else if c.contains("VP9") { bits.append("VP9") }
        }
        let lower: [String] = tokens.map { $0.lowercased() }
        if lower.contains("pq") { bits.append("HDR") } else if lower.contains("hlg") { bits.append("HLG") }
        return bits.joined(separator: " · ")
    }

    /// resolution-label.ts realQualityLabel from the decoded picture ("w h codec…" in status).
    private var resolutionLabel: String? {
        let parts = session.status.videoParams.split(separator: " ")
        guard parts.count >= 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0 || h > 0 else { return nil }
        if h >= 2160 || w >= 3840 { return "4K" }
        if h >= 1440 || w >= 2560 { return "1440p" }
        if h >= 1080 || w >= 1920 { return "1080p" }
        if h >= 720 || w >= 1280 { return "720p" }
        if h >= 480 || w >= 854 { return "480p" }
        return "SD"
    }

    /// switcher-row.tsx isCurrentStream's inputs: the URL playing and the picked stream's ref
    /// (PlayerSrc.streamRef, or the one swapped in), else the local torrent the URL names.
    private var currentSource: PlayerSourcesPanel.Current {
        let ref: AnyJSON? = session.switched != nil ? session.switched?.ref : session.pick?.streamRef
        let torrent = TorrentEngine.streamRef(session.playURL)
        let hash: String? = ref?["infoHash"]?.string ?? torrent?.infoHash
        var idx: Int? = torrent?.fileIdx
        if let n = ref?["fileIdx"]?.number, n.isFinite, n >= 0 { idx = clampedInt(n) }
        return PlayerSourcesPanel.Current(url: session.playURL.absoluteString, streamURL: ref?["url"]?.string, infoHash: hash, fileIdx: idx)
    }

    /// live-channel-error.tsx: the channel is not answering; Back, Try again, or Browse channels.
    private var liveErrorCard: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Spacer()
            HStack(spacing: BP.px(10)) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash").foregroundStyle(BP.danger).accessibilityHidden(true)
                Text("This channel isn't responding").font(BP.display(30)).foregroundStyle(BP.ink)
            }
            Text("It looks offline right now. Free playlists often include channels that have gone dark, so another one is usually a click away.")
                .font(BP.sans(16)).foregroundStyle(BP.inkMuted).frame(maxWidth: BP.px(900), alignment: .leading)
            HStack(spacing: BP.px(10)) {
                chip("Back", "chevron.backward", id: "live-back") { session.finish(natural: false) }
                chip("Try again", "arrow.clockwise", id: "live-retry") { session.reloadSame() }
                if session.liveGuide != nil { chip("Browse channels", "list.bullet.rectangle", id: "live-browse") { session.open(.channels) } }
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BP.gutter).padding(.bottom, BP.px(20))
        .background(LinearGradient(colors: [.clear, BP.void_.opacity(0.6), BP.void_.opacity(0.95)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .onAppear { session.hideTask?.cancel(); session.focusLater(.chip(session.liveGuide != nil ? "live-browse" : "live-retry")) }
    }

    /// bp-connecting: while the stream is still opening, elapsed time and a way out; after 22 s the
    /// copy admits it is still looking. Focus moves here only once a start is clearly slow.
    private var connectingCard: some View {
        let elapsed = Int(Date().timeIntervalSince(session.loadingSince))
        return VStack(alignment: .leading, spacing: BP.px(10)) {
            Spacer()
            HStack(spacing: BP.px(10)) { ProgressView().tint(BP.ink).accessibilityHidden(true); Text("Connecting…").font(BP.display(28)).foregroundStyle(BP.ink) }
            if TorrentEngine.streamRef(session.playURL) != nil {
                // bp-connecting with a torrent: bp-p2p-status's stage, readiness and peers/speed.
                TorrentReadout(url: session.playURL)
            } else {
                Text(elapsed >= 22 ? T("Still looking. Some sources take a while to answer.") : T("The player is opening the stream. %lld s", elapsed)).font(BP.sans(15)).foregroundStyle(BP.inkMuted)
            }
            if elapsed >= 8 {
                HStack(spacing: BP.px(10)) {
                    chip("Go back", "chevron.backward") { session.finish(natural: false) }
                    chip("Try again", "arrow.clockwise") { session.reloadSame() }
                    // The in-place switcher where it can open, else the picker at this spot.
                    if session.canSwitchInPlace { chip("Switch source", "list.bullet") { session.open(.sources) } }
                    else if session.onSwitchSource != nil { chip("Switch source", "list.bullet") { let go = session.onSwitchSource; let at = session.switchSpot; session.finish(natural: false, reopening: true); go?(at) } }
                }
                .focusSection()
                .onAppear { session.focusLater(.chip("Go back")) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BP.gutter).padding(.bottom, BP.px(20))
        .background(LinearGradient(colors: [.clear, BP.void_.opacity(0.5), BP.void_.opacity(0.9)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    /// speed-menu.tsx "Speed & sleep" control, drawn inside PlayerSleepReader.
    private func speedChip(_ timer: SleepTimer) -> some View {
        let changedRate: Bool = !session.isLive && abs(session.rate - 1) > 0.01
        return orb("speed", timer.isActive ? "clock" : "speedometer", title: T(speedChipLabel(timer)),
                   active: timer.isActive || changedRate) { session.open(.speed) }
    }

    /// speed-menu.tsx trigger face: the sleep countdown while a timer is armed, else a changed rate.
    private func speedChipLabel(_ timer: SleepTimer) -> String {
        if let face = timer.faceLabel { return face }
        if !session.isLive, abs(session.rate - 1) > 0.01 { return PlayerSpeedPanel.rateLabel(session.rate) }
        return session.isLive ? "Sleep timer" : "Speed & sleep"
    }

    private func fmt(_ s: Double) -> String { PlayerClock.fmt(s) }

    /// The resume fork's line: title, episode, then "{a} of {b}" through the catalogs (the literal
    /// Text was the letter-free key "%@%@ · %@%@", with an English " of " baked into an argument).
    private func resumeLine(_ sec: Double, duration: Double) -> String {
        let head: String = session.title + (session.subtitle.map { " · " + $0 } ?? "")
        let at: String = duration > 0 ? T("%@ of %@", fmt(sec), fmt(duration)) : fmt(sec)
        return head + " · " + at
    }

    /// bp-resume-prompt.tsx: a fork over the paused first frame; the ring lands on Resume.
    /// Drawn inside the clock's leaf: the file's duration can arrive under the fork.
    private func resumePrompt(_ sec: Double) -> some View {
        PlayerClockReader(session.clock) { c in resumeFork(sec, duration: c.snap.duration) }
            .onAppear { session.controller?.setPaused(true); if let c = session.controller { session.takeSnap(c.snapshot()) } }
    }

    private func resumeFork(_ sec: Double, duration: Double) -> some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            Spacer()
            Text("Pick up where you left off").font(BP.display(34)).foregroundStyle(BP.ink)
            Text(verbatim: resumeLine(sec, duration: duration))
                .font(BP.sans(16)).foregroundStyle(BP.inkMuted).lineLimit(1)
            if duration > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(BP.on)
                        Capsule().fill(BP.accent).frame(width: g.size.width * min(1, max(0, sec / duration)))
                    }
                }.frame(width: BP.px(420), height: BP.px(6))
                    .bpProgressValue(sec / duration)
            }
            HStack(spacing: BP.px(10)) {
                chip("Pick up where you left off", "play.fill") { session.acknowledgeResume(true) }
                chip("Start over", "arrow.counterclockwise") { session.acknowledgeResume(false) }
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BP.gutter).padding(.bottom, BP.px(34))
        // The picture (and its burned-in subtitles) stayed bright behind the
        // question and ran through the buttons; the whole frame now dims under it, deepest at the foot.
        .background(
            Color.black.opacity(0.5)
                .overlay(LinearGradient(colors: [.clear, Color.black.opacity(0.45), Color.black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
        )
    }

    /// The stage while the picture plays in the PiP window: where it went and the way back. The
    /// viewer can press the TV button and keep watching over other apps.
    private var pipPlacard: some View {
        ZStack {
            BP.void_.ignoresSafeArea()
            VStack(spacing: BP.px(14)) {
                Image(systemName: "pip").font(.system(size: BP.px(56), weight: .light)).foregroundStyle(BP.inkMuted).accessibilityHidden(true)
                Text(T("Picture in Picture")).font(BP.display(30)).foregroundStyle(BP.ink)
                Text(verbatim: session.shownTitle).font(BP.sans(16, .semibold)).foregroundStyle(BP.inkMuted).lineLimit(1)
                HStack(spacing: BP.px(10)) {
                    chip("Exit Picture in Picture", "pip.exit", id: "pip-exit") { session.controller?.stopPictureInPicture() }
                    // Back to browsing (PiPBrowse) while the picture stays in the PiP window.
                    if session.canBrowseDuringPiP { chip("Browse Harbor", "square.grid.2x2", id: "pip-browse") { session.browseHarbor() } }
                    chip("Leave", "rectangle.portrait.and.arrow.right", id: "pip-leave") { session.finish(natural: false) }
                }
                .padding(.top, BP.px(8))
                .focusSection()
            }
            .padding(BP.gutter)
        }
    }

    /// The white-screen failure had nothing in status.error:
    /// mpv can log the real reason (a vo:/vulkan/MoltenVK setup failure, or any other "failed" line)
    /// without ever reaching an end-file error, so a stream can look like it just silently never
    /// started. Falls back to the last matching log line so sourceErrorCard never says nothing.
    private var sourceErrorDetail: String? {
        if let e = session.endedEarly ?? session.status.error { return e }
        let needles = ["vo:", "vulkan", "moltenvk", "failed"]
        return session.status.log.last { line in
            let l = line.lowercased()
            return needles.contains { l.contains($0) }
        }
    }

    /// source-error-card.tsx: the stream would not open; pick another source, retry, or leave.
    private var sourceErrorCard: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Spacer()
            HStack(spacing: BP.px(10)) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(BP.danger).accessibilityHidden(true)
                Text("Harbor couldn't play this source").font(BP.display(30)).foregroundStyle(BP.ink)
            }
            Text("The source responded but the stream would not open. Try a different one.").font(BP.sans(16)).foregroundStyle(BP.inkMuted)
            if let e = sourceErrorDetail { Text(T("Source said") + ": " + e).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).lineLimit(1) }
            HStack(spacing: BP.px(10)) {
                if session.canPickAnother {
                    chip("Pick another source", "list.bullet") { session.pickAnotherSource() }
                }
                // Like the other retries: the connecting card's clock starts over (it
                // otherwise came up at once with the first open's elapsed time and "Still looking"),
                // and the torn-down engine is no longer read by the tick until the new one is ready.
                chip("Try again", "arrow.clockwise") { session.reloadSame() }
                // header-warning.tsx onUseMpv: the forced native engine could not open it; mpv can try.
                if session.engine == .native { chip("Use mpv engine", "play.rectangle") { session.useMpvEngine() } }
                chip("Back", "chevron.backward") { session.finish(natural: false) }
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BP.gutter).padding(.bottom, BP.px(20))
        .background(LinearGradient(colors: [.clear, BP.void_.opacity(0.6), BP.void_.opacity(0.95)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .onAppear { session.hideTask?.cancel(); session.focusLater(.chip(session.canPickAnother ? "Pick another source" : "Try again")) }
    }

    /// header-warning.tsx NoAudioWarning, over the stage above the transport.
    private var noAudioCard: some View {
        VStack {
            Spacer()
            VStack(spacing: BP.px(12)) {
                Text("No audio: this stream's audio format (likely Dolby or DTS) is not supported by the AVPlayer engine.")
                    .font(BP.sans(15, .medium)).foregroundStyle(BP.ink).multilineTextAlignment(.center)
                HStack(spacing: BP.px(10)) {
                    chip("Use mpv engine", "play.rectangle") { session.useMpvEngine() }
                    chip("Dismiss", "xmark") { session.noAudioWarning = false; focus = .surface }
                }
                .focusSection()
            }
            .padding(.horizontal, BP.px(24)).padding(.vertical, BP.px(18))
            .frame(maxWidth: BP.px(560))
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.void_.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge2, lineWidth: 1))
            .padding(.bottom, session.chrome ? BP.px(300) : BP.px(120))
        }
        .frame(maxWidth: .infinity)
    }

    /// bp-leave-confirm.tsx: Keep watching / Leave / Don't ask again.
    /// A centred frosted card over the dimmed frame, buttons stacked full width,
    /// as tvOS asks its own questions; it floated bare over the picture at the bottom left.
    private var leaveConfirmView: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: BP.px(12)) {
                // A film asked "Leave the show?"; upstream's copy fits an episode.
                Text(T(session.context?.meta.type == "movie" ? "Leave the movie?" : "Leave the show?")).font(BP.display(28)).foregroundStyle(Color.white).multilineTextAlignment(.center)
                Text("We'll save your spot so you can pick up right where you left off.").font(BP.sans(14.5))
                    .foregroundStyle(Color.white.opacity(0.7)).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: BP.px(9)) {
                    leaveButton("Keep watching", "play.fill", primary: true) { session.keepWatching() }
                    leaveButton("Leave", "rectangle.portrait.and.arrow.right") {
                        if session.leaveRemember { Task { try? await SettingsBridge.shared.patch(["playerConfirmLeave": .bool(false)]) } }
                        session.leaveConfirm = false
                        session.finish(natural: false)
                    }
                    leaveButton("Don't ask again", session.leaveRemember ? "checkmark.circle.fill" : "circle", active: session.leaveRemember) { session.leaveRemember.toggle() }
                }
                .padding(.top, BP.px(8))
                .focusSection()
            }
            .padding(BP.px(30))
            .frame(width: BP.px(440))
            .background(
                RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(Color.black.opacity(0.35)))
            )
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.6), radius: 40, y: 20)
        }
    }

    /// One full-width button of the Leave card; its focus id is the same `.chip(label)` the old
    /// chip row used (the card's appearance puts the ring on "Keep watching").
    private func leaveButton(_ label: String, _ icon: String, primary: Bool = false, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: { action(); session.wake() }) {
            Label(T(label), systemImage: icon).frame(maxWidth: .infinity)
        }
        .buttonStyle(BPActionStyle(primary: primary))
        .bpSelected(active)
        .focused($focus, equals: .chip(label))
    }
}
