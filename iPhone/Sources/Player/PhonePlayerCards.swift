import SwiftUI

/// PhonePlayerView's cards and cues, each the TV PlayerScreen's of the same name drawn for touch: the
/// skip pill and the up-next card (PlayerSession's cues), the resume fork, "Leave the movie?", the
/// source error, the connecting card (with the P2P readout), the no-audio warning, a kid's loader
/// and "Still watching?". The logic behind every button is the shared session's.
extension PhonePlayerView {
    // MARK: cues

    /// The up-next card (inside the lead) or the skip pill, kept clear of every prompt and card.
    @ViewBuilder var cueLayer: some View {
        if !session.leaveConfirm, session.resumePending == nil, !session.pipActive, !session.stillPrompt, !session.failed {
            if session.showUpNextCard, let upNext = session.upNext {
                upNextCard(upNext).slideOrFade(.trailing)
            } else if let seg = session.activeSkip {
                skipPill(seg).slideOrFade(.trailing)
            }
        }
    }

    /// Above the scrubber while the HUD is up, near the corner when it is not.
    private var cueBottom: CGFloat { session.chrome ? 104 : 24 }

    private func skipPill(_ seg: PlayerSession.SkipSegment) -> some View {
        let outroNext: Bool = session.isOutroNext(seg)
        // bp-skip-pill onDismiss: a real segment's pill carries a ✕ ("Hide this Skip button").
        let dismissKey: String? = session.displaySkip != nil && !outroNext ? session.skipButtonKey : nil
        return VStack {
            Spacer()
            HStack(spacing: 8) {
                Spacer()
                Button {
                    StillWatching.reset()
                    if outroNext { session.playNext(); return }
                    session.skipTo(seg.endSec)
                    session.wake()
                } label: {
                    Label(T(outroNext ? "Next Episode" : seg.label), systemImage: outroNext ? "chevron.forward.2" : "forward.fill")
                        .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                        .padding(.horizontal, 6).padding(.vertical, 4)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("player-skip")
                if let dismissKey {
                    Button {
                        session.skipDismissedKeys.insert(dismissKey)
                        session.wake()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(Text(T("Hide this Skip button")))
                    .accessibilityIdentifier("player-skip-dismiss")
                }
            }
            .padding(.bottom, cueBottom).padding(.trailing, PhoneTheme.margin)
        }
    }

    /// "S{season} E{episode}" of the episode that would play next (still-watching-prompt).
    var stillWatchingNextLabel: String? {
        guard session.context?.season != nil, let upNext = session.upNext else { return nil }
        return upNext.components(separatedBy: " · ").first
    }

    /// bp-up-next.tsx BpUpNext: the next episode, a countdown ring, "Play now" and "Keep watching".
    private func upNextCard(_ text: String) -> some View {
        let seconds: Int = Int(session.remainingSec.rounded(.up))
        let progress: Double = session.leadSec > 0 ? min(1, max(0, 1 - Double(seconds) / session.leadSec)) : 0
        let parts: [String] = text.components(separatedBy: " · ")
        let epLabel: String = parts.first ?? text
        let name: String = parts.dropFirst().joined(separator: " · ")
        let heading: String = name.isEmpty ? epLabel : name
        return VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(T("Up Next")).font(PhoneTheme.sans(11.5, .bold, relativeTo: .caption)).textCase(.uppercase).tracking(1.4)
                                .foregroundStyle(Color.white.opacity(0.6))
                            Text(verbatim: heading).font(PhoneTheme.display(18, relativeTo: .headline)).foregroundStyle(Color.white).lineLimit(2)
                            if heading != epLabel {
                                Text(verbatim: epLabel).font(PhoneTheme.sans(12, .medium, relativeTo: .caption)).foregroundStyle(Color.white.opacity(0.6)).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 10)
                        countdownRing(seconds: seconds, progress: progress)
                    }
                    HStack(spacing: 8) {
                        cardButton("upnext-play", "Play now", "play.fill", primary: true) { session.playNext() }
                        cardButton("upnext-keep", "Keep watching", "xmark") { session.cancelAutoNext() }
                    }
                    .padding(.top, 4)
                }
                .padding(16)
                .frame(width: 340, alignment: .leading)
                .phoneGlassPlate(radius: PhoneTheme.radiusLarge)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("player-upnext")
            }
            .padding(.bottom, cueBottom).padding(.trailing, PhoneTheme.margin)
        }
    }

    /// bp-up-next.tsx CountdownRing: whole seconds left, the ring filling toward the jump.
    private func countdownRing(seconds: Int, progress: Double) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 3).accessibilityHidden(true)
            Circle().trim(from: 0, to: progress)
                .stroke(BP.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .accessibilityHidden(true)
            Text(verbatim: "\(seconds)").font(PhoneTheme.sans(14, .bold, relativeTo: .footnote)).foregroundStyle(Color.white).monospacedDigit()
        }
        .frame(width: 40, height: 40)
        .motion(.linear(duration: 0.2), value: progress)
    }

    // MARK: cards

    /// A card's button: glass, or the accent's prominent glass for the one the card leads with.
    @ViewBuilder func cardButton(_ id: String, _ title: String, _ icon: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        let label = Label(T(title), systemImage: icon)
            .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
        if primary {
            Button(action: action) { label }
                .buttonStyle(.glassProminent)
                .tint(BP.accent)
                .accessibilityIdentifier(id)
        } else {
            Button(action: action) { label }
                .buttonStyle(.glass)
                .accessibilityIdentifier(id)
        }
    }

    /// A card centred over the dimmed picture.
    func card<Content: View>(_ id: String, width: CGFloat = 420, dim: Double = 0.55, @ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(dim).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) { content() }
                .foregroundStyle(Color.white)
                .padding(20)
                .frame(maxWidth: width, alignment: .leading)
                .phoneGlassPlate(radius: PhoneTheme.radiusLarge)
                .padding(PhoneTheme.margin)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(id)
        }
    }

    private func cardTitle(_ text: String) -> some View {
        Text(verbatim: text).font(PhoneTheme.display(22, relativeTo: .title2)).foregroundStyle(Color.white)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func cardLine(_ text: String) -> some View {
        Text(verbatim: text).font(PhoneTheme.sans(14, relativeTo: .subheadline)).foregroundStyle(Color.white.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// bp-resume-prompt.tsx: a fork over the paused first frame (settings.resumePrompt).
    func resumeCard(_ sec: Double) -> some View {
        PlayerClockReader(session.clock) { c in resumeFork(sec, duration: c.snap.duration) }
            .onAppear {
                session.controller?.setPaused(true)
                if let c = session.controller { session.takeSnap(c.snapshot()) }
            }
    }

    private func resumeFork(_ sec: Double, duration: Double) -> some View {
        let head: String = session.title + (session.subtitle.map { " · " + $0 } ?? "")
        let at: String = duration > 0 ? T("%@ of %@", PlayerClock.fmt(sec), PlayerClock.fmt(duration)) : PlayerClock.fmt(sec)
        return card("player-resume-card") {
            cardTitle(T("Pick up where you left off"))
            cardLine(head + " · " + at).lineLimit(2)
            if duration > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(BP.accent).frame(width: g.size.width * min(1, max(0, sec / duration)))
                    }
                }
                .frame(height: 5)
                .accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                cardButton("player-resume", "Pick up where you left off", "play.fill", primary: true) { session.acknowledgeResume(true); session.wake() }
                cardButton("player-startover", "Start over", "arrow.counterclockwise") { session.acknowledgeResume(false); session.wake() }
            }
            .padding(.top, 4)
        }
    }

    /// bp-leave-confirm.tsx: Keep watching / Leave / Don't ask again (settings.playerConfirmLeave).
    var leaveCard: some View {
        card("player-leave-card", width: 380) {
            cardTitle(T(session.context?.meta.type == "movie" ? "Leave the movie?" : "Leave the show?"))
            cardLine(T("We'll save your spot so you can pick up right where you left off."))
            HStack(spacing: 8) {
                cardButton("player-keep", "Keep watching", "play.fill", primary: true) { session.keepWatching() }
                cardButton("player-leave", "Leave", "rectangle.portrait.and.arrow.right") {
                    if session.leaveRemember { Task { try? await SettingsBridge.shared.patch(["playerConfirmLeave": .bool(false)]) } }
                    session.leaveConfirm = false
                    session.finish(natural: false)
                }
            }
            .padding(.top, 4)
            Toggle(isOn: $session.leaveRemember) {
                Text(T("Don't ask again")).font(PhoneTheme.sans(14, .medium, relativeTo: .subheadline))
            }
            .tint(BP.accent)
            .accessibilityIdentifier("player-leave-remember")
        }
    }

    /// The error's detail: the engine's, else the last log line that names a failure (the TV's
    /// sourceErrorDetail), so the card never says nothing.
    private var sourceErrorDetail: String? {
        if let e = session.endedEarly ?? session.status.error { return e }
        let needles: [String] = ["vo:", "vulkan", "moltenvk", "failed"]
        return session.status.log.last { line in
            let l: String = line.lowercased()
            return needles.contains { l.contains($0) }
        }
    }

    /// source-error-card.tsx: the stream would not open; another source, Try again, mpv, or back.
    var errorCard: some View {
        card("player-error", width: 460) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(BP.danger).accessibilityHidden(true)
                cardTitle(T("Harbor couldn't play this source"))
            }
            cardLine(T("The source responded but the stream would not open. Try a different one."))
            if let e = sourceErrorDetail {
                Text(verbatim: T("Source said") + ": " + e).font(PhoneTheme.sans(12, relativeTo: .caption)).foregroundStyle(Color.white.opacity(0.5)).lineLimit(2)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                // The phone has no in-place switcher yet: the picker opens again for this title.
                if session.onChooseAnother != nil {
                    cardButton("player-pick-another", "Pick another source", "list.bullet", primary: true) { chooseAnother() }
                }
                cardButton("player-retry", "Try again", "arrow.clockwise") { session.reloadSame() }
                if session.engine == .native { cardButton("player-use-mpv", "Use mpv engine", "play.rectangle") { session.useMpvEngine() } }
                cardButton("player-error-back", "Back", "chevron.backward") { session.finish(natural: false) }
            }
            .padding(.top, 4)
        }
        .onAppear { session.hideTask?.cancel() }
    }

    private func chooseAnother() {
        guard let go = session.onChooseAnother else { return }
        session.finish(natural: false, reopening: true)
        go()
    }

    /// bp-connecting: while the stream is still opening, the elapsed time (or the P2P readout) and,
    /// after 8 s, the ways out.
    var connectingCard: some View {
        let elapsed: Int = Int(Date().timeIntervalSince(session.loadingSince))
        return card("player-connecting", width: 440, dim: 0.35) {
            HStack(spacing: 10) {
                ProgressView().tint(Color.white).accessibilityHidden(true)
                cardTitle(T("Connecting…"))
            }
            if TorrentEngine.streamRef(session.playURL) != nil {
                PhoneTorrentReadout(url: session.playURL)
            } else {
                cardLine(elapsed >= 22 ? T("Still looking. Some sources take a while to answer.") : T("The player is opening the stream. %lld s", elapsed))
            }
            if elapsed >= 8 {
                HStack(spacing: 8) {
                    cardButton("connecting-back", "Go back", "chevron.backward") { session.finish(natural: false) }
                    cardButton("connecting-retry", "Try again", "arrow.clockwise") { session.reloadSame() }
                    if session.onSwitchSource != nil {
                        cardButton("connecting-switch", "Switch source", "list.bullet") {
                            let go = session.onSwitchSource
                            let at: Double = session.switchSpot
                            session.finish(natural: false, reopening: true)
                            go?(at)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    /// cinematic-player-loader.tsx for a kid, kept plain: the title and a way back until the first frame.
    var kidsLoader: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(Color.white).controlSize(.large).accessibilityHidden(true)
                Text(verbatim: session.shownTitle).font(PhoneTheme.display(22, relativeTo: .title2)).foregroundStyle(Color.white)
                HStack(spacing: 8) {
                    cardButton("kids-cancel", "Go back", "chevron.backward") { session.finish(natural: false) }
                    cardButton("kids-retry", "Try again", "arrow.clockwise") { session.reloadSame() }
                }
                .frame(maxWidth: 320)
            }
            .padding(PhoneTheme.margin)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-kids-loader")
    }

    /// header-warning.tsx NoAudioWarning, over the picture above the scrubber.
    var noAudioCard: some View {
        VStack {
            Spacer()
            VStack(spacing: 10) {
                Text(T("No audio: this stream's audio format (likely Dolby or DTS) is not supported by the AVPlayer engine."))
                    .font(PhoneTheme.sans(14, .medium, relativeTo: .subheadline)).foregroundStyle(Color.white).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    cardButton("player-noaudio-mpv", "Use mpv engine", "play.rectangle", primary: true) { session.useMpvEngine() }
                    cardButton("player-noaudio-dismiss", "Dismiss", "xmark") { session.noAudioWarning = false }
                }
            }
            .padding(16)
            .frame(maxWidth: 440)
            .phoneGlassPlate(radius: PhoneTheme.radiusLarge)
            .padding(.bottom, session.chrome ? 84 : 20)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player-noaudio")
        }
        .frame(maxWidth: .infinity)
    }
}

/// player.tsx StillWatchingPrompt on the phone: "Still watching?" with Keep watching and a 45 s
/// Stop countdown, which closes the player when it runs out (the TV's StillWatchingPrompt).
struct PhoneStillWatching: View {
    let show: String
    var nextLabel: String? = nil
    let onContinue: () -> Void
    let onExit: () -> Void

    private static let timeoutSec = 45
    @State private var secs = PhoneStillWatching.timeoutSec
    @State private var fired = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 8) {
                Text(T("Still watching?")).font(PhoneTheme.display(24, relativeTo: .title2)).foregroundStyle(Color.white)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: nextLabel.map { "\(show) · \($0)" } ?? show)
                    .font(PhoneTheme.sans(14, relativeTo: .subheadline)).foregroundStyle(Color.white.opacity(0.72))
                    .multilineTextAlignment(.center).lineLimit(2)
                HStack(spacing: 8) {
                    Button { exitOnce(continuing: true) } label: {
                        Text(T("Keep watching")).font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline)).frame(maxWidth: .infinity).padding(.vertical, 3)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(BP.accent)
                    .accessibilityIdentifier("still-continue")
                    Button { exitOnce(continuing: false) } label: {
                        Text(T("Stop (%lld)", secs)).font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline)).monospacedDigit()
                            .frame(maxWidth: .infinity).padding(.vertical, 3)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("still-stop")
                }
                .padding(.top, 12)
            }
            .padding(22)
            .frame(maxWidth: 400)
            .phoneGlassPlate(radius: PhoneTheme.radiusLarge)
            .padding(PhoneTheme.margin)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-still-watching")
        // The countdown lives with the prompt (the TV's: a timer publisher rebuilt with the player
        // would never get to fire).
        .task {
            while secs > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                secs -= 1
            }
            exitOnce(continuing: false)
        }
    }

    /// Continue, Stop and the countdown can land together; the player moves on once.
    private func exitOnce(continuing: Bool) {
        guard !fired else { return }
        fired = true
        if continuing { onContinue() } else { onExit() }
    }
}

