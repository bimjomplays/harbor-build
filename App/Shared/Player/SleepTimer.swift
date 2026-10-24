import SwiftUI
import Combine

/// lib/sleep-timer-store.ts: one timer for the whole app. "minutes" pauses the player when it runs
/// out; "End of episode" / "End of next episode" stop playback at a natural end (use-sleep-timer.ts).
@MainActor
final class SleepTimer: ObservableObject {
    static let shared = SleepTimer()

    /// sleep-timer-store.ts SleepMode.
    enum Mode: Equatable {
        case off
        case minutes(total: Int, firesAt: Date)
        case endEpisode
        case endNextEpisode(remaining: Int)
    }

    @Published private(set) var mode: Mode = .off
    /// useSleepRemainingMs, in seconds: what is left on a minutes timer (nil otherwise).
    @Published private(set) var remainingSec: Double?
    private var tick: Timer?
    private var fireHandler: (owner: UUID, run: () -> Void)?
    /// use-sleep-timer.ts lastUrlRef: the stream the player last opened (nil after a close that
    /// did not move on to another episode, like a fresh mount upstream).
    private var lastURL: URL?

    var isActive: Bool { mode != .off }

    /// setSleepMode.
    func set(_ next: Mode) {
        switch next {
        case .minutes(let total, _):
            mode = .minutes(total: total, firesAt: Date().addingTimeInterval(Double(total) * 60))
            startTick()
        case .endNextEpisode(let remaining):
            stopTick()
            remainingSec = nil
            mode = .endNextEpisode(remaining: max(1, remaining))
        case .off, .endEpisode:
            stopTick()
            remainingSec = nil
            mode = next
        }
    }

    /// clearSleepMode.
    func clear() {
        stopTick()
        mode = .off
        remainingSec = nil
    }

    /// registerSleepFireHandler: the playing player pauses when a minutes timer runs out.
    func register(_ owner: UUID, _ run: @escaping () -> Void) { fireHandler = (owner, run) }
    func unregister(_ owner: UUID) { if fireHandler?.owner == owner { fireHandler = nil } }

    /// use-sleep-timer.ts srcUrl effect: another stream in the player drops "End of episode".
    func playerOpened(url: URL) {
        if let last = lastURL, last != url, mode == .endEpisode { clear() }
        lastURL = url
    }

    /// The player closed; `advancing` when the next (or previous) episode opens next.
    func playerClosed(advancing: Bool) {
        if !advancing { lastURL = nil }
    }

    /// use-sleep-timer.ts status "ended": true when the timer ends playback here ("End of episode",
    /// or the last episode of "End of next episode"); "End of next episode" counts one down.
    func episodeEnded() -> Bool {
        switch mode {
        case .endEpisode:
            clear()
            return true
        case .endNextEpisode(let remaining):
            if remaining > 1 {
                mode = .endNextEpisode(remaining: remaining - 1)
                return false
            }
            clear()
            return true
        case .off, .minutes:
            return false
        }
    }

    private func startTick() {
        stopTick()
        step()
        guard case .minutes = mode else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { @Sendable [weak self] _ in
            Task { @MainActor in self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func stopTick() {
        tick?.invalidate()
        tick = nil
    }

    private func step() {
        guard case .minutes(_, let firesAt) = mode else { stopTick(); return }
        let r = firesAt.timeIntervalSinceNow
        remainingSec = max(0, r)
        if r <= 0 {
            stopTick()
            mode = .off
            remainingSec = nil
            fireHandler?.run()
        }
    }

    // speed-menu.tsx labels

    /// speed-menu.tsx formatRemaining: m:ss.
    static func formatRemaining(_ sec: Double) -> String {
        let s = max(0, Int(sec.rounded()))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// speed-menu.tsx sleepMinuteLabel.
    static func minuteLabel(_ m: Int) -> String {
        if m >= 60 && m % 60 == 0 { return T("%lld hr", m / 60) }
        return T("%lld min", m)
    }

    /// speed-menu.tsx sleepLabel: what the control's face shows while a timer is armed.
    var faceLabel: String? {
        switch mode {
        case .off: return nil
        case .minutes: return remainingSec.map { Self.formatRemaining($0) }
        case .endEpisode: return T("End ep")
        case .endNextEpisode(let n): return T("+%lld ep", n)
        }
    }
}
