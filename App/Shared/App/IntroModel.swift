import SwiftUI

/// use-bp-intro.ts: when the poster-wall front door leaves. It shows for at least 5 s and at most
/// 8 s counted from the first splash (app launch), but never less than 3.5 s after it mounts;
/// it leaves as soon as the rows behind it have arrived (after the floor), and any press skips
/// it. The fade is 620 ms.
@MainActor
final class IntroModel: ObservableObject {
    enum Phase { case showing, leaving, done }
    /// Starts as `.showing` so the wall is on screen in the same frame the boot splash leaves;
    /// the timers only run from `start()`. UI-test fixtures pass `enabled: false`.
    @Published private(set) var phase: Phase
    /// The wall's posters, frozen at the first render so the mosaic never reshuffles mid-intro.
    @Published private(set) var posters: [String] = []

    /// Whether the wall still blocks input, mirrored statically: RootView owns the
    /// one instance as a `@StateObject`, and a link waiting for the shell to be reachable
    /// (AppModel.shellReachable) has no reference to it. Only `.showing` disables the tree below
    /// (RootView `.disabled(phase == .showing)`); `.leaving`'s fade does not, so a link may show then.
    private(set) static var wallShowing = true

    private static let minVisible: TimeInterval = 5, maxVisible: TimeInterval = 8
    private static let minAfterMount: TimeInterval = 3.5, fade: TimeInterval = 0.62
    /// bp-intro.tsx COLUMNS × PER_COLUMN.
    static let columns = 8, perColumn = 6

    private let launchedAt = Date()
    private var mountedAt = Date()
    private var started = false
    private var left = false
    private var cap: Task<Void, Never>?
    private var leaveTimer: Task<Void, Never>?

    init(enabled: Bool) {
        phase = enabled ? .showing : .done
        Self.wallShowing = enabled
    }

    /// bp-shell mounts the intro once per session, the moment Big Picture is up (here: the boot
    /// splash hands over to onboarding, who's watching or the shell).
    func start() {
        guard phase == .showing, !started else { return }
        started = true
        mountedAt = Date()
        let openedFor = Date().timeIntervalSince(launchedAt)
        let capIn = max(Self.minAfterMount, Self.maxVisible - openedFor)
        cap = Task { [weak self] in
            try? await Task.sleep(for: .seconds(capIn))
            guard !Task.isCancelled else { return }
            self?.beginLeave()
        }
    }

    /// bp-intro.tsx: live posters when there are enough, else the ones remembered from last session.
    func offer(live: [String]) {
        guard phase == .showing, posters.count < Self.columns * 2 else { return }
        freeze(live)
    }

    private func freeze(_ urls: [String]) {
        guard posters.count < Self.columns * 2, urls.count >= Self.columns * 2 else { return }
        var shuffled = urls
        // bp-intro.tsx's deterministic shuffle (Knuth's multiplicative hash), no RNG.
        if shuffled.count > 1 {
            for i in stride(from: shuffled.count - 1, to: 0, by: -1) {
                let j = Int((UInt64(i) &* 2654435761) % UInt64(i + 1))
                shuffled.swapAt(i, j)
            }
        }
        posters = Array(shuffled.prefix(Self.columns * Self.perColumn))
    }

    /// contentReady: wait out the floor, then leave.
    func contentReady() {
        guard phase == .showing, started, leaveTimer == nil else { return }
        let waited = Date().timeIntervalSince(launchedAt)
        let remaining = max(0, Self.minVisible - waited)
        cap?.cancel()
        leaveTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.beginLeave()
        }
    }

    /// Navigation is dead while the wall is up, so the first press skips it instead of vanishing.
    func skip() {
        guard phase == .showing, started, Date().timeIntervalSince(mountedAt) > 0.3 else { return }
        beginLeave()
    }

    private func beginLeave() {
        guard !left, phase == .showing else { return }
        left = true
        cap?.cancel(); leaveTimer?.cancel()
        Self.wallShowing = false
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: Self.fade)) { phase = .leaving }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.fade))
            self?.phase = .done
        }
    }
}
