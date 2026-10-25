import XCTest
@testable import HarborPhone

/// The player's Infuse-style touch rules (iPhone/Sources/Player/PhonePlayerTouch.swift): what a drag is,
/// the brightness and volume levels a swipe sets, the pull down to close, where a press and hold plays at
/// 2x, and the capsule's words.
final class PhonePlayerTouchTests: XCTestCase {
    private let width: CGFloat = 956
    private let height: CGFloat = 440

    // MARK: What a drag is

    func testShortDragIsUndecided() {
        XCTAssertEqual(PhonePlayerTouch.drag(startX: 100, width: width, translation: CGSize(width: 5, height: 6), isLive: false), .undecided)
    }

    func testSidewaysDragScrubs() {
        XCTAssertEqual(PhonePlayerTouch.drag(startX: 100, width: width, translation: CGSize(width: 40, height: 10), isLive: false), .scrub)
        XCTAssertEqual(PhonePlayerTouch.drag(startX: 800, width: width, translation: CGSize(width: -40, height: -10), isLive: false), .scrub)
    }

    func testLiveHasNoScrub() {
        XCTAssertEqual(PhonePlayerTouch.drag(startX: 100, width: width, translation: CGSize(width: 40, height: 10), isLive: true), .undecided)
    }

    func testLeftHalfIsBrightnessRightHalfIsVolume() {
        XCTAssertEqual(PhonePlayerTouch.drag(startX: 100, width: width, translation: CGSize(width: 3, height: -30), isLive: false), .brightness)
        XCTAssertEqual(PhonePlayerTouch.drag(startX: 100, width: width, translation: CGSize(width: 3, height: 30), isLive: false), .brightness)
        XCTAssertEqual(PhonePlayerTouch.drag(startX: 850, width: width, translation: CGSize(width: 3, height: -30), isLive: false), .volume)
        XCTAssertEqual(PhonePlayerTouch.drag(startX: 850, width: width, translation: CGSize(width: 3, height: 30), isLive: true), .volume)
    }

    func testDownFromTheMiddleCloses() {
        XCTAssertEqual(PhonePlayerTouch.drag(startX: 478, width: width, translation: CGSize(width: 2, height: 30), isLive: false), .close)
        // Up from the middle is still a level.
        XCTAssertEqual(PhonePlayerTouch.drag(startX: 470, width: width, translation: CGSize(width: 2, height: -30), isLive: false), .brightness)
        XCTAssertEqual(PhonePlayerTouch.drag(startX: 490, width: width, translation: CGSize(width: 2, height: -30), isLive: false), .volume)
    }

    func testNoWidthIsUndecided() {
        XCTAssertEqual(PhonePlayerTouch.drag(startX: 10, width: 0, translation: CGSize(width: 0, height: 40), isLive: false), .undecided)
    }

    // MARK: Levels

    func testSwipeUpRaisesDownLowers() {
        let up = PhonePlayerTouch.level(from: 0.4, translationY: -height * PhonePlayerTouch.levelSpan * 0.25, height: height)
        XCTAssertEqual(up, 0.65, accuracy: 0.0001)
        let down = PhonePlayerTouch.level(from: 0.4, translationY: height * PhonePlayerTouch.levelSpan * 0.1, height: height)
        XCTAssertEqual(down, 0.3, accuracy: 0.0001)
    }

    func testLevelsClamp() {
        XCTAssertEqual(PhonePlayerTouch.level(from: 0.9, translationY: -1000, height: height), 1)
        XCTAssertEqual(PhonePlayerTouch.level(from: 0.1, translationY: 1000, height: height), 0)
        XCTAssertEqual(PhonePlayerTouch.level(from: 0.5, translationY: .nan, height: height), 0.5)
        XCTAssertEqual(PhonePlayerTouch.level(from: 0.5, translationY: 10, height: 0), 0.5)
    }

    // MARK: Pull down to close

    func testFarPullCloses() {
        XCTAssertTrue(PhonePlayerTouch.closes(translationY: height * 0.3, velocityY: 0, height: height))
        XCTAssertFalse(PhonePlayerTouch.closes(translationY: height * 0.1, velocityY: 100, height: height))
    }

    func testQuickFlickCloses() {
        XCTAssertTrue(PhonePlayerTouch.closes(translationY: 70, velocityY: 1200, height: height))
        XCTAssertFalse(PhonePlayerTouch.closes(translationY: 30, velocityY: 2000, height: height))
    }

    // MARK: Press and hold

    func testHoldSpeedsUpOnTheSidesOnly() {
        XCTAssertTrue(PhonePlayerTouch.holdSpeedsUp(x: 100, width: width))
        XCTAssertTrue(PhonePlayerTouch.holdSpeedsUp(x: 900, width: width))
        XCTAssertFalse(PhonePlayerTouch.holdSpeedsUp(x: 478, width: width))
        XCTAssertEqual(PhonePlayerTouch.holdRate, 2)
    }

    // MARK: Words

    func testPercent() {
        XCTAssertEqual(PhonePlayerTouch.percent(0.4), "40%")
        XCTAssertEqual(PhonePlayerTouch.percent(0.914), "91%")
        XCTAssertEqual(PhonePlayerTouch.percent(1.2), "100%")
        XCTAssertEqual(PhonePlayerTouch.percent(-1), "0%")
        XCTAssertEqual(PhonePlayerTouch.percent(.nan), "0%")
    }

    func testSpeakerGlyph() {
        XCTAssertEqual(PhonePlayerTouch.speakerGlyph(0), "speaker.slash.fill")
        XCTAssertEqual(PhonePlayerTouch.speakerGlyph(0.2), "speaker.wave.1.fill")
        XCTAssertEqual(PhonePlayerTouch.speakerGlyph(0.5), "speaker.wave.2.fill")
        XCTAssertEqual(PhonePlayerTouch.speakerGlyph(0.9), "speaker.wave.3.fill")
    }
}
