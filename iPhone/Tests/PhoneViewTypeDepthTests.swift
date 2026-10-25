import SwiftUI
import XCTest
@testable import HarborPhone

/// The player's view types stay shallow enough to resolve on a phone's main thread (a13).
///
/// The first time SwiftUI draws a view, the Swift runtime builds the metadata of its body's static type
/// by decoding the type's mangled name, recursing once (several big frames) per level of generic
/// nesting. PhonePlayerView's body nested 83 levels deep (every modifier, card and the whole HUD
/// in one type), which overflowed the iPhone's 1 MB main-thread stack the moment the player opened.
/// The simulator's main thread has 8 MB, so the app and its UI tests ran fine there.
///
/// Each check resolves a body type for the first time on a thread with its own painted stack and
/// measures how much of it the runtime used, and counts the type's nesting from its name.
final class PhoneViewTypeDepthTests: XCTestCase {
    /// The most stack one body type may take to resolve (measured in the Debug simulator build). The a12
    /// player took 111 KB at depth 83 and crashed the phone; its parts now take at most 48 KB.
    static let stackBudget = 64 * 1024
    /// The most levels of generic nesting a body type may have (a12 player: 83; deepest part now: 24).
    static let depthBudget = 28

    /// Each body type of the player (its parts and modifiers too), resolved for the first time inside the
    /// closure (a metatype read is enough). A new part of the player belongs here.
    static let probes: [(String, () -> Any.Type)] = [
        ("PhonePlayerView", { PhonePlayerView.Body.self }),
        ("PhonePlayerLayers", { PhonePlayerLayers.Body.self }),
        ("PhonePlayerHUDLayer", { PhonePlayerHUDLayer.Body.self }),
        ("PhonePlayerTopRow", { PhonePlayerTopRow.Body.self }),
        ("PhonePlayerVolumeAlone", { PhonePlayerVolumeAlone.Body.self }),
        ("PhonePlayerVolumeCapsule", { PhonePlayerVolumeCapsule.Body.self }),
        ("PhonePlayerVolumeBar", { PhonePlayerVolumeBar.Body.self }),
        ("PhonePlayerTransport", { PhonePlayerTransport.Body.self }),
        ("PhonePlayerBottomBlock", { PhonePlayerBottomBlock.Body.self }),
        ("PhonePlayerScrubber", { PhonePlayerScrubber.Body.self }),
        ("PhonePlayerScrubTrack", { PhonePlayerScrubTrack.Body.self }),
        ("PhonePlayerTopPills", { PhonePlayerTopPills.Body.self }),
        ("PhonePlayerBrightnessFace", { PhonePlayerBrightnessFace.Body.self }),
        ("PhoneRateFace", { PhoneRateFace.Body.self }),
        ("PhonePlainIcon", { PhonePlainIcon.Body.self }),
        ("PhoneCapsuleIcon", { PhoneCapsuleIcon.Body.self }),
        ("PhonePlayerCues", { PhonePlayerCues.Body.self }),
        ("PhonePlayerSkipPill", { PhonePlayerSkipPill.Body.self }),
        ("PhonePlayerUpNext", { PhonePlayerUpNext.Body.self }),
        ("PhonePlayerUpNextPlate", { PhonePlayerUpNextPlate.Body.self }),
        ("PhoneCountdownRing", { PhoneCountdownRing.Body.self }),
        ("PhoneCardButton", { PhoneCardButton.Body.self }),
        ("PhonePlayerResumeCard", { PhonePlayerResumeCard.Body.self }),
        ("PhonePlayerResumeFork", { PhonePlayerResumeFork.Body.self }),
        ("PhonePlayerLeaveCard", { PhonePlayerLeaveCard.Body.self }),
        ("PhonePlayerErrorCard", { PhonePlayerErrorCard.Body.self }),
        ("PhonePlayerConnectingCard", { PhonePlayerConnectingCard.Body.self }),
        ("PhonePlayerKidsLoader", { PhonePlayerKidsLoader.Body.self }),
        ("PhonePlayerNoAudioCard", { PhonePlayerNoAudioCard.Body.self }),
        ("PhonePlayerLockLayer", { PhonePlayerLockLayer.Body.self }),
        ("PhonePlayerPiPPlacard", { PhonePlayerPiPPlacard.Body.self }),
        ("PhonePlayerBackgroundPill", { PhonePlayerBackgroundPill.Body.self }),
        ("PhoneScrubPlate", { PhoneScrubPlate.Body.self }),
        ("PhoneStillWatching", { PhoneStillWatching.Body.self }),
        ("PhoneSeekRipple", { PhoneSeekRipple.Body.self }),
        ("PhoneTorrentReadout", { PhoneTorrentReadout.Body.self }),
        ("PhonePanelSheet", { PhonePanelSheet.Body.self }),
        ("PhonePlayerLook", { PhonePlayerLook.Body.self }),
        ("PhonePlayerLifecycle", { PhonePlayerLifecycle.Body.self }),
        ("PhonePlayerPresentation", { PhonePlayerPresentation.Body.self }),
        ("PhonePlayerMotion", { PhonePlayerMotion.Body.self }),
        ("PhoneCardFrame", { PhoneCardFrame.Body.self }),
    ]

