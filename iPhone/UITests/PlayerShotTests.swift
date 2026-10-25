import XCTest

/// The phone player laid out like Infuse, in landscape on the fixture film, dressed by `--phone-player-demo`
/// (a real film still as the picture, Infuse-like audio and subtitle tracks). Attaches a screenshot of each
/// state: the HUD playing, paused, the gear menu and each of its lists, the brightness pill, the volume
/// capsule on its own, the 2x pill and the double tap's ripple. CI exports the attachments (ci/build.yml,
/// "Player screenshots"); they are compared side by side with Infuse's own.
///
/// The English UI is assumed. The still comes from TMDB's public image host, so this test needs the network
/// (the shots wait for it, and are still taken without it).
final class PlayerShotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
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

    @discardableResult
    private func expect(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let found = element(app, id)
        if !found.waitForExistence(timeout: timeout) {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "hierarchy-missing-\(id)"
            tree.lifetime = .keepAlways
            add(tree)
            snap("missing-\(id)")
            XCTFail("no element \(id)", file: file, line: line)
        }
        return found
    }

    private func tap(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        expect(app, id, timeout: timeout, file: file, line: line).tap()
    }

    /// Waits without polling an element (an animation settling, the still arriving).
    private func pause(_ seconds: TimeInterval) {
        let wait = XCTestExpectation(description: "pause")
        wait.isInverted = true
        _ = XCTWaiter().wait(for: [wait], timeout: seconds)
    }

    /// A row of the open gear menu whose title starts with `title`.
    private func menuRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func tapMenuRow(_ app: XCUIApplication, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = menuRow(app, title)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no menu row \(title)", file: file, line: line)
        row.tap()
    }

    private func point(_ app: XCUIApplication, _ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    /// The HUD up (a tap on the bare picture when it has faded).
    private func wakeHUD(_ app: XCUIApplication) {
        if !element(app, "player-hud").exists { point(app, 0.5, 0.25).tap() }
        expect(app, "player-hud", timeout: 5)
    }

    /// The HUD away, for the shots of what shows over the bare picture.
    private func hideHUD(_ app: XCUIApplication) {
        if element(app, "player-hud").exists { point(app, 0.5, 0.25).tap() }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, "player-hud"))
        _ = XCTWaiter.wait(for: [gone], timeout: 5)
    }

    /// Opens the gear menu, then the list under `row` (none for the menu itself), and shoots it.
    private func shootMenu(_ app: XCUIApplication, _ row: String?, _ name: String) {
        wakeHUD(app)
        tap(app, "player-gear", timeout: 5)
        XCTAssertTrue(menuRow(app, "Advanced Options").waitForExistence(timeout: 5), "the gear menu did not open")
        if let row { tapMenuRow(app, row) }
        pause(1.2)
        snap(name)
        // A tap away closes the menu; the HUD stays.
        point(app, 0.25, 0.5).tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: menuRow(app, "Advanced Options"))
        _ = XCTWaiter.wait(for: [gone], timeout: 5)
        pause(0.6)
    }

    func testPlayerShots() {
        let app = launchHarbor(["--fixtures", "detail", "--fixture-streams", "--phone-picker", "--phone-player-demo"])
        expect(app, "phone-picker", timeout: 40)
        tap(app, "stream-0", timeout: 30)
        expect(app, "player-screen", timeout: 20)
        if element(app, "player-resume").waitForExistence(timeout: 2) { tap(app, "player-resume") }
        // The phone held sideways, as the player turns itself, so the shots come out landscape.
        XCUIDevice.shared.orientation = .landscapeLeft
        _ = element(app, "player-fixture-picture").waitForExistence(timeout: 25)
        pause(2)

        // The HUD, playing.
        wakeHUD(app)
        for id in ["player-close", "player-fill", "player-volume", "player-back", "player-playpause", "player-ahead",
                   "player-title", "player-gear", "player-airplay", "player-lock", "player-scrubber", "player-elapsed", "player-remaining"] {
            expect(app, id, timeout: 5)
        }
        XCTAssertEqual(element(app, "player-volume").value as? String, "40%", "the volume capsule reads the fixture's level")
        pause(1)
        snap("01-hud-playing")

        // Paused.
        tap(app, "player-playpause", timeout: 5)
        pause(1)
        snap("02-paused")

        // The gear menu and each of its lists.
        shootMenu(app, nil, "03-gear-menu")
        shootMenu(app, "Volume Boost", "04-gear-volume-boost")
        shootMenu(app, "Playback Speed", "05-gear-playback-speed")
        shootMenu(app, "English - E-AC3 5.1", "06-gear-audio")
        shootMenu(app, "None", "07-gear-subtitles")
        shootMenu(app, "Advanced Options", "08-gear-advanced")

        // Playing again, the HUD away: a swipe up on the left half shows the brightness pill.
        wakeHUD(app)
        tap(app, "player-playpause", timeout: 5)
        hideHUD(app)
        point(app, 0.2, 0.7).press(forDuration: 0.05, thenDragTo: point(app, 0.2, 0.4))
        expect(app, "player-brightness-pill", timeout: 5)
        pause(0.5)
        snap("09-brightness")

        // A swipe on the right half: the volume capsule on its own.
        point(app, 0.8, 0.7).press(forDuration: 0.05, thenDragTo: point(app, 0.8, 0.45))
        expect(app, "player-volume", timeout: 5)
        pause(0.5)
        snap("10-volume")
        pause(6)

        // A press and hold on the right side plays at 2x (under fixtures the pill stays a while after).
        point(app, 0.85, 0.55).press(forDuration: 1.5)
        expect(app, "player-rate-pill", timeout: 3)
        snap("11-hold-2x")
        pause(6.5)

        // A double tap on the left steps back, with the ripple and its seconds.
        point(app, 0.15, 0.55).doubleTap()
        pause(0.25)
        snap("12-double-tap")
        pause(4.5)

        // The HUD at rest again, for a last look.
        wakeHUD(app)
        pause(1)
        snap("13-hud-again")
    }
}
