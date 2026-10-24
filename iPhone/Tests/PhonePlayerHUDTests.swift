import XCTest
@testable import HarborPhone

/// The phone player's touch rules (iPhone/Sources/Player/PhonePlayerHUD.swift): the double tap's thirds
/// and steps, the pinch's fit / fill, the scrubber's target and fill, its labels and the step glyphs.
final class PhonePlayerHUDTests: XCTestCase {
    func testHUDFadesAfterThreeSeconds() {
        XCTAssertEqual(PhonePlayerHUD.hideAfter, 3)
    }

    // MARK: Double tap

    func testThirds() {
        XCTAssertEqual(PhonePlayerHUD.side(x: 10, width: 900), .back)
        XCTAssertEqual(PhonePlayerHUD.side(x: 299, width: 900), .back)
        XCTAssertEqual(PhonePlayerHUD.side(x: 450, width: 900), .middle)
        XCTAssertEqual(PhonePlayerHUD.side(x: 601, width: 900), .ahead)
        XCTAssertEqual(PhonePlayerHUD.side(x: 899, width: 900), .ahead)
    }

    func testThirdsWithNoWidthAreTheMiddle() {
        XCTAssertEqual(PhonePlayerHUD.side(x: 10, width: 0), .middle)
        XCTAssertEqual(PhonePlayerHUD.side(x: .nan, width: 900), .middle)
    }

    func testSeekDeltaUsesThePrefsSteps() {
        XCTAssertEqual(PhonePlayerHUD.seekDelta(.back), -10)
        XCTAssertEqual(PhonePlayerHUD.seekDelta(.ahead), 10)
        XCTAssertNil(PhonePlayerHUD.seekDelta(.middle))
        XCTAssertEqual(PhonePlayerHUD.seekDelta(.back, back: 5, ahead: 30), -5)
        XCTAssertEqual(PhonePlayerHUD.seekDelta(.ahead, back: 5, ahead: 30), 30)
        // A step stored with a sign still steps the right way.
        XCTAssertEqual(PhonePlayerHUD.seekDelta(.back, back: -15), -15)
    }

    // MARK: Pinch

    func testPinchOutFillsAndInFits() {
        XCTAssertTrue(PhonePlayerHUD.fill(afterPinch: 1.3, current: false))
        XCTAssertFalse(PhonePlayerHUD.fill(afterPinch: 0.7, current: true))
    }

    func testASmallPinchChangesNothing() {
        XCTAssertTrue(PhonePlayerHUD.fill(afterPinch: 1.02, current: true))
        XCTAssertFalse(PhonePlayerHUD.fill(afterPinch: 0.97, current: false))
        XCTAssertTrue(PhonePlayerHUD.fill(afterPinch: .nan, current: true))
    }

    // MARK: Scrubber

    func testScrubTargetFollowsTheFinger() {
        XCTAssertEqual(PhonePlayerHUD.scrubTarget(x: 150, width: 600, duration: 7200), 1800)
        XCTAssertEqual(PhonePlayerHUD.scrubTarget(x: -40, width: 600, duration: 7200), 0)
        // Never past the last second.
        XCTAssertEqual(PhonePlayerHUD.scrubTarget(x: 900, width: 600, duration: 7200), 7199)
    }

    func testScrubTargetNeedsALength() {
        XCTAssertNil(PhonePlayerHUD.scrubTarget(x: 150, width: 600, duration: 0))
        XCTAssertNil(PhonePlayerHUD.scrubTarget(x: 150, width: 600, duration: .infinity))
    }

    func testBarFraction() {
        XCTAssertEqual(PhonePlayerHUD.barFraction(position: 1800, duration: 7200), 0.25)
        XCTAssertEqual(PhonePlayerHUD.barFraction(position: 9000, duration: 7200), 1)
        XCTAssertEqual(PhonePlayerHUD.barFraction(position: 30, duration: 0), 0)
    }

    func testLabelsFollowAPendingScrub() {
        let playing = PhonePlayerHUD.labels(position: 1800, duration: 7200, pending: nil)
        XCTAssertEqual(playing.elapsed, PlayerClock.fmt(1800))
        XCTAssertEqual(playing.remaining, "-" + PlayerClock.fmt(5400))
        let scrubbing = PhonePlayerHUD.labels(position: 1800, duration: 7200, pending: 3600)
        XCTAssertEqual(scrubbing.elapsed, PlayerClock.fmt(3600))
        XCTAssertEqual(scrubbing.remaining, "-" + PlayerClock.fmt(3600))
        let unknown = PhonePlayerHUD.labels(position: 12, duration: 0, pending: nil)
        XCTAssertEqual(unknown.remaining, "-" + PlayerClock.fmt(0))
    }

    // MARK: Glyphs

    func testStepGlyphs() {
        XCTAssertEqual(PhonePlayerHUD.stepGlyph("gobackward", 10), "gobackward.10")
        XCTAssertEqual(PhonePlayerHUD.stepGlyph("goforward", 30), "goforward.30")
        XCTAssertEqual(PhonePlayerHUD.stepGlyph("goforward", 12), "goforward")
        XCTAssertEqual(PhonePlayerHUD.stepGlyph("goforward", 0), "goforward")
    }
}