    func testPlayerBodyTypesResolveOnASmallStack() {
        for (name, probe) in Self.probes {
            let r = Self.resolve(probe)
            print("[type-depth] \(name).Body: depth \(r.depth), stack \(r.stack / 1024) KB")
            XCTAssertGreaterThan(r.stack, 0, "\(name): the probe thread did not run")
            XCTAssertLessThanOrEqual(r.stack, Self.stackBudget,
                                     "\(name).Body took \(r.stack / 1024) KB of stack to resolve (budget \(Self.stackBudget / 1024) KB, depth \(r.depth))")
            XCTAssertLessThanOrEqual(r.depth, Self.depthBudget,
                                     "\(name).Body nests \(r.depth) levels deep (budget \(Self.depthBudget)): split it into views of their own")
        }
    }

    func testDepthCountsGenericNesting() {
        XCTAssertEqual(Self.depth("Color"), 0)
        XCTAssertEqual(Self.depth("ModifiedContent<Color, _OpacityEffect>"), 1)
        XCTAssertEqual(Self.depth("ZStack<TupleView<(Color, Optional<Text>)>>"), 4)
        XCTAssertEqual(Self.depth("Foo<(Int) -> ()>"), 2)
    }

    func testStackProbeSeesDeepRecursion() {
        let shallow = Self.stackPeak { _ = Self.recurse(1) }
        let deep = Self.stackPeak { _ = Self.recurse(2000) }
        XCTAssertGreaterThan(shallow, 0)
        XCTAssertGreaterThan(deep, shallow + 2000 * 16)
    }

    // MARK: helpers

    @inline(never) static func recurse(_ n: Int) -> Int {
        var pad = (n, n, n, n)
        return withUnsafeMutablePointer(to: &pad) { p in n <= 1 ? p.pointee.0 : recurse(n - 1) + 1 }
    }

    struct Resolved {
        let name: String
        let depth: Int
        let stack: Int
    }

    /// Resolves the type on a fresh painted stack: its name, nesting and the stack the resolving took
    /// (the name is read afterwards, so its printing is not counted).
    static func resolve(_ probe: @escaping () -> Any.Type) -> Resolved {
        var type: Any.Type = Void.self
        let stack = stackPeak { type = probe() }
        let name = _typeName(type, qualified: false)
        return Resolved(name: name, depth: depth(name), stack: stack)
    }

    /// The deepest generic nesting in a type name: each `<` or `(` opens a level (`->` is not a close).
    static func depth(_ name: String) -> Int {
        var level = 0
        var most = 0
        var previous: Character = " "
        for c in name {
            switch c {
            case "<", "(":
                level += 1
                most = max(most, level)
            case ">" where previous != "-", ")":
                level -= 1
            default:
                break
            }
            previous = c
        }
        return most
    }

    private final class Work {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    /// Runs `work` on a thread whose 16 MB stack is filled with a pattern first; returns the bytes of it
    /// the work touched (0 if the thread could not start).
    static func stackPeak(_ work: @escaping () -> Void) -> Int {
        let page = Int(getpagesize())
        let size = 16 << 20
        guard let mem = mmap(nil, size + page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              mem != UnsafeMutableRawPointer(bitPattern: -1) else { return 0 }
        defer { munmap(mem, size + page) }
        // A guard page under the stack: an overflow stops here instead of writing over other memory.
        mprotect(mem, page, PROT_NONE)
        let base = mem + page
        memset(base, 0xA5, size)
        var attr = pthread_attr_t()
        pthread_attr_init(&attr)
        defer { pthread_attr_destroy(&attr) }
        guard pthread_attr_setstack(&attr, base, size) == 0 else { return 0 }
        let context = Unmanaged.passRetained(Work(work)).toOpaque()
        var thread: pthread_t?
        let started = pthread_create(&thread, &attr, { context in
            let work = Unmanaged<Work>.fromOpaque(context).takeRetainedValue()
            work.run()
            return nil
        }, context)
        guard started == 0, let thread else {
            Unmanaged<Work>.fromOpaque(context).release()
            return 0
        }
        pthread_join(thread, nil)
        // The stack grows down: the lowest byte that lost the pattern marks the deepest point reached.
        let words = base.assumingMemoryBound(to: UInt64.self)
        let count = size / 8
        var low = 0
        while low < count, words[low] == 0xA5A5_A5A5_A5A5_A5A5 { low += 1 }
        return (count - low) * 8
    }
}
