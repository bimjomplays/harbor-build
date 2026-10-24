import Foundation

/// use-still-watching.ts: after `threshold` episodes advanced on their own with no press in
/// between, the next auto-advance asks first. `runs` is app-wide because the TV reopens the
/// player per episode; any press in the player resets it (upstream's window keydown listener).
@MainActor
enum StillWatching {
    static var runs = 0

    static func reset() { runs = 0 }

    /// gateAdvance: true when the prompt should show instead of advancing.
    static func gate(enabled: Bool, threshold: Int) -> Bool {
        guard enabled, threshold > 0 else { return false }
        if runs + 1 >= threshold { return true }
        runs += 1
        return false
    }
}
