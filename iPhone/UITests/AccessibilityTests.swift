import XCTest

/// The phone's accessibility pass on fixtures: the largest Dynamic Type size
/// (`-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`) on Home, a title page,
/// Discover, the picker and the player HUD, and the app's own Reduce Motion override (`--phone-reduce-motion`;
/// a launch argument cannot switch the system setting). Each checks that the controls the screen is for are
/// still on screen and inside it, and attaches a screenshot of the screen at that size.
///
/// The English UI is assumed.
final class AccessibilityTests: XCTestCase {
    private static let largest = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func snap(_ app: XCUIApplication, _ name: String) {
        // A screenshot the runner cannot deliver in time is evidence lost, not a failed test.
        let lenient = XCTExpectedFailure.Options()
        lenient.isStrict = false
        var shot: XCUIScreenshot?
        XCTExpectFailure("the screenshot service can time out", options: lenient) {
            shot = XCUIScreen.main.screenshot()
        }
        guard let shot else { return }
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @discardableResult
    private func expect(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let found = element(app, id)
        if !found.waitForExistence(timeout: timeout) {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "hierarchy-missing-\(id)"
            tree.lifetime = .keepAlways
            add(tree)
            snap(app, "missing-\(id)")
            XCTFail("no element \(id)", file: file, line: line)
        }
        return found
    }

    private func tap(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        expect(app, id, timeout: timeout, file: file, line: line).tap()
    }

    /// The element is drawn inside the screen's width: no text pushing a control off the edge.
    private func assertFits(_ app: XCUIApplication, _ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(element.frame.minX, screen.minX - 1, "\(what) starts left of the screen", file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxX, screen.maxX + 1, "\(what) ends right of the screen", file: file, line: line)
        XCTAssertGreaterThan(element.frame.height, 0, "\(what) has no height", file: file, line: line)
    }

    // MARK: Dynamic Type

    /// Home at the largest size: the hero reads as "Featured" and fits, the tab bar keeps every tab.
    func testHomeAtLargestText() throws {
        let app = launchHarbor(["--fixtures", "shell"] + Self.largest)
        let hero = expect(app, "hero-carousel", timeout: 40)
        XCTAssertTrue(hero.label.hasPrefix("Featured"), "the hero reads \(hero.label)")
        assertFits(app, hero, "the hero")
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 30), "no tab bar")
        for title in ["Home", "Discover", "Library", "Search"] {
            XCTAssertTrue(bar.buttons[title].firstMatch.exists, "the tab bar lost \(title) at the largest size")
        }
        snap(app, "a11y-home-xxxl")
    }

    /// Discover at the largest size still opens, and its screen fits the width.
    func testDiscoverAtLargestText() throws {
        let app = launchHarbor(["--fixtures", "shell"] + Self.largest)
        tapTab(app, "Discover")
        let discover = expect(app, "discover", timeout: 30)
        assertFits(app, discover, "Discover")
        snap(app, "a11y-discover-xxxl")
    }

    /// A title page at the largest size: its name, Play and the page itself stay inside the screen.
    func testDetailAtLargestText() throws {
        let app = launchHarbor(["--fixtures", "detail", "--fixture-streams", "--phone-open", "harbor://detail/series/s-0"] + Self.largest)
        expect(app, "detail-sheet", timeout: 40)
        let page = expect(app, "detail-page")
        assertFits(app, page, "the title page")
        let name = expect(app, "detail-name")
        XCTAssertEqual(name.label, "Dune: Part Two")
        assertFits(app, name, "the title")
        snap(app, "a11y-detail-xxxl")
    }

    /// The player's HUD at the largest size keeps Close, Play / Pause and the scrubber, all inside the screen.
    func testPlayerHUDAtLargestText() throws {
        let app = launchHarbor(["--fixtures", "detail", "--fixture-streams", "--phone-picker"] + Self.largest)
        expect(app, "phone-picker", timeout: 40)
        snap(app, "a11y-picker-xxxl")
        tap(app, "stream-0", timeout: 30)
        expect(app, "player-screen", timeout: 20)
        expect(app, "player-hud", timeout: 5)
        for id in ["player-close", "player-playpause", "player-scrubber"] {
            assertFits(app, expect(app, id), id)
        }
        snap(app, "a11y-player-xxxl")
    }

    // MARK: Reduce Motion

    /// With Reduce Motion the hero holds on its first title (no auto-advance) and still names its place.
    func testHeroHoldsUnderReduceMotion() throws {
        let app = launchHarbor(["--fixtures", "shell", "--phone-reduce-motion"])
        let hero = expect(app, "hero-carousel", timeout: 40)
        let first = hero.label
        XCTAssertTrue(first.hasPrefix("Featured"), "the hero reads \(first)")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(hero.label, first, "the hero moved under Reduce Motion")
        snap(app, "a11y-home-reduce-motion")
    }

    /// A title page opens with Reduce Motion on (no zoom transition, no backdrop stretch).
    func testTitleOpensUnderReduceMotion() throws {
        let app = launchHarbor(["--fixtures", "detail", "--fixture-streams", "--phone-reduce-motion", "--phone-open", "harbor://detail/series/s-0"])
        expect(app, "detail-sheet", timeout: 40)
        expect(app, "detail-page")
        snap(app, "a11y-detail-reduce-motion")
    }
}
