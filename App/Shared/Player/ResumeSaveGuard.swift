import Foundation

/// A player that opens on a saved spot reads 0 (or wherever the file's
/// first frames land) until the engine's start seek has gone through. The 1 s save tick, a pause
/// or a close in that window wrote that early position over the saved one: the title's Continue
/// Watching card and the Stremio library entry (which the other device resumes from) went back to
/// the start, and the next open began there too.
///
/// The guard holds every progress save until playback has really reached the spot it was sent to
/// (within `tolerance`), or the viewer moved the playhead themselves (a scrub, a step, the skip
/// pill, Start over). It is armed by every start position the session sets (`startAt`, a source
/// switch's or an engine move's spot, the resume prompt's saved spot). Auto-skip is not the viewer.
/// The natural end's "finished" save is never held: the file did play to its end.
struct ResumeSaveGuard: Equatable {
    /// How near the target the position must be for playback to count as started there.
    static let tolerance: Double = 10
    /// A start at or under this is a start from the top (PlayerSession.start's `sec <= 5`).
    static let minimumSpot: Double = 5

    /// The spot playback was sent to and has not reached yet; nil when saves may go out.
    private(set) var target: Double?

    var armed: Bool { target != nil }

    /// A new start position: saves wait until the position reaches it. A start from the top
    /// arms nothing (an earlier, unlanded target stays armed: `startAt = 0` under the resume fork).
    mutating func arm(_ spot: Double?) {
        guard let spot, spot.isFinite, spot > Self.minimumSpot else { return }
        target = spot
    }

    /// The viewer moved the playhead: where it is now is what they chose, so it may be saved.
    mutating func viewerMoved() {
        target = nil
    }

    /// Whether a save of `position` may go out now. Reaching the target disarms the guard; so does a
    /// target past the end of a file whose length is known (it can never be reached).
    mutating func allowsSave(position: Double, duration: Double) -> Bool {
        guard let t = target else { return true }
        if duration > 0, t >= duration { target = nil; return true }
        guard position.isFinite, abs(position - t) <= Self.tolerance else { return false }
        target = nil
        return true
    }

    /// The position to report while the guard holds (a home-server session stop): the saved spot,
    /// not the early one.
    func reported(position: Double) -> Double {
        target ?? position
    }
}
