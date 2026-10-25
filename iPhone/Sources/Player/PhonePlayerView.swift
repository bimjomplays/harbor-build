import SwiftUI

/// The phone's player: full screen, turned landscape while it is up
/// (a root overlay, PhonePlayerOverlay, or a cover over the deep-link title sheet), over the shared
/// PlayerSession and the TV's two engines (mpv and AVPlayer, the same Auto rule). The session holds
/// playback, resume, saves, cues and the close; this view draws it with touch, laid out like Infuse:
/// glass buttons in the corners (close, fit / fill and Picture in Picture top left; the volume top
/// right; the gear menu, AirPlay and the lock bottom right), the title and the bar at the foot, and
/// plain skip and play icons in the middle. The HUD fades 3 s after the last touch.
/// The touches (PhonePlayerStage): a tap toggles the HUD, a double tap on the left or right third
/// steps back / ahead, a press and hold there plays at 2x while held, a sideways drag scrubs, up and
/// down set the brightness (left half) and the volume (right half), a pull down from the middle closes,
/// a pinch fills or fits the picture.
/// The HUD is in PhonePlayerChrome.swift, the gear menu in PhonePlayerGearMenu.swift, the cards (resume
/// fork, leave, errors, connecting, cues, still watching) in PhonePlayerCards.swift.
struct PhonePlayerView: View {
    let target: PhonePlayerTarget
    /// A root overlay (PhonePlayerOverlay) rather than a cover: while the picture floats in Picture in
    /// Picture the player steps aside and the viewer browses Harbor, the tab bar's accessory leading back.
    let hoisted: Bool
    @StateObject var session: PlayerSession
    /// The pinch's (or the aspect button's) choice: the picture fills the screen (cropped) instead of fitting it.
    @State var fill = false
    /// The double tap's mark on the side it stepped (the step it took, summed over quick repeats).
    @State var flash: SeekFlash?
    @State var flashTask: Task<Void, Never>?
    /// Holds the screen awake while the video plays (DisplayAwake, released on pause and close).
    @State var awake = PhoneAwakeToken()
    /// The engine-switch offer a PiP / AirPlay press on mpv raises (§2.7: say plainly what the button needs).
    @State var offer: PhonePlayerSystem.Feature?
    /// The out-of-sight route picker the AirPlay button presses (AVPlayer engine only).
    @StateObject var routes = PhoneAirPlayRoutes()
    /// The panel sheet the session does not own (stats, X-Ray); the others open through `session.panel`.
    @State var local: PhonePlayerPanel?
    /// Lock controls: while locked the player takes no touch but the Unlock button's.
    @State var lock = PhonePlayerLock()
    @State var lockTask: Task<Void, Never>?
    /// The audio and subtitle tracks that are on (their names, for the accessibility values).
    @State var audioOn: String?
    @State var subOn: String?
    @ObservedObject var settings = SettingsBridge.shared
    /// The phone's volume (the capsule top right, the right-half swipe) and the screen's brightness.
    @StateObject var volume: PhoneVolume
    @StateObject var brightness: PhoneBrightness
    /// Volume Boost: percent above the file's own level (mpv), kept across a reload.
    @State var boost = 0
    /// The level a swipe is moving, shown while it moves and a moment after.
    @State var levelShown: PhonePlayerLevel?
    @State var levelTask: Task<Void, Never>?
    @State var levelStart: Double = 0
    /// A press and hold is playing at 2x (the "2x" pill shows).
    @State var holding = false
    @State var holdTask: Task<Void, Never>?
    /// The pull down to close: how far the picture has followed the finger.
    @State var pull: CGFloat = 0
    /// The gear menu is open: the HUD stays.
    @State var menuOpen = false
    /// The scrub preview's frames. Held, not observed: only the plate over the bar watches it, so a new
    /// frame redraws the plate and not the player.
    @State var preview = PhoneScrubPreview()
    /// Under fixtures: the last drag's spot, still drawn a moment after the finger lifts (for the shots).
    @State var scrubLinger: Double?
    @State var lingerTask: Task<Void, Never>?
    let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(target: PhonePlayerTarget, hoisted: Bool) {
        self.target = target
        self.hoisted = hoisted
        _session = StateObject(wrappedValue: Self.makeSession(target, hoisted: hoisted))
        // Under fixtures the levels are the test's (a simulator has neither).
        let fixture: Bool = Fixtures.active
        _volume = StateObject(wrappedValue: PhoneVolume(start: fixture ? 0.4 : nil))
        _brightness = StateObject(wrappedValue: PhoneBrightness(start: fixture ? 0.6 : nil))
    }