/// bp-p2p-status.tsx on the phone's connecting card: the meter, the stage, "peers · speed · bytes"
/// and bp-connecting's notes, from the shared TorrentReadoutModel the TV's readout draws too.
struct PhoneTorrentReadout: View {
    let url: URL
    @State private var model = TorrentReadoutModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    if model.pct >= 1 {
                        Capsule().fill(Color.white).frame(width: g.size.width * model.pct / 100)
                            .motion(.linear(duration: 1.9), value: model.pct)
                    } else {
                        Capsule().fill(Color.white.opacity(0.6)).frame(width: g.size.width * 0.2)
                    }
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline) {
                Text(T(model.label(buffering: false))).font(PhoneTheme.sans(13, .bold, relativeTo: .footnote)).textCase(.uppercase).tracking(1.6)
                Spacer(minLength: 8)
                if model.pct >= 1 { Text(verbatim: "\(Int(model.pct.rounded()))%").font(PhoneTheme.sans(14, .semibold, relativeTo: .footnote)).monospacedDigit() }
            }
            .foregroundStyle(Color.white)
            if !model.parts.isEmpty {
                Text(verbatim: model.parts.joined(separator: " · ")).font(PhoneTheme.sans(13, .medium, relativeTo: .footnote)).monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.72))
            }
            if let note = model.note(buffering: false) {
                Text(T(note)).font(PhoneTheme.sans(12.5, relativeTo: .caption)).foregroundStyle(Color.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let heavy = model.heavyNote {
                Text(T(heavy)).font(PhoneTheme.sans(12.5, relativeTo: .caption)).foregroundStyle(Color.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player-p2p")
        .task(id: url) { await TorrentReadoutModel.poll(url: url, update: { model = $0 }) }
    }
}
