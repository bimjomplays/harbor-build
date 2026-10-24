import SwiftUI


/// A leaf that observes the playback clock and draws `content` from it, so a tick
/// redraws this view alone and not the player around it.
struct PlayerClockReader<Content: View>: View {
    @ObservedObject private var clock: PlayerClock
    private let content: (PlayerClock) -> Content

    init(_ clock: PlayerClock, @ViewBuilder content: @escaping (PlayerClock) -> Content) {
        _clock = ObservedObject(wrappedValue: clock)
        self.content = content
    }

    var body: some View { content(clock) }
}

/// bp-player-scrub.tsx role="slider" aria-valuetext={fmtTime(position)}: the stage's
/// VoiceOver value, read from the clock inside this modifier so the player's body does not observe it.
struct PlayerSeekValue: ViewModifier {
    @ObservedObject var clock: PlayerClock
    let isLive: Bool
    let pending: Double?

    func body(content: Content) -> some View {
        let position: Double = pending ?? clock.snap.position
        let value: String = isLive ? "" : PlayerClock.fmt(position)
        return content.accessibilityValue(Text(verbatim: value))
    }
}

/// A leaf that observes the app-wide sleep timer (its minutes countdown publishes
/// every second) for the Speed & sleep control's face; the player's body no longer observes it.
struct PlayerSleepReader<Content: View>: View {
    @ObservedObject private var timer: SleepTimer
    private let content: (SleepTimer) -> Content

    init(@ViewBuilder content: @escaping (SleepTimer) -> Content) {
        _timer = ObservedObject(wrappedValue: SleepTimer.shared)
        self.content = content
    }

    var body: some View { content(timer) }
}