    /// The overlay is out of sight and out of reach while the picture floats; the session, its engine
    /// and its clock stay up under it.
    var floating: Bool { hoisted && session.pipActive && !session.stillPrompt }

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

    /// The HUD is up: not behind a panel sheet, while the controls are locked, or while the picture is
    /// being pulled down.
    var hudUp: Bool { (session.chromeShown || menuOpen) && session.panel == nil && local == nil && lock.passesTouches && pull < 1 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            engineLayer
                .offset(y: pull)
                .scaleEffect(1 - min(0.12, pull / 2400), anchor: .top)
            if session.engine == .native {
                PhoneAirPlayAnchor(routes: routes).frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
            }
            PhoneVolumeHost(volume: volume).frame(width: 2, height: 2).allowsHitTesting(false).accessibilityHidden(true)
            stage
            if let f = flash { PhoneSeekRipple(flash: f).id(f.id).allowsHitTesting(false) }
            if hudUp {
                hud.transition(.opacity)
            } else if levelShown == .volume, lock.passesTouches {
                // A volume swipe with the HUD away shows the volume capsule on its own.
                volumeAlone.transition(.opacity)
            }
            topPills
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
            preview.close()
            session.disappeared()
            PhoneMiniState.shared.clear()
            DisplayAwake.shared.hold(awake, awake: false)
            brightness.restore()
            PhoneOrientation.lock(.portrait)
        }
        .onReceive(CurfewState.shared.$locked) { session.curfewChanged($0) }
        // Leaving the app saves the spot at once (the session's pagehide save) and the sound goes on;
        // coming back, the HUD shows the film where it is, and a torrent that stopped says so. The
        // phone's own brightness comes back while Harbor is away.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            brightness.restore()
            preview.close()
            session.didEnterBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in preview.trim() }
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
            if paused, holding { endHold() }
            holdAwake()
        }
        .onChange(of: session.reloadToken) { _, _ in
            preview.close()
            session.reloadTokenChanged()
        }
        .onChange(of: session.pendingSeek) { old, new in scrubMoved(from: old, to: new) }
        .motion(.easeOut(duration: 0.25), value: session.chrome)
        .motion(.easeOut(duration: 0.25), value: session.leaveConfirm)
        .motion(.easeOut(duration: 0.2), value: lock.locked)
        .motion(.easeOut(duration: 0.2), value: lock.hintShown)
        .motion(.easeOut(duration: 0.2), value: levelShown)
        .motion(.easeOut(duration: 0.2), value: holding)
    }

    /// The idle timer is off only while the video plays (§2.7): paused, loading or failed, the phone
    /// may sleep as usual.
    func holdAwake() {
        DisplayAwake.shared.hold(awake, awake: session.status.state == "playing" && !session.isPaused)
    }

    /// The scrub preview follows the pending spot: a frame for it while the finger drags, none once it
    /// lands. Under fixtures the last spot stays drawn 6 s (the shots are taken after the finger lifts).
    func scrubMoved(from old: Double?, to new: Double?) {
        if let new {
            lingerTask?.cancel()
            scrubLinger = nil
            guard !session.isLive else { return }
            let duration: Double = session.clock.snap.duration
            let plan = PhoneScrubPreview.plan(url: session.playURL, headers: session.playHeaders, engine: session.engine, duration: duration)
            preview.prepare(key: plan.key, duration: duration, config: plan.config, make: plan.make)
            preview.update(new)
        } else if let old, PlayerFixtures.hudHideAfter != nil {
            scrubLinger = old
            lingerTask?.cancel()
            lingerTask = Task {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                scrubLinger = nil
                preview.update(nil)
            }
        } else {
            preview.update(nil)
        }
    }

    // MARK: the engine

    /// As the TV's PlayerScreen: the engine view is built once the session knows where to start, and
    /// rebuilt (its id) by a retry or an engine move. Under UI-test fixtures a stand-in plays instead.
    @ViewBuilder var engineLayer: some View {
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

    /// A new engine (a retry, the move to mpv) keeps the pinch's choice and the Volume Boost.
    func applyFill(_ c: any PlayerEngineControlling) {
        if fill { c.setPictureFill(true) }
        if boost > 0 { c.setVolumeBoost(boost) }
    }

    // MARK: the stage's touches

    /// Nothing over the picture takes the touches the stage would: the prompts and cards have their
    /// own buttons.
    var stageLive: Bool {
        session.resumePending == nil && !session.leaveConfirm && !session.stillPrompt && !session.failed && !session.kidsLoading
    }

    /// The touch surface under the HUD (PhonePlayerStage). For VoiceOver it is the seek slider
    /// (bp-player-scrub role="slider"), as the TV's stage is, and activating it toggles the HUD.
    var stage: some View {
        PhonePlayerStage(isLive: session.isLive, handlers: .init(
            tap: { toggleHUD() },
            doubleTap: { x, w in doubleTap(x: x, width: w) },
            hold: { on, _, _ in if on { startHold() } else { endHold() } },
            dragBegan: { kind in dragBegan(kind) },
            dragMoved: { kind, t, size in dragMoved(kind, t, size) },
            dragEnded: { kind, t, v, size in dragEnded(kind, t, v, size) },
            pinched: { scale in pinched(scale) }))
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
    func toggleHUD() {
        StillWatching.reset()
        if session.chromeShown {
            session.hideTask?.cancel()
            session.chrome = false
        } else {
            session.wake()
        }
    }

    /// One seek step back or ahead (the player prefs' steps, 10 s unless changed), as the HUD's buttons.
    func step(ahead: Bool) {
        let delta: Double = ahead ? session.prefs.seekForwardStepSec : -session.prefs.seekBackStepSec
        if session.isLive { session.controller?.seek(delta) } else { session.seekBy(delta) }
        session.wake()
    }

    /// A double tap on the left or right third steps back or ahead, with a ripple and the seconds on
    /// that side; the HUD stays as it was (its wait starts over when it is up). In the middle third it
    /// is a tap.
    func doubleTap(x: CGFloat, width: CGFloat) {
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
        flash = SeekFlash(side: side, seconds: shown, id: (flash?.id ?? 0) + 1)
        flashTask?.cancel()
        flashTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(PlayerFixtures.hudHideAfter != nil ? 4000 : 800))
            if !Task.isCancelled { flash = nil }
        }
    }

    func pinched(_ scale: CGFloat) {
        let next: Bool = PhonePlayerHUD.fill(afterPinch: scale, current: fill)
        guard next != fill else { return }
        setFill(next)
    }

    func setFill(_ next: Bool) {
        fill = next
        session.controller?.setPictureFill(next)
        PhoneFeedback.shared.tap()
    }

    func setBoost(_ percent: Int) {
        boost = percent
        session.controller?.setVolumeBoost(percent)
        PhoneFeedback.shared.selection()
    }

    // MARK: press and hold for 2x

    /// A press and hold on the left or right third: 2x while the finger stays, the session's own speed
    /// (and the show's remembered one) untouched. Only while playing.
    func startHold() {
        guard !session.isLive, !session.isPaused, let c = session.controller else { return }
        StillWatching.reset()
        holdTask?.cancel()
        c.setRate(PhonePlayerTouch.holdRate)
        holding = true
        PhoneFeedback.shared.tap()
    }

    /// The finger lifted: back to the speed it played at. Under fixtures the pill stays a while, so a
    /// screenshot taken after the test's press still shows it.
    func endHold() {
        guard holding else { return }
        session.controller?.setRate(session.rate)
        holdTask?.cancel()
        let linger: Double? = PlayerFixtures.hudHideAfter != nil ? 6 : nil
        guard let linger else { holding = false; return }
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(linger))
            if !Task.isCancelled { holding = false }
        }
    }

    // MARK: the drags

    func dragBegan(_ kind: PhonePlayerTouch.Drag) {
        StillWatching.reset()
        switch kind {
        case .brightness:
            brightness.begin()
            levelStart = brightness.level
            showLevel(.brightness)
        case .volume:
            levelStart = volume.level
            showLevel(.volume)
        case .scrub, .close, .undecided:
            break
        }
    }

    func dragMoved(_ kind: PhonePlayerTouch.Drag, _ t: CGSize, _ size: CGSize) {
        switch kind {
        case .scrub:
            session.scrubSwipe(t.width / max(1, size.width))
        case .brightness:
            brightness.set(PhonePlayerTouch.level(from: levelStart, translationY: t.height, height: size.height))
        case .volume:
            volume.set(PhonePlayerTouch.level(from: levelStart, translationY: t.height, height: size.height))
        case .close:
            pull = max(0, t.height)
        case .undecided:
            break
        }
    }

    func dragEnded(_ kind: PhonePlayerTouch.Drag, _ t: CGSize, _ v: CGPoint, _ size: CGSize) {
        switch kind {
        case .scrub:
            session.scrubSwipeEnded()
        case .brightness, .volume:
            hideLevelSoon()
        case .close:
            let closes: Bool = PhonePlayerTouch.closes(translationY: t.height, velocityY: v.y, height: size.height)
            withAnimation(PhoneMotion.reduced ? nil : .spring(duration: 0.3)) { pull = 0 }
            if closes {
                PhoneFeedback.shared.tap()
                session.requestClose()
            }
        case .undecided:
            break
        }
    }

    func showLevel(_ l: PhonePlayerLevel) {
        levelTask?.cancel()
        levelShown = l
    }

    /// The level's pill goes a moment after the finger lifts (a while longer under fixtures, for the
    /// screenshots).
    func hideLevelSoon() {
        levelTask?.cancel()
        let after: Double = PlayerFixtures.hudHideAfter != nil ? 6 : 0.9
        levelTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(after))
            if !Task.isCancelled { levelShown = nil }
        }
    }

    // MARK: Picture in Picture and AirPlay

    var pipAction: PhonePlayerSystem.PiPAction {
        PhonePlayerSystem.pipAction(engine: session.engine, supported: session.controller?.supportsPictureInPicture ?? true,
                                    active: session.pipActive)
    }

    func pipPressed() {
        switch pipAction {
        case .start: session.controller?.startPictureInPicture()
        case .stop: session.controller?.stopPictureInPicture()
        case .offerNative: offer = .pictureInPicture
        case .hidden: break
        }
    }

    func airPlayPressed() {
        switch PhonePlayerSystem.airPlayAction(engine: session.engine) {
        case .picker: routes.present()
        case .offerNative: offer = .airPlay
        }
    }

    /// The tab bar's accessory follows the floating picture (PhoneMiniState). A cover keeps the
    /// session in front, so there the player's own placard is what the viewer sees on coming back; the
    /// overlay steps aside instead (and the screen turns upright for browsing).
    func pipChanged(_ on: Bool) {
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
    func pipClosedByViewer() {
        guard hoisted else { return }
        session.controller?.setPaused(true)
        session.finish(natural: false)
    }

    /// While the picture floats a cover shows this instead of it: what is playing, and a way back.
    var pipPlacard: some View {
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
    func backgroundPill(_ note: String) -> some View {
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

    // MARK: the panels

    /// The HUD's panel buttons: what a title gets is PhonePlayerPanel.shown.
    var panelFacts: PhonePlayerPanel.Facts {
        let canReopen: Bool = !session.isLive && session.tuned == nil && !session.isKid && session.onSwitchSource != nil
        let xray: Bool = settings.slice.xrayEnabled == true && session.context?.meta != nil && !session.isLive
        return PhonePlayerPanel.Facts(isLive: session.isLive, hasHomeServer: session.context?.homeServer != nil,
                                      sources: PhonePlayerPanel.sourcesRoute(canSwitchInPlace: session.canSwitchInPlace, canReopen: canReopen),
                                      xray: xray, isKid: session.isKid)
    }

    /// A press on a panel button: the session's panels go through `session.open` (so the shared Sources
    /// swap and the HUD hiding work as on the TV); stats and X-Ray are the view's own.
    func openPanel(_ p: PhonePlayerPanel) {
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
    var panelBinding: Binding<PhonePlayerPanel?> {
        Binding(get: { session.panel.flatMap { PhonePlayerPanel($0) } ?? local },
                set: { if $0 == nil { dismissPanel() } })
    }

    func dismissPanel() {
        local = nil
        if session.panel != nil { session.closePanel() } else { session.wake() }
        refreshPicks()
    }

    /// The audio and subtitle tracks that are on, for the buttons' values.
    func refreshPicks() {
        let tracks: [MPVPlayerController.Track] = session.controller?.tracks() ?? []
        let a: String? = PhoneTrackText.onLabel(tracks, type: "audio")
        let s: String? = PhoneTrackText.onLabel(tracks, type: "sub")
        if a != audioOn { audioOn = a }
        if s != subOn { subOn = s }
    }

    /// switcher-row.tsx isCurrentStream's inputs (the TV's PlayerScreen.currentSource): the URL playing and
    /// the picked stream's ref, else the local torrent the URL names.
    var currentSource: PlayingSource {
        let ref: AnyJSON? = session.switched != nil ? session.switched?.ref : session.pick?.streamRef
        let torrent = TorrentEngine.streamRef(session.playURL)
        let hash: String? = ref?["infoHash"]?.string ?? torrent?.infoHash
        var idx: Int? = torrent?.fileIdx
        if let n = ref?["fileIdx"]?.number, n.isFinite, n >= 0 { idx = clampedInt(n) }
        return PlayingSource(url: session.playURL.absoluteString, streamURL: ref?["url"]?.string, infoHash: hash, fileIdx: idx)
    }

    // MARK: lock controls

    func lockControls() {
        lock.lock()
        lockTask?.cancel()
        session.hideTask?.cancel()
        PhoneFeedback.shared.tap()
    }

    /// A touch on the locked player: only the Unlock button comes up, for a few seconds.
    func touchedLocked() {
        lock.touched()
        lockTask?.cancel()
        lockTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(PlayerFixtures.hudHideAfter ?? PhonePlayerLock.hintFor))
            if !Task.isCancelled { lock.hintExpired() }
        }
    }

    func unlockControls() {
        lockTask?.cancel()
        lock.unlock()
        PhoneFeedback.shared.tap()
        session.wake()
    }

    /// Over the picture while locked: it takes every touch (so nothing under it seeks, pauses or fills)
    /// and answers with the Unlock button. The cards and prompts stay above it.
    var lockLayer: some View {
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
}

/// The DisplayAwake holder of one phone player (the table holds it weakly).
final class PhoneAwakeToken {}
