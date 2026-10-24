import Foundation

/// The player under UI-test fixtures. Nothing here touches a
/// real launch: every flag needs `--fixtures` (and not `live`).
/// - `--fixture-resume <sec>`: the saved spot a title opens on (PlaybackContext.startPosition), the
///   way the engine's resume store would answer for a title watched that far.
/// - A fixture link (StreamsFixtures' fixtures.harbor.invalid), or any link with `--fixture-player`:
///   the phone draws a stand-in engine (PhoneFixturePlayer) instead of mpv or AVPlayer, which have
///   nothing to play from it.
/// - The first progress save of the launch is kept (`firstSave`), so a test can check it was not
///   the file's first frames written over the saved spot (the rule, ResumeSaveGuard).
/// - The phone's HUD holds 30 s after the last touch instead of 3 s (`--fixture-hud-after <sec>` sets
///   it): a slow simulator can take longer than 3 s between two XCUITest queries.
/// - `--fixture-engine mpv|native`: the engine the stand-in plays as, so the PiP / AirPlay buttons
///   can be tested on both (the stand-in's PiP is a flag, not AVKit's window).
@MainActor
enum PlayerFixtures {
    private static var args: [String] { ProcessInfo.processInfo.arguments }
    private static var on: Bool { Fixtures.active && !Fixtures.liveRooms }

    static var savedSec: Double? {
        guard on, let i = args.firstIndex(of: "--fixture-resume"), i + 1 < args.count, let sec = Double(args[i + 1]) else { return nil }
        return sec
    }

    /// How long the phone's HUD stays up after the last touch under fixtures; nil on a real launch.
    static var hudHideAfter: Double? {
        guard on else { return nil }
        if let i = args.firstIndex(of: "--fixture-hud-after"), i + 1 < args.count, let sec = Double(args[i + 1]) { return sec }
        return 30
    }

    /// The engine a fixture launch forces for the stand-in, nil for the Auto rule's own pick.
    static var engineOverride: PlayerEngineKind? {
        guard on, let i = args.firstIndex(of: "--fixture-engine"), i + 1 < args.count else { return nil }
        return PlayerEngineKind(rawValue: args[i + 1])
    }

    static let fixtureHost = "fixtures.harbor.invalid"

    static func standInEngine(for url: URL) -> Bool {
        on && (url.host == fixtureHost || args.contains("--fixture-player"))
    }

    /// The first position PlaybackContext.save wrote this launch, under fixtures.
    private(set) static var firstSave: Double?

    static func noteSave(positionSec: Double) {
        guard on, firstSave == nil else { return }
        firstSave = positionSec
    }
}
