import XCTest

/// The tab bar's bottom accessory: "Resume <title> · S2E4 · 34 min
/// left" from Continue Watching. `tabViewBottomAccessory(isEnabled:content:)` is an iOS 26.1 API, so
/// on an older runtime these tests skip. The live Picture in Picture state of the same strip needs a
/// device (the report's on-phone list). `--phone-no-resume` empties Continue Watching. The English UI
/// is assumed.
final class BottomAccessoryTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
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

    private func launch(_ extra: [String]) throws -> XCUIApplication {
        guard #available(iOS 26.1, *) else { throw XCTSkip("the bottom accessory is an iOS 26.1 API") }
        let app = launchHarbor(["--fixtures", "detail", "--fixture-streams"] + extra)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 40), "no tab bar")
        return app
    }

    /// With Continue Watching on Home the strip reads "Resume <newest title>" and its episode / time left.
    func testShownWithAContinueWatchingItem() throws {
        let app = try launch([])
        let strip = element(app, "resume-accessory")
        XCTAssertTrue(strip.waitForExistence(timeout: 30), "no Resume accessory")
        XCTAssertTrue(strip.label.contains("Resume Severance"), "the strip reads \"\(strip.label)\"")
        XCTAssertTrue(strip.label.contains("S2E4"), "the strip reads \"\(strip.label)\"")
        snap("resume-accessory")
    }

    /// Nothing to resume: no strip.
    func testHiddenWhenContinueWatchingIsEmpty() throws {
        let app = try launch(["--phone-no-resume"])
        // Home has loaded; the strip must not turn up in the time its Continue Watching read takes.
        XCTAssertTrue(element(app, "rail-Continue Watching").waitForExistence(timeout: 30), "Home did not load")
        let appears = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: element(app, "resume-accessory"))
        appears.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [appears], timeout: 6), .completed, "the Resume accessory shows with nothing to resume")
        snap("no-accessory")
    }

    /// A tap on the strip opens the title playing from its saved spot: the picker (the fixture film's
    /// streams), then the player once a source is picked.
    func testTapOpensThePlayer() throws {
        let app = try launch([])
        let strip = element(app, "resume-accessory")
        XCTAssertTrue(strip.waitForExistence(timeout: 30), "no Resume accessory")
        strip.tap()
        let picker = element(app, "phone-picker")
        let player = element(app, "player-screen")
        let up = NSPredicate { _, _ in picker.exists || player.exists }
        let wait = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: up, object: nil)], timeout: 60)
        XCTAssertEqual(wait, .completed, "neither the picker nor the player opened")
        // Instant play (the default) picks the best source itself behind an auto step; with it off the
        // list stays and a row is tapped. Give the auto step its time before choosing by hand.
        let row = element(app, "stream-0")
        let auto = element(app, "auto-caption")
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, !player.exists {
            if row.exists, !auto.exists {
                if player.waitForExistence(timeout: 3) { break }
                if row.exists, !auto.exists { row.tap() }
            }
            _ = player.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(player.waitForExistence(timeout: 30), "the player did not open")
        snap("resume-opens-player")
    }
}
