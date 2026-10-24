import SwiftUI

/// The phone's player: full screen, turned landscape while it is up
/// (a root overlay, PhonePlayerOverlay, or a cover over the deep-link title sheet), over the shared
/// PlayerSession and the TV's two engines (mpv and AVPlayer, the same Auto rule). The session holds
/// playback, resume, saves, cues and the close; this view draws it with touch: a glass HUD that fades 3 s after the last touch (a tap toggles it), double taps on the left
/// or right third step back / ahead, a sideways pan scrubs, a pinch fills or fits the picture.
/// The cards (resume fork, leave, errors, connecting, cues, still watching) are in PhonePlayerCards.swift.
struct PhonePlayerView: View {
    let target: PhonePlayerTarget
    /// A root overlay (PhonePlayerOverlay) rather than a cover: while the picture floats in Picture in
    /// Picture the player steps aside and the viewer browses Harbor, the tab bar's accessory leading back.
    let hoisted: Bool
    @StateObject var session: PlayerSession
    /// The pinch's choice: the picture fills the screen (cropped) instead of fitting it.
    @State var fill = false
    /// The double tap's mark on the side it stepped (the step it took, summed over quick repeats).
    @State private var flash: (side: PhonePlayerHUD.Side, seconds: Double)?
    @State private var flashTask: Task<Void, Never>?
    /// Holds the screen awake while the video plays (DisplayAwake, released on pause and close).
    @State private var awake = PhoneAwakeToken()
    /// The engine-switch offer a PiP / AirPlay press on mpv raises (§2.7: say plainly what the button needs).
    @State private var offer: PhonePlayerSystem.Feature?
    /// The out-of-sight route picker the AirPlay button presses (AVPlayer engine only).
    @StateObject private var routes = PhoneAirPlayRoutes()
    /// The panel sheet the session does not own (stats, X-Ray); the others open through `session.panel`.
    @State private var local: PhonePlayerPanel?
    /// Lock controls: while locked the player takes no touch but the Unlock button's.
    @State private var lock = PhonePlayerLock()
    @State private var lockTask: Task<Void, Never>?
    /// The HUD buttons' values: the audio and subtitle tracks that are on.
    @State private var audioOn: String?
    @State private var subOn: String?
    @ObservedObject private var settings = SettingsBridge.shared
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(target: PhonePlayerTarget, hoisted: Bool) {
        self.target = target
        self.hoisted = hoisted
        _session = StateObject(wrappedValue: Self.makeSession(target, hoisted: hoisted))
    }

    /// The overlay is out of sight and out of reach while the picture floats; the session, its engine
    /// and its clock stay up under it.
    private var floating: Bool { hoisted && session.pipActive && !session.stillPrompt }

