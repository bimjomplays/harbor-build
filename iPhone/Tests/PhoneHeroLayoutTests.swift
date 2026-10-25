import XCTest
@testable import HarborPhone

/// Home's hero shows about 70% of a landscape backdrop: the art band is close to the picture's own 16:9 shape, so
/// aspect-filling it crops only a little off the sides, on every iPhone width.
@MainActor
final class PhoneHeroLayoutTests: XCTestCase {
    /// iPhone widths in points: SE / mini, 17, 17 Pro Max.
    private let widths: [CGFloat] = [375, 402, 440]

    func testArtShowsMostOfA16x9Backdrop() {
        for width in widths {
            let share = PhoneHero.visibleShare(aspect: 16.0 / 9.0, width: width)
            XCTAssertEqual(share, 0.70, accuracy: 0.03, "at \(width) pt only \(share) of the backdrop's width shows")
        }
    }

    func testArtCoversTheWidthWithoutLetterbox() {
        // Taller than the backdrop drawn at the screen's width: the art fills the band edge to edge, no bars.
        for width in widths {
            XCTAssertGreaterThan(PhoneHero.artHeight(forWidth: width), width * 9 / 16)
        }
    }

    func testSixPointNineInchNumbers() {
        XCTAssertEqual(PhoneHero.artHeight(forWidth: 440), 352)
        XCTAssertEqual(PhoneHero.height(forWidth: 440), 504)
    }

    func testTextBlockOverlapsTheArt() {
        // The hero runs past its art by less than its text block is tall (kicker, logo, facts, buttons, dots:
        // about 270 pt), so the kicker and logo sit over the art's lower part.
        XCTAssertLessThan(PhoneHero.belowArt, 200)
        XCTAssertGreaterThan(PhoneHero.belowArt, 120)
    }
}
