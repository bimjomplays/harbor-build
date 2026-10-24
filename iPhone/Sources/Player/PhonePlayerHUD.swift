import CoreGraphics

/// The phone player's touch rules, kept out of the view so the unit tests
/// reach them: where a double tap seeks, what a pinch does to the picture, where a finger on the
/// scrubber lands, and the bar's elapsed / remaining labels. The view (PhonePlayerView) only forwards.
enum PhonePlayerHUD {
    /// The HUD fades this long after the last touch (§2.7; the TV's chrome waits 4.6 s).
    static let hideAfter: Double = 3
    /// A pinch counts once it has opened or closed the picture by this much.
    static let pinchThreshold: CGFloat = 0.08

    /// Which third of the picture a double tap landed in.
    enum Side: Equatable {
        case back, middle, ahead
    }

    /// Left third steps back, right third ahead; the middle third steps nowhere (YouTube's rule; the
    /// single tap there toggles the HUD like anywhere else).
    static func side(x: CGFloat, width: CGFloat) -> Side {
        guard width > 0, x.isFinite else { return .middle }
        let f = x / width
        if f < 1.0 / 3.0 { return .back }
        if f > 2.0 / 3.0 { return .ahead }
        return .middle
    }

    /// The double tap's seek: the TV's step sizes (player prefs seekBackStepSec / seekForwardStepSec,
    /// 10 s unless changed), back on the left, ahead on the right; nil in the middle.
    static func seekDelta(_ side: Side, back: Double = 10, ahead: Double = 10) -> Double? {
        switch side {
        case .back: return -abs(back)
        case .ahead: return abs(ahead)
        case .middle: return nil
        }
    }

    /// A pinch out fills the screen (the picture is cropped to it), a pinch in fits it again; one too
    /// small to mean either leaves the picture as it is.
    static func fill(afterPinch scale: CGFloat, current: Bool) -> Bool {
        guard scale.isFinite else { return current }
        if scale >= 1 + pinchThreshold { return true }
        if scale <= 1 - pinchThreshold { return false }
        return current
    }

    /// How far along the bar a finger at `x` is, clamped to the bar.
    static func scrubFraction(x: CGFloat, width: CGFloat) -> Double {
        guard width > 0, x.isFinite else { return 0 }
        return Double(min(1, max(0, x / width)))
    }

    /// The spot a finger at `x` on the bar asks for: never past the last second (the seek clamp the
    /// session uses), nil while the file's length is not known.
    static func scrubTarget(x: CGFloat, width: CGFloat, duration: Double) -> Double? {
        guard duration.isFinite, duration > 0 else { return nil }
        return min(max(0, duration - 1), scrubFraction(x: x, width: width) * duration)
    }

    /// How much of the bar is filled at `position`.
    static func barFraction(position: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0, position.isFinite else { return 0 }
        return min(1, max(0, position / duration))
    }

    /// Apple's numbered skip glyphs ("gobackward.10") for the steps SF Symbols draws; any other step
    /// keeps the plain arrow (the TV's PlayerScreen.stepGlyph).
    static func stepGlyph(_ base: String, _ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0, seconds < 1000 else { return base }
        let n: Int = Int(seconds.rounded())
        return [5, 10, 15, 30, 45, 60, 75, 90].contains(n) ? "\(base).\(n)" : base
    }

    /// The bar's labels: the time played and the time left ("-" before it), both from the pending
    /// scrub while a finger is on the bar, so they follow it.
    static func labels(position: Double, duration: Double, pending: Double?) -> (elapsed: String, remaining: String) {
        let at: Double = pending ?? position
        let left: Double = duration > 0 ? max(0, duration - at) : 0
        return (PlayerClock.fmt(at), "-" + PlayerClock.fmt(left))
    }
}