    /// The TV DetailView's PlayerScreen for the same target: each way back to the picker (another
    /// source, Switch source, a failed auto pick, the previous episode) reopens it once the cover has
    /// gone (PhonePlay.reopen); the close reports where it ended (PhonePlay.closed).
    private static func makeSession(_ t: PhonePlayerTarget, hoisted: Bool) -> PlayerSession {
        let play = PhonePlay.shared
        let s = PlayerSession(title: t.title, subtitle: t.subtitle, url: t.url, headers: t.headers, context: t.context, upNext: t.upNext,
                              streamHints: t.hints,
                              onChooseAnother: { play.reopen(t.request.again(video: t.episode, autoPlay: false)) },
                              onSwitchSource: { at in play.reopen(t.request.again(video: t.episode, autoPlay: false, switchFromSec: at)) },
                              onPreviousEpisode: play.previousEpisode(t),
                              pick: t.pick,
                              // views/player.tsx openPicker(meta, episode, { autoPlay: true, attempt: attempt + 1 }).
                              onPickAgain: { auto in play.reopen(t.request.again(video: t.episode, autoPlay: auto, attempt: t.pick.attempt + 1)) },
                              // A cover owns its session: nothing to browse under while the picture floats.
                              browseDuringPiP: hoisted,
                              streamSubtitles: t.subtitles, pickEpisode: t.episode, subtitlePreselect: t.preselect,
                              onClose: { advancing in play.closed(t, advancing: advancing) })
        s.hideDelay = PlayerFixtures.hudHideAfter ?? PhonePlayerHUD.hideAfter
        // leaving the app keeps the sound going (UIBackgroundModes audio) instead of pausing, as the TV does.
        s.keepsPlayingInBackground = true
        return s
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            engineLayer
            if session.engine == .native {
                PhoneAirPlayAnchor(routes: routes).frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
            }
            stage
            // The HUD stays hidden behind a panel sheet and while the controls are locked.
            if session.chromeShown, local == nil, lock.passesTouches { hud.transition(.opacity) }
            if let f = flash { seekFlash(f.side, seconds: f.seconds).allowsHitTesting(false) }
            // The cues follow the playhead: drawn in a leaf that observes the clock (the TV's cueLayer).
            PlayerClockReader(session.clock) { _ in cueLayer }
            if lock.locked { lockLayer.transition(.opacity) }
            if let sec = session.resumePending { resumeCard(sec).transition(.opacity) }
            if session.leaveConfirm { leaveCard.transition(.opacity) }
            if session.failed, !session.isLive, session.resumePending == nil, !session.leaveConfirm { errorCard.transition(.opacity) }
            if session.connectingShown { connectingCard.transition(.opacity) }
            if session.kidsLoading { kidsLoader.transition(.opacity) }
            if session.noAudioWarning, session.engine == .native, !session.leaveConfirm, session.resumePending == nil, !session.failed {
                noAudioCard.transition(.opacity)
            }
            if session.pipActive, !hoisted, !session.stillPrompt { pipPlacard.transition(.opacity) }
            if let note = session.backgroundNote, !session.pipActive { backgroundPill(note).transition(.opacity) }
            if session.stillPrompt {
                PhoneStillWatching(show: session.context?.meta.name ?? session.title, nextLabel: stillWatchingNextLabel,
                                   onContinue: { session.continueWatching() }, onExit: { session.stopWatching() })
                    .transition(.opacity)
            }
        }
        // The player is always dark: the picture is under every part of it.
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        // "player-screen" means the player is up; a floating one is out of sight and out of the tree.
        .accessibilityIdentifier(floating ? "player-floating" : "player-screen")
        // Over the root the shell is still in the tree: VoiceOver stays on the player.
        .accessibilityAddTraits(hoisted && !floating ? .isModal : [])
        .statusBarHidden(!floating)
        .persistentSystemOverlays(floating ? .automatic : .hidden)
        .opacity(floating ? 0 : 1)
        .allowsHitTesting(!floating)
        .accessibilityHidden(floating)
        .onChange(of: session.chromeShown) { _, up in session.chromeShownChanged(to: up) }
        .onChange(of: session.leaveConfirm) { _, up in session.leaveConfirmChanged(to: up) }
        .onAppear {
            PhoneOrientation.lock(.landscape)
            PhonePlayerSystem.activateAudioSession()
            session.appeared()
        }
        .onDisappear {
            session.disappeared()
            PhoneMiniState.shared.clear()
            DisplayAwake.shared.hold(awake, awake: false)
            PhoneOrientation.lock(.portrait)
        }
        .onReceive(CurfewState.shared.$locked) { session.curfewChanged($0) }
        // Leaving the app saves the spot at once (the session's pagehide save) and the sound goes on;
        // coming back, the HUD shows the film where it is, and a torrent that stopped says so.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in session.didEnterBackground() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in session.willEnterForeground() }
        .onChange(of: session.pipActive) { _, on in pipChanged(on) }
        .confirmationDialog(T("Picture in Picture and AirPlay"), isPresented: Binding(get: { offer != nil }, set: { if !$0 { offer = nil } }),
                            titleVisibility: .visible, presenting: offer) { feature in
            Button(PhonePlayerSystem.offerButton(for: feature)) { session.switchToNative() }
                .accessibilityIdentifier("player-switch-engine")
            Button(role: .cancel) {} label: { Text(T("Cancel")) }
        } message: { feature in
            Text(verbatim: PhonePlayerSystem.offerMessage(for: feature))
        }
        .task { await session.start() }
        .onReceive(tick) { _ in
            session.tick()
            if session.chromeShown { refreshPicks() }
        }
        .sheet(item: panelBinding) { p in
            PhonePanelSheet(panel: p, session: session, source: currentSource, onClose: dismissPanel)
        }
        .onChange(of: session.status.state) { _, state in
            session.statusChanged(to: state)
            holdAwake()
        }
        .onChange(of: session.isPaused) { _, paused in
            if !paused { session.backgroundNote = nil }
            session.pausedChanged(to: paused)
            holdAwake()
        }
        .onChange(of: session.reloadToken) { _, _ in session.reloadTokenChanged() }
        .motion(.easeOut(duration: 0.25), value: session.chrome)
        .motion(.easeOut(duration: 0.25), value: session.leaveConfirm)
        .motion(.easeOut(duration: 0.2), value: lock.locked)
        .motion(.easeOut(duration: 0.2), value: lock.hintShown)
    }

    /// The idle timer is off only while the video plays (§2.7): paused, loading or failed, the phone
    /// may sleep as usual.
    private func holdAwake() {
        DisplayAwake.shared.hold(awake, awake: session.status.state == "playing" && !session.isPaused)
    }

    // MARK: the engine

    /// As the TV's PlayerScreen: the engine view is built once the session knows where to start, and
    /// rebuilt (its id) by a retry or an engine move. Under UI-test fixtures a stand-in plays instead.
    @ViewBuilder private var engineLayer: some View {
        if let startAt = session.startAt, PlayerFixtures.standInEngine(for: session.playURL) {
            PhoneFixturePlayer(kind: session.engine, startAt: startAt, subtitles: session.subtitlePreselect?.title,
                               onStatus: { session.applyStatus($0) }, onEnded: { session.endedNaturally() },
                               onReady: { [token = session.reloadToken] c in
                                   if session.engine == .native { session.nativeReady(c, token: token) } else { session.mpvReady(c, token: token) }
                                   applyFill(c)
                               },
                               onPictureInPicture: { on in if session.engine == .native { session.pipChanged(on) } })
                .ignoresSafeArea()
                .id(session.reloadToken)
        } else if let startAt = session.startAt, session.engine == .native {
            NativePlayerView(url: session.playURL, headers: session.playHeaders, startAt: startAt, isLive: session.isLive,
                             preferredAudio: SettingsBridge.shared.slice.preferredAudioLangs ?? ["English", "Japanese"],
                             preferredSubs: SettingsBridge.shared.slice.preferredSubLangs,
                             trackMemory: session.trackMemory,
                             seedSubtitles: session.playSeeds,
                             onStatus: { s in if session.engine == .native { session.applyStatus(s) } },
                             onEnded: { if session.engine == .native { session.endedNaturally() } },
                             onUnsupported: { session.nativeUnsupported($0) },
                             // Delivered a main-queue turn after creation: the session drops a stale engine's report.
                             onReady: { [token = session.reloadToken] c in
                                 session.nativeReady(c, token: token)
                                 applyFill(c)
                             },
                             onPictureInPicture: { on in if session.engine == .native { session.pipChanged(on) } },
                             onPictureInPictureRestore: { if hoisted { PhonePlay.shared.pictureReturning() } },
                             onPictureInPictureClosed: { if session.engine == .native { pipClosedByViewer() } })
                .ignoresSafeArea()
                .id(session.reloadToken)
        } else if let startAt = session.startAt {
            MPVPlayerView(url: session.playURL, headers: session.playHeaders, startAt: startAt, isLive: session.isLive,
                          preferredAudio: SettingsBridge.shared.slice.preferredAudioLangs ?? ["English", "Japanese"],
                          preferredSubs: SettingsBridge.shared.slice.preferredSubLangs,
                          trackMemory: session.trackMemory,
                          seedSubtitles: session.playSeeds,
                          onStatus: { session.applyStatus($0) }, onEnded: { session.endedNaturally() },
                          onReady: { [token = session.reloadToken] c in
                              session.mpvReady(c, token: token)
                              applyFill(c)
                          })
                .ignoresSafeArea()
                .id(session.reloadToken)
        }
    }

    /// A new engine (a retry, the move to mpv) keeps the pinch's choice.
    private func applyFill(_ c: any PlayerEngineControlling) {
        if fill { c.setPictureFill(true) }
    }

    // MARK: the stage's touches

    /// Nothing over the picture takes the touches the stage would: the prompts and cards have their
    /// own buttons.
    private var stageLive: Bool {
        session.resumePending == nil && !session.leaveConfirm && !session.stillPrompt && !session.failed && !session.kidsLoading
    }

    /// The touch surface under the HUD: tap, double tap, sideways pan, pinch. For VoiceOver it is the
    /// seek slider (bp-player-scrub role="slider"), as the TV's stage is, and activating it toggles the HUD.
    private var stage: some View {
        GeometryReader { g in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { v in doubleTap(x: v.location.x, width: g.size.width) }
                        .exclusively(before: TapGesture().onEnded { toggleHUD() })
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onChanged { v in
                            guard !session.isLive, abs(v.translation.width) > abs(v.translation.height) else { return }
                            session.scrubSwipe(v.translation.width / max(1, g.size.width))
                        }
                        .onEnded { _ in session.scrubSwipeEnded() }
                )
                .simultaneousGesture(MagnifyGesture().onEnded { v in pinched(v.magnification) })
        }
        .ignoresSafeArea()
        .allowsHitTesting(stageLive && lock.passesTouches)
        .accessibilityElement()
        .accessibilityLabel(Text(T(session.isLive ? "Player controls" : "Seek")))
        .modifier(PlayerSeekValue(clock: session.clock, isLive: session.isLive, pending: session.pendingSeek))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(ahead: true)
            case .decrement: step(ahead: false)
            @unknown default: break
            }
        }
        .accessibilityAction { toggleHUD() }
        .accessibilityIdentifier("player-stage")
    }

    /// A tap: the HUD comes up, or goes if it is up.
    private func toggleHUD() {
        StillWatching.reset()
        if session.chromeShown {
            session.hideTask?.cancel()
            session.chrome = false
        } else {
            session.wake()
        }
    }

    /// One seek step back or ahead (the player prefs' steps, 10 s unless changed), as the HUD's buttons.
    private func step(ahead: Bool) {
        let delta: Double = ahead ? session.prefs.seekForwardStepSec : -session.prefs.seekBackStepSec
        if session.isLive { session.controller?.seek(delta) } else { session.seekBy(delta) }
        session.wake()
    }

    /// A double tap on the left or right third steps back or ahead; the HUD stays as it was (its wait
    /// starts over when it is up). In the middle third it is a tap.
    private func doubleTap(x: CGFloat, width: CGFloat) {
        let side = PhonePlayerHUD.side(x: x, width: width)
        guard let delta = PhonePlayerHUD.seekDelta(side, back: session.prefs.seekBackStepSec, ahead: session.prefs.seekForwardStepSec) else {
            toggleHUD()
            return
        }
        StillWatching.reset()
        if session.isLive { session.controller?.seek(delta) } else { session.seekBy(delta) }
        if session.chromeShown { session.wake() }
        PhoneFeedback.shared.tap()
        // Quick repeats on the same side add up on the mark.
        let shown: Double = flash?.side == side ? (flash?.seconds ?? 0) + abs(delta) : abs(delta)
        flash = (side, shown)
        flashTask?.cancel()
        flashTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { flash = nil }
        }
    }

    private func pinched(_ scale: CGFloat) {
        let next: Bool = PhonePlayerHUD.fill(afterPinch: scale, current: fill)
        guard next != fill else { return }
        setFill(next)
    }

    func setFill(_ next: Bool) {
        fill = next
        session.controller?.setPictureFill(next)
        PhoneFeedback.shared.tap()
    }

    /// The double tap's mark: a glass disc on the side it stepped, with the seconds stepped.
    private func seekFlash(_ side: PhonePlayerHUD.Side, seconds: Double) -> some View {
        let back: Bool = side == .back
        return HStack {
            if !back { Spacer() }
            VStack(spacing: 6) {
                Image(systemName: back ? "backward.fill" : "forward.fill").font(.system(size: 22, weight: .semibold))
                Text(verbatim: (back ? "−" : "+") + "\(Int(seconds.rounded())) s").font(PhoneTheme.sans(14, .semibold, relativeTo: .footnote)).monospacedDigit()
            }
            .foregroundStyle(Color.white)
            .frame(width: 104, height: 104)
            .glassEffect(.regular, in: .circle)
            .padding(.horizontal, 56)
            if back { Spacer() }
        }
        .transition(.opacity)
        .accessibilityHidden(true)
    }

    // MARK: the HUD

    /// §2.7's glass HUD in one GlassEffectContainer: Close, the title and episode, the lock and the fill
    /// toggle along the top; Back / Play-Pause / Forward in the middle; the panel buttons (subtitles,
    /// audio, speed & sleep, sources, quality, stats, X-Ray), each opening a sheet; the scrubber with
    /// elapsed and remaining at the foot.
    private var hud: some View {
        GlassEffectContainer(spacing: 18) {
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)
                transport
                Spacer(minLength: 12)
                panelRow
                if !session.isLive {
                    PlayerClockReader(session.clock) { c in scrubber(c) }
                }
            }
            .padding(.horizontal, PhoneTheme.margin)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(stops: [.init(color: Color.black.opacity(0.6), location: 0), .init(color: .clear, location: 0.3),
                                   .init(color: .clear, location: 0.62), .init(color: Color.black.opacity(0.7), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-hud")
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 14) {
            orb("player-close", "xmark", label: T("Close"), size: 17) { session.requestClose() }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: session.shownTitle)
                    .font(PhoneTheme.display(19, relativeTo: .headline)).foregroundStyle(Color.white).lineLimit(1)
                    .accessibilityIdentifier("player-title")
                if let s = session.shownSubtitle {
                    Text(verbatim: s)
                        .font(PhoneTheme.sans(13, .medium, relativeTo: .subheadline)).foregroundStyle(Color.white.opacity(0.72)).lineLimit(1)
                        .accessibilityIdentifier("player-subtitle")
                }
            }
            .shadow(color: Color.black.opacity(0.45), radius: 8, y: 1)
            Spacer(minLength: 12)
            if pipAction != .hidden {
                orb("player-pip", pipAction == .stop ? "pip.exit" : "pip.enter", label: T("Picture in Picture"), size: 16) { pipPressed() }
            }
            orb("player-airplay", "airplayvideo", label: T("AirPlay"), size: 16) { airPlayPressed() }
            orb("player-lock", "lock.fill", label: T("Lock controls"), size: 16) { lockControls() }
            orb("player-fill", fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                label: T(fill ? "Fit the screen" : "Fill the screen"), size: 16) { setFill(!fill) }
        }
    }

    // MARK: Picture in Picture and AirPlay

    private var pipAction: PhonePlayerSystem.PiPAction {
        PhonePlayerSystem.pipAction(engine: session.engine, supported: session.controller?.supportsPictureInPicture ?? true,
                                    active: session.pipActive)
    }

    private func pipPressed() {
        switch pipAction {
        case .start: session.controller?.startPictureInPicture()
        case .stop: session.controller?.stopPictureInPicture()
        case .offerNative: offer = .pictureInPicture
        case .hidden: break
        }
    }

    private func airPlayPressed() {
        switch PhonePlayerSystem.airPlayAction(engine: session.engine) {
        case .picker: routes.present()
        case .offerNative: offer = .airPlay
        }
    }

    /// The tab bar's accessory follows the floating picture (PhoneMiniState). A cover keeps the
    /// session in front, so there the player's own placard is what the viewer sees on coming back; the
    /// overlay steps aside instead (and the screen turns upright for browsing).
    private func pipChanged(_ on: Bool) {
        if hoisted { PhoneOrientation.lock(on ? .portrait : .landscape) }
        guard on else { PhoneMiniState.shared.clear(); return }
        PhoneMiniState.shared.set(.init(title: session.shownTitle, subtitle: session.shownSubtitle),
                                  bringBack: { session.controller?.stopPictureInPicture() },
                                  // The close takes the player down, and its window with it.
                                  end: {
                                      session.controller?.setPaused(true)
                                      session.finish(natural: false)
                                  })
    }

    /// The floating picture's window was closed (its X): over a cover the picture just comes back to the
    /// placard; with the viewer browsing, the video stops and saves (PlayerSession.pipClosedByViewer).
    private func pipClosedByViewer() {
        guard hoisted else { return }
        session.controller?.setPaused(true)
        session.finish(natural: false)
    }

    /// While the picture floats a cover shows this instead of it: what is playing, and a way back.
    private var pipPlacard: some View {
        VStack(spacing: 14) {
            Image(systemName: "pip").font(.system(size: 34, weight: .semibold)).accessibilityHidden(true)
            Text(verbatim: T("Picture in Picture")).font(PhoneTheme.display(19, relativeTo: .headline))
            Text(verbatim: session.shownTitle).font(PhoneTheme.sans(14, .medium, relativeTo: .subheadline)).opacity(0.72).lineLimit(1)
            HStack(spacing: 12) {
                Button { session.controller?.stopPictureInPicture() } label: {
                    Text(T("Exit Picture in Picture")).font(PhoneTheme.sans(15, .semibold, relativeTo: .body)).padding(.horizontal, 18).padding(.vertical, 8)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("player-pip-exit")
                Button { session.requestClose() } label: {
                    Text(T("Close")).font(PhoneTheme.sans(15, .semibold, relativeTo: .body)).padding(.horizontal, 18).padding(.vertical, 8)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("player-pip-close")
            }
        }
        .foregroundStyle(Color.white)
        .padding(24)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-pip-placard")
    }

    /// The torrent stream stopped while Harbor was away: said where the viewer looks, gone on play.
    private func backgroundPill(_ note: String) -> some View {
        VStack {
            Text(verbatim: note)
                .font(PhoneTheme.sans(14, .semibold, relativeTo: .footnote))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .onTapGesture { session.backgroundNote = nil }
                .accessibilityIdentifier("player-background-note")
            Spacer()
        }
        .padding(.top, 20)
        .padding(.horizontal, PhoneTheme.margin)
    }

    private var transport: some View {
        HStack(spacing: 40) {
            if !session.isLive {
                orb("player-back", PhonePlayerHUD.stepGlyph("gobackward", session.prefs.seekBackStepSec),
                    label: T("Back %llds", Int(session.prefs.seekBackStepSec)), size: 24) { step(ahead: false) }
            }
            orb("player-playpause", session.isPaused ? "play.fill" : "pause.fill",
                label: T(session.isPaused ? "Play" : "Pause"), size: 34) { session.togglePause() }
            if !session.isLive {
                orb("player-ahead", PhonePlayerHUD.stepGlyph("goforward", session.prefs.seekForwardStepSec),
                    label: T("Forward %llds", Int(session.prefs.seekForwardStepSec)), size: 24) { step(ahead: true) }
            }
        }
    }

    // MARK: the panels

    /// The HUD's panel buttons: what a title gets is PhonePlayerPanel.shown.
    private var panelFacts: PhonePlayerPanel.Facts {
        let canReopen: Bool = !session.isLive && session.tuned == nil && !session.isKid && session.onSwitchSource != nil
        let xray: Bool = settings.slice.xrayEnabled == true && session.context?.meta != nil && !session.isLive
        return PhonePlayerPanel.Facts(isLive: session.isLive, hasHomeServer: session.context?.homeServer != nil,
                                      sources: PhonePlayerPanel.sourcesRoute(canSwitchInPlace: session.canSwitchInPlace, canReopen: canReopen),
                                      xray: xray, isKid: session.isKid)
    }

    private var panelRow: some View {
        HStack(spacing: 12) {
            ForEach(PhonePlayerPanel.shown(panelFacts)) { p in
                if p == .speed {
                    PhoneSleepFace { sleep in
                        panelButton(p, face: PhoneSpeedSleep.face(rate: session.rate, isLive: session.isLive, sleepFace: sleep),
                                    value: PhoneSpeedSleep.rateLabel(session.rate))
                    }
                } else {
                    panelButton(p, face: nil, value: panelValue(p))
                }
            }
        }
        .padding(.bottom, session.isLive ? 0 : 10)
    }

    /// The value a panel's button reads out: the track that is on.
    private func panelValue(_ p: PhonePlayerPanel) -> String? {
        switch p {
        case .audio: return audioOn
        case .subtitles: return subOn ?? T("Off")
        default: return nil
        }
    }

    private func panelButton(_ p: PhonePlayerPanel, face: String?, value: String?) -> some View {
        Button {
            StillWatching.reset()
            PhoneFeedback.shared.tap()
            openPanel(p)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: p.icon).font(.system(size: 17, weight: .semibold))
                if let face {
                    Text(verbatim: face).font(PhoneTheme.sans(14, .semibold, relativeTo: .footnote)).monospacedDigit()
                        .accessibilityIdentifier(p.buttonID + "-face")
                }
            }
            .foregroundStyle(Color.white)
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, face == nil ? 0 : 8)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .accessibilityLabel(Text(verbatim: p.title))
        .accessibilityValue(Text(verbatim: value ?? ""))
        .accessibilityIdentifier(p.buttonID)
    }

    /// A press on a panel button: the session's panels go through `session.open` (so the shared Sources
    /// swap and the HUD hiding work as on the TV); stats and X-Ray are the view's own.
    private func openPanel(_ p: PhonePlayerPanel) {
        session.hideTask?.cancel()
        refreshPicks()
        switch p {
        case .stats, .xray:
            local = p
        case .sources where !session.canSwitchInPlace:
            // Where a copy can't be swapped in place the picker reopens at this spot (the TV's Switch source).
            let go = session.onSwitchSource
            let at = session.switchSpot
            session.finish(natural: false, reopening: true)
            go?(at)
        default:
            if let panel = p.sessionPanel { session.open(panel) }
        }
    }

    /// The sheet on show: the session's panel, else the view's own.
    private var panelBinding: Binding<PhonePlayerPanel?> {
        Binding(get: { session.panel.flatMap { PhonePlayerPanel($0) } ?? local },
                set: { if $0 == nil { dismissPanel() } })
    }

    private func dismissPanel() {
        local = nil
        if session.panel != nil { session.closePanel() } else { session.wake() }
        refreshPicks()
    }

    /// The audio and subtitle tracks that are on, for the buttons' values.
    private func refreshPicks() {
        let tracks: [MPVPlayerController.Track] = session.controller?.tracks() ?? []
        let a: String? = PhoneTrackText.onLabel(tracks, type: "audio")
        let s: String? = PhoneTrackText.onLabel(tracks, type: "sub")
        if a != audioOn { audioOn = a }
        if s != subOn { subOn = s }
    }

    /// switcher-row.tsx isCurrentStream's inputs (the TV's PlayerScreen.currentSource): the URL playing and
    /// the picked stream's ref, else the local torrent the URL names.
    private var currentSource: PlayingSource {
        let ref: AnyJSON? = session.switched != nil ? session.switched?.ref : session.pick?.streamRef
        let torrent = TorrentEngine.streamRef(session.playURL)
        let hash: String? = ref?["infoHash"]?.string ?? torrent?.infoHash
        var idx: Int? = torrent?.fileIdx
        if let n = ref?["fileIdx"]?.number, n.isFinite, n >= 0 { idx = clampedInt(n) }
        return PlayingSource(url: session.playURL.absoluteString, streamURL: ref?["url"]?.string, infoHash: hash, fileIdx: idx)
    }

    // MARK: lock controls

    private func lockControls() {
        lock.lock()
        lockTask?.cancel()
        session.hideTask?.cancel()
        PhoneFeedback.shared.tap()
    }

    /// A touch on the locked player: only the Unlock button comes up, for a few seconds.
    private func touchedLocked() {
        lock.touched()
        lockTask?.cancel()
        lockTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(PlayerFixtures.hudHideAfter ?? PhonePlayerLock.hintFor))
            if !Task.isCancelled { lock.hintExpired() }
        }
    }

    private func unlockControls() {
        lockTask?.cancel()
        lock.unlock()
        PhoneFeedback.shared.tap()
        session.wake()
    }

    /// Over the picture while locked: it takes every touch (so nothing under it seeks, pauses or fills)
    /// and answers with the Unlock button. The cards and prompts stay above it.
    private var lockLayer: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in if !lock.hintShown { touchedLocked() } }
                    .onEnded { _ in if lock.hintShown { touchedLocked() } })
                .accessibilityElement()
                .accessibilityLabel(Text(T("Controls locked")))
                .accessibilityAction { touchedLocked() }
                .accessibilityIdentifier("player-lock-layer")
            if lock.hintShown {
                Button { unlockControls() } label: {
                    Label { Text(verbatim: T("Unlock")) } icon: { Image(systemName: "lock.open.fill") }
                        .font(PhoneTheme.sans(17, .semibold, relativeTo: .body))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 22).padding(.vertical, 14)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .transition(.opacity)
                .accessibilityIdentifier("player-unlock")
            }
        }
    }

    /// A round glass HUD button; any press restarts the HUD's wait.
    private func orb(_ id: String, _ icon: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            StillWatching.reset()
            action()
            if !session.leaveConfirm { session.wake() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: size * 2.1, height: size * 2.1)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
    }

    /// bp-player-scrub.tsx on the phone: the played fill over the buffered one; a finger on the bar
    /// moves a pending spot (with a time bubble over it) that lands when it lifts. No trickplay
    /// thumbnail: neither engine gives one.
    private func scrubber(_ c: PlayerClock) -> some View {
        let duration: Double = c.snap.duration
        let shown: Double = session.pendingSeek ?? c.snap.position
        let labels = PhonePlayerHUD.labels(position: c.snap.position, duration: duration, pending: session.pendingSeek)
        let played: Double = PhonePlayerHUD.barFraction(position: shown, duration: duration)
        let buffered: Double = PhonePlayerHUD.barFraction(position: max(c.buffered, shown), duration: duration)
        let dragging: Bool = session.pendingSeek != nil
        return HStack(spacing: 12) {
            Text(verbatim: labels.elapsed).accessibilityIdentifier("player-elapsed")
            GeometryReader { g in
                let w: CGFloat = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22)).frame(height: dragging ? 8 : 5)
                    Capsule().fill(Color.white.opacity(0.38)).frame(width: w * buffered, height: dragging ? 8 : 5)
                    Capsule().fill(Color.white).frame(width: w * played, height: dragging ? 8 : 5)
                    Circle().fill(Color.white)
                        .frame(width: dragging ? 20 : 13, height: dragging ? 20 : 13)
                        .shadow(color: Color.black.opacity(0.4), radius: 4, y: 1)
                        .position(x: w * played, y: g.size.height / 2)
                    if dragging {
                        Text(verbatim: PlayerClock.fmt(shown))
                            .font(PhoneTheme.sans(13, .bold, relativeTo: .caption)).monospacedDigit().foregroundStyle(Color.black)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.white))
                            .fixedSize()
                            .position(x: min(max(w * played, 30), max(30, w - 30)), y: -16)
                            .accessibilityIdentifier("player-scrub-time")
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard let t = PhonePlayerHUD.scrubTarget(x: v.location.x, width: w, duration: duration) else { return }
                            session.seekCommit?.cancel()
                            session.hideTask?.cancel()
                            session.pendingSeek = t
                        }
                        .onEnded { _ in
                            if session.pendingSeek != nil { session.commitSeek(after: 0) }
                            session.wake()
                        }
                )
                .motion(.easeOut(duration: 0.15), value: dragging)
            }
            .frame(height: 30)
            // The bar draws from the physical left under right-to-left too (bp-player-scrub.tsx).
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityElement()
            .accessibilityLabel(Text(T("Seek")))
            .accessibilityValue(Text(verbatim: PlayerClock.fmt(shown)))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(ahead: true)
                case .decrement: step(ahead: false)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("player-scrubber")
            Text(verbatim: labels.remaining).accessibilityIdentifier("player-remaining")
        }
        .font(PhoneTheme.sans(14, .semibold, relativeTo: .footnote))
        .monospacedDigit()
        .foregroundStyle(Color.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }
}

/// The DisplayAwake holder of one phone player (the table holds it weakly).
final class PhoneAwakeToken {}
