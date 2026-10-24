import XCTest
@testable import HarborPhone

/// The resume rule (App/Shared/Player/ResumeSaveGuard.swift): a player that opens on
/// a saved spot never saves the file's first frames over it, on the phone as on the TV.
final class ResumeSaveGuardTests: XCTestCase {
    func testUnarmedAllowsEverySave() {
        var g = ResumeSaveGuard()
        XCTAssertFalse(g.armed)
        XCTAssertTrue(g.allowsSave(position: 0, duration: 7200))
        XCTAssertTrue(g.allowsSave(position: 42, duration: 0))
        XCTAssertEqual(g.reported(position: 12), 12)
    }

    func testEarlyPositionIsHeldUntilTheSpotIsReached() {
        var g = ResumeSaveGuard()
        g.arm(1800)
        XCTAssertTrue(g.armed)
        // The engine reports 0 (and then its first seconds) before the start seek lands.
        XCTAssertFalse(g.allowsSave(position: 0, duration: 0))
        XCTAssertFalse(g.allowsSave(position: 1.2, duration: 7200))
        XCTAssertFalse(g.allowsSave(position: 1789, duration: 7200))
        XCTAssertTrue(g.armed)
        XCTAssertEqual(g.reported(position: 1.2), 1800, "a session stop reports the saved spot, not the early one")
        // Landed (within the tolerance): saves go out from here on, wherever playback goes.
        XCTAssertTrue(g.allowsSave(position: 1801.5, duration: 7200))
        XCTAssertFalse(g.armed)
        XCTAssertTrue(g.allowsSave(position: 3, duration: 7200))
    }

    func testToleranceIsBothSides() {
        var below = ResumeSaveGuard()
        below.arm(600)
        XCTAssertTrue(below.allowsSave(position: 600 - ResumeSaveGuard.tolerance, duration: 7200))
        var above = ResumeSaveGuard()
        above.arm(600)
        XCTAssertFalse(above.allowsSave(position: 600 + ResumeSaveGuard.tolerance + 0.5, duration: 7200))
    }

    func testAStartFromTheTopArmsNothing() {
        var g = ResumeSaveGuard()
        g.arm(nil)
        g.arm(0)
        g.arm(ResumeSaveGuard.minimumSpot)
        g.arm(.nan)
        g.arm(.infinity)
        XCTAssertFalse(g.armed)
    }

    func testAZeroStartKeepsAnEarlierTarget() {
        // The resume fork: startAt = 0 while the saved spot waits on the prompt.
        var g = ResumeSaveGuard()
        g.arm(1200)
        g.arm(0)
        XCTAssertEqual(g.target, 1200)
    }

    func testANewSpotReplacesTheTarget() {
        // A source switch or an engine move sends playback to a new spot.
        var g = ResumeSaveGuard()
        g.arm(1200)
        g.arm(1500)
        XCTAssertFalse(g.allowsSave(position: 1200, duration: 7200))
        XCTAssertTrue(g.allowsSave(position: 1500, duration: 7200))
    }

    func testTheViewerMovingReleasesTheGuard() {
        // A scrub, a step, the skip pill or Start over: where the viewer put the playhead is theirs.
        var g = ResumeSaveGuard()
        g.arm(1800)
        g.viewerMoved()
        XCTAssertFalse(g.armed)
        XCTAssertTrue(g.allowsSave(position: 0, duration: 7200))
    }

    func testATargetPastTheEndCannotHoldForever() {
        var g = ResumeSaveGuard()
        g.arm(5000)
        XCTAssertFalse(g.allowsSave(position: 3, duration: 0), "the length is not known yet")
        XCTAssertTrue(g.allowsSave(position: 3, duration: 4000))
        XCTAssertFalse(g.armed)
    }

    func testANonFinitePositionIsHeld() {
        var g = ResumeSaveGuard()
        g.arm(900)
        XCTAssertFalse(g.allowsSave(position: .nan, duration: 7200))
        XCTAssertTrue(g.armed)
    }
}
