import XCTest

/// Home's hero ("Spotlight": art to the very top, floating glass buttons) on the fixture feed, dressed with
/// real art by `--phone-hero-demo`. Attaches screenshots of the top of Home at rest and after a scroll, and
/// checks the controls are there. CI exports the attachments (ci/build.yml, "Home hero screenshots").
///
/// The English UI is assumed. The art comes from Cinemeta's public image host, so this one test needs the
/// network (the screenshot waits for it, and still attaches what it has).
final class HomeHeroShotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func snap(_ name: String) {
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

    /// Waits without polling an element: the art needs a moment to arrive.
    private func pause(_ seconds: TimeInterval) {
        let wait = XCTestExpectation(description: "pause")
        wait.isInverted = true
        _ = XCTWaiter().wait(for: [wait], timeout: seconds)
    }

    func testSpotlightHero() throws {
        let app = launchHarbor(["--fixtures", "shell", "--phone-hero-demo"])
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "no tab bar")
        XCTAssertTrue(element(app, "hero-carousel").waitForExistence(timeout: 30), "no hero")
        XCTAssertTrue(element(app, "hero-play-t-0").exists, "no Play")
        XCTAssertTrue(element(app, "hero-watchlist-t-0").exists, "no Watchlist")
        XCTAssertTrue(element(app, "hero-details-t-0").exists, "no Details")
        XCTAssertTrue(element(app, "hero-kicker-t-0").exists, "no kicker")
        XCTAssertTrue(element(app, "home-edit").exists, "no filter button")
        XCTAssertTrue(element(app, "account-button").exists, "no profile button")
        // The art is at the top edge: the hero starts at y = 0.
        XCTAssertLessThanOrEqual(element(app, "hero-carousel").frame.minY, 1, "the hero does not start at the top of the screen")
        pause(10)
        snap("home-hero-spotlight")

        // Scrolled: the status bar keeps a scrim over the rows, no dark bar.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
        pause(1)
        snap("home-hero-scrolled")
    }
}
