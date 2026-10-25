import CoreGraphics
import Foundation

/// The player's newer touch rules (press and hold for 2x, the vertical swipes for brightness and volume,
/// swipe down to close), kept out of the views so the unit tests reach them. PhonePlayerHUD holds the
/// older ones (double tap thirds, pinch, scrub maths).
enum PhonePlayerTouch {
    /// How fast a press and hold plays.
    static let holdRate: Double = 2
    /// How long a finger rests before the hold counts.
    static let holdAfter: TimeInterval = 0.45
    /// A drag this far (points) decides what it is: a sideways scrub, or an up / down swipe.
    static let decideAfter: CGFloat = 12
    /// A full swipe over this share of the screen's height moves brightness or volume from 0 to 100 %.
    static let levelSpan: CGFloat = 0.75
    /// Swipe down to close: past this share of the height, or a quick flick past `closeFlickDistance`.
    static let closeShare: CGFloat = 0.22
    static let closeFlickDistance: CGFloat = 60
    static let closeFlickSpeed: CGFloat = 900

    /// What a drag on the picture does, decided once it has moved `decideAfter` points.
    enum Drag: Equatable {
        /// Sideways: scrub (PlayerSession.scrubSwipe).
        case scrub
        /// Up or down on the left half: the screen's brightness.
        case brightness
        /// Up or down on the right half: the volume.
        case volume
        /// Down from the middle strip: close the player.
        case close
        /// Too short to say yet.
        case undecided
    }

    /// Sideways beats up / down when it is the larger move. Up / down is brightness on the left half and
    /// volume on the right, except a downward drag that starts in the middle strip (the centre 30 %),
    /// which pulls the player down to close it.
    static func drag(startX: CGFloat, width: CGFloat, translation: CGSize, isLive: Bool) -> Drag {
        let dx: CGFloat = abs(translation.width)
        let dy: CGFloat = abs(translation.height)
        guard max(dx, dy) >= decideAfter, width > 0, startX.isFinite else { return .undecided }
        if dx > dy { return isLive ? .undecided : .scrub }
        let f: CGFloat = startX / width
        if translation.height > 0, f >= 0.35, f <= 0.65 { return .close }
        return f < 0.5 ? .brightness : .volume
    }

    /// The level after an up / down swipe: up raises it, down lowers it, clamped to 0...1.
    static func level(from start: Double, translationY: CGFloat, height: CGFloat) -> Double {
        guard height > 0, translationY.isFinite, start.isFinite else { return min(1, max(0, start.isFinite ? start : 0)) }
        let delta: Double = Double(-translationY / (height * levelSpan))
        return min(1, max(0, start + delta))
    }

    /// Whether a downward pull that ended here closes the player.
    static func closes(translationY: CGFloat, velocityY: CGFloat, height: CGFloat) -> Bool {
        guard height > 0 else { return false }
        if translationY >= height * closeShare { return true }
        return translationY >= closeFlickDistance && velocityY >= closeFlickSpeed
    }

    /// A press and hold speeds up only on the left or right third (the middle is the play button's).
    static func holdSpeedsUp(x: CGFloat, width: CGFloat) -> Bool {
        PhonePlayerHUD.side(x: x, width: width) != .middle
    }

    /// "40%": a level as the volume capsule and the brightness pill read it.
    static func percent(_ level: Double) -> String {
        guard level.isFinite else { return "0%" }
        return "\(Int((min(1, max(0, level)) * 100).rounded()))%"
    }

    /// The speaker glyph for a volume level.
    static func speakerGlyph(_ level: Double) -> String {
        if level <= 0.001 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
