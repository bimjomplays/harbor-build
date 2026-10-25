import SwiftUI

/// The double tap's mark: the side it stepped and the seconds stepped (summed over quick repeats);
/// `id` grows with every tap, so each one ripples again.
struct SeekFlash: Equatable {
    var side: PhonePlayerHUD.Side
    var seconds: Double
    var id: Int
}

/// Which level a swipe is moving.
enum PhonePlayerLevel: Equatable { case brightness, volume }

/// PhonePlayerView's HUD, laid out like Infuse's: in the top corners a glass circle to close and a
/// glass capsule with fit / fill and Picture in Picture, and the volume capsule; in the middle the
/// plain skip and play icons; at the foot the title, a glass capsule with the gear menu, AirPlay and the
/// lock, and the bar with the times under it.
extension PhonePlayerView {
    /// The HUD's sizes, from Infuse on a 6.9" iPhone (points).
    enum Metrics {
        static let side: CGFloat = 13
        static let top: CGFloat = 28
        static let bottom: CGFloat = 10
        static let control: CGFloat = 39
        static let transportGap: CGFloat = 88
    }

    var hud: some View {
        ZStack {
            // A light dim over the picture, deeper at the foot under the title and the bar.
            LinearGradient(stops: [.init(color: Color.black.opacity(0.22), location: 0), .init(color: Color.black.opacity(0.06), location: 0.25),
                                   .init(color: Color.black.opacity(0.06), location: 0.6), .init(color: Color.black.opacity(0.5), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            transport
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                topRow
                Spacer(minLength: 0)
                bottomBlock
            }
            .padding(.horizontal, Metrics.side)
            .padding(.top, Metrics.top)
            .padding(.bottom, Metrics.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-hud")
    }

    // MARK: top

    private var topRow: some View {
        HStack(alignment: .center, spacing: 9) {
            Button { hudPress { session.requestClose() } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.white)
                    .frame(width: Metrics.control, height: Metrics.control)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.clear.interactive(), in: .circle)
            .accessibilityLabel(Text(T("Close")))
            .accessibilityIdentifier("player-close")
            HStack(spacing: 0) {
                capsuleIcon("player-fill", fill ? "rectangle.arrowtriangle.2.inward" : "rectangle",
                            label: T(fill ? "Fit the screen" : "Fill the screen"), size: 19) { setFill(!fill) }
                if pipAction != .hidden {
                    capsuleIcon("player-pip", pipAction == .stop ? "pip.exit" : "pip.enter", label: T("Picture in Picture"), size: 19) { pipPressed() }
                }
            }
            .padding(.horizontal, 2)
            .glassEffect(.clear.interactive(), in: .capsule)
            Spacer(minLength: 12)
            volumeCapsule
        }
    }

    /// A volume swipe with the HUD away: the capsule alone in its corner.
    var volumeAlone: some View {
        VStack {
            HStack {
                Spacer()
                volumeCapsule
            }
            Spacer()
        }
        .padding(.horizontal, Metrics.side)
        .padding(.top, Metrics.top)
    }

    /// "40%", the level's bar and a speaker: a finger on the bar sets the phone's volume.
    var volumeCapsule: some View {
        let level: Double = volume.level
        let filled: CGFloat = CGFloat(min(1, max(0, level)))
        return HStack(spacing: 10) {
            Text(verbatim: PhonePlayerTouch.percent(level))
                .font(.system(size: 18, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: 46, alignment: .leading)
                .accessibilityIdentifier("player-volume-value")
            GeometryReader { g in
                let w: CGFloat = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.28)).frame(height: 4)
                    Capsule().fill(Color.white).frame(width: max(4, w * filled), height: 4)
                    Circle().fill(Color.white).frame(width: 11, height: 11)
                        .shadow(color: Color.black.opacity(0.25), radius: 2)
                        .position(x: min(max(5.5, w * filled), w - 5.5), y: g.size.height / 2)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            session.hideTask?.cancel()
                            volume.set(Double(v.location.x / max(1, w)))
                        }
                        .onEnded { _ in session.wake() }
                )
            }
            .frame(width: 108, height: Metrics.control)
            .environment(\.layoutDirection, .leftToRight)
            Image(systemName: PhonePlayerTouch.speakerGlyph(level))
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 26, alignment: .leading)
                .accessibilityHidden(true)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: Metrics.control)
        .glassEffect(.clear.interactive(), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(T("Volume")))
        .accessibilityValue(Text(verbatim: PhonePlayerTouch.percent(level)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: volume.set(level + 0.0625)
            case .decrement: volume.set(level - 0.0625)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("player-volume")
    }

    // MARK: middle

    /// Back, play / pause and ahead: plain white icons, no plates.
    var transport: some View {
        HStack(spacing: 0) {
            if !session.isLive {
                plainIcon("player-back", "gobackward", label: T("Back %llds", Int(session.prefs.seekBackStepSec)), size: 25) { step(ahead: false) }
            }
            plainIcon("player-playpause", session.isPaused ? "play.fill" : "pause.fill",
                      label: T(session.isPaused ? "Play" : "Pause"), size: session.isPaused ? 44 : 37) { session.togglePause() }
            if !session.isLive {
                plainIcon("player-ahead", "goforward", label: T("Forward %llds", Int(session.prefs.seekForwardStepSec)), size: 25) { step(ahead: true) }
            }
        }
    }

    private func plainIcon(_ id: String, _ icon: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button { hudPress(action) } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(Color.white)
                .shadow(color: Color.black.opacity(0.35), radius: 6)
                .frame(width: Metrics.transportGap, height: 72)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
    }

    // MARK: foot

    private var bottomBlock: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                titleLine
                Spacer(minLength: 0)
                bottomCapsule
            }
            .frame(height: Metrics.control)
            if !session.isLive {
                PlayerClockReader(session.clock) { c in scrubber(c) }
                    .padding(.top, 6.5)
            }
        }
    }

    /// The title in bold, the episode after it in a lighter weight, on one line.
    private var titleLine: some View {
        HStack(spacing: 0) {
            Text(verbatim: session.shownTitle)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .layoutPriority(1)
                .accessibilityIdentifier("player-title")
            if let s = session.shownSubtitle, !s.isEmpty {
                Text(verbatim: "  " + s)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
                    .accessibilityIdentifier("player-subtitle")
            }
        }
        .shadow(color: Color.black.opacity(0.4), radius: 8, y: 1)
    }

    /// The gear menu, AirPlay and the lock (Harbor has no cast; the lock takes its place).
    private var bottomCapsule: some View {
        HStack(spacing: 0) {
            PhonePlayerGearButton(items: { gearItems() }, onOpen: { menuOpened($0) }, label: T("Settings"),
                                  value: (audioOn ?? T("None")) + ", " + (subOn ?? T("Off")))
                .frame(width: 43, height: Metrics.control)
            capsuleIcon("player-airplay", "airplayvideo", label: T("AirPlay"), size: 19) { airPlayPressed() }
            capsuleIcon("player-lock", "lock", label: T("Lock controls"), size: 18) { lockControls() }
        }
        .padding(.horizontal, 3)
        .glassEffect(.clear.interactive(), in: .capsule)
    }

    /// The gear menu opened (the HUD stays while it is up) or went (its wait starts over).
    func menuOpened(_ on: Bool) {
        StillWatching.reset()
        menuOpen = on
        if on {
            session.hideTask?.cancel()
            PhoneFeedback.shared.tap()
        } else {
            session.wake()
            refreshPicks()
        }
    }

    /// An icon in a glass capsule.
    private func capsuleIcon(_ id: String, _ icon: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button { hudPress(action) } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(Color.white)
                .frame(width: 43, height: Metrics.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
    }

    /// Any HUD press restarts the HUD's wait.
    private func hudPress(_ action: () -> Void) {
        StillWatching.reset()
        action()
        if !session.leaveConfirm { session.wake() }
    }

    /// bp-player-scrub.tsx on the phone: a thin bar (played over buffered), the times under it. A finger
    /// on the bar (or a sideways drag on the picture) moves a pending spot, drawn with a knob and a time
    /// bubble over it, that lands when it lifts. No trickplay thumbnail: neither engine gives one.
    func scrubber(_ c: PlayerClock) -> some View {
        let duration: Double = c.snap.duration
        let shown: Double = session.pendingSeek ?? c.snap.position
        let labels = PhonePlayerHUD.labels(position: c.snap.position, duration: duration, pending: session.pendingSeek)
        let played: CGFloat = CGFloat(PhonePlayerHUD.barFraction(position: shown, duration: duration))
        let buffered: CGFloat = CGFloat(PhonePlayerHUD.barFraction(position: max(c.buffered, shown), duration: duration))
        let dragging: Bool = session.pendingSeek != nil
        let bar: CGFloat = dragging ? 8 : 5
        return VStack(spacing: 0) {
            GeometryReader { g in
                let w: CGFloat = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.24)).frame(height: bar)
                    Capsule().fill(Color.white.opacity(0.5)).frame(width: max(bar, w * buffered), height: bar)
                    Capsule().fill(Color.white).frame(width: max(bar, w * played), height: bar)
                    if dragging {
                        Circle().fill(Color.white)
                            .frame(width: 16, height: 16)
                            .shadow(color: Color.black.opacity(0.35), radius: 3, y: 1)
                            .position(x: w * played, y: g.size.height / 2)
                        Text(verbatim: PlayerClock.fmt(shown))
                            .font(.system(size: 15, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .glassEffect(.regular, in: .capsule)
                            .fixedSize()
                            .position(x: min(max(w * played, 36), max(36, w - 36)), y: -22)
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
            .frame(height: 20)
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
            HStack {
                Text(verbatim: labels.elapsed).accessibilityIdentifier("player-elapsed")
                Spacer()
                Text(verbatim: labels.remaining).accessibilityIdentifier("player-remaining")
            }
            .font(.system(size: 13, weight: .regular))
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.55))
            .frame(height: 16)
        }
        // The bar draws from the physical left under right-to-left too (bp-player-scrub.tsx).
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: the pills

    /// Top centre: the brightness while a left-half swipe moves it, "2x" while a press and hold plays fast.
    var topPills: some View {
        VStack {
            HStack(spacing: 10) {
                if levelShown == .brightness {
                    HStack(spacing: 22) {
                        Image(systemName: "sun.max").font(.system(size: 25, weight: .regular)).accessibilityHidden(true)
                        Text(verbatim: PhonePlayerTouch.percent(brightness.level))
                            .font(.system(size: 15, weight: .medium)).monospacedDigit()
                            .frame(minWidth: 38, alignment: .leading)
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 24)
                    .frame(height: 46)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(T("Brightness")))
                    .accessibilityValue(Text(verbatim: PhonePlayerTouch.percent(brightness.level)))
                    .accessibilityIdentifier("player-brightness-pill")
                }
                if holding {
                    HStack(spacing: 6) {
                        Image(systemName: "forward.fill").font(.system(size: 13, weight: .semibold)).accessibilityHidden(true)
                        Text(verbatim: String(format: "%gx", PhonePlayerTouch.holdRate)).font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(T("Playing at 2x")))
                    .accessibilityIdentifier("player-rate-pill")
                }
            }
            .padding(.top, 17)
            Spacer()
        }
        .allowsHitTesting(false)
    }
}

/// The double tap's mark: a soft ripple on the side it stepped, with the seconds stepped.
struct PhoneSeekRipple: View {
    let flash: SeekFlash
    @State private var grown = false

    var body: some View {
        GeometryReader { g in
            let back: Bool = flash.side == .back
            ZStack {
                Circle()
                    .fill(Color.white.opacity(grown ? 0 : 0.2))
                    .frame(width: 160, height: 160)
                    .scaleEffect(grown ? 1.25 : 0.35)
                VStack(spacing: 4) {
                    Image(systemName: back ? "backward.fill" : "forward.fill").font(.system(size: 17, weight: .semibold))
                    Text(verbatim: "\(Int(flash.seconds.rounded()))s").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                }
                .foregroundStyle(Color.white)
                .shadow(color: Color.black.opacity(0.45), radius: 6)
            }
            .position(x: g.size.width * (back ? 0.17 : 0.83), y: g.size.height / 2)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(PhoneMotion.reduced ? nil : .easeOut(duration: 0.65)) { grown = true }
        }
        .accessibilityHidden(true)
    }
}
