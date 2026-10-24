import XCTest

/// Account → Trackers on fixtures (`--fixtures shell`, PhoneTrackersFixtures): Trakt needs a
/// reconnect, Simkl and AniList are connected, MyAnimeList and Letterboxd are not. A sign-out and a
/// Sync now run offline.
///
/// The English UI is assumed.
final class TrackersTests: XCTestCase {
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

    /// Waits until `predicate` holds for the element; a miss fails with the screen attached.
    private func wait(_ app: XCUIApplication, _ id: String, _ predicate: String, _ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let found = expect(app, id, file: file, line: line)
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: found)
        if XCTWaiter().wait(for: [match], timeout: timeout) != .completed {
            snap(app, "wait-\(id)")
            XCTFail("\(id): \(what) (label \"\(found.label)\", value \"\(String(describing: found.value))\")", file: file, line: line)
        }
    }

    /// A button that has left the page. On a slow simulator one UI query can take longer than 15 s, so
    /// this polls (`waitForNonExistence`) with a long budget, on the typed buttons query: a
    /// `descendants(.any)` snapshot of the whole page is the slow one (run 39730552524).
    private func buttonGone(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 45) -> Bool {
        app.buttons[id].waitForNonExistence(timeout: timeout)
    }

    /// The account sheet's Trackers screen.
    private func openTrackers() -> XCUIApplication {
        let app = launchHarbor(["--fixtures", "shell"])
        tap(app, "account-button", timeout: 30)
        expect(app, "account-sheet")
        tap(app, "account-trackers")
        expect(app, "trackers-screen", timeout: 20)
        return app
    }

    /// The back button of a tracker's page (it carries the Trackers screen's title).
    private func back(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons["Trackers"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no back button")
        button.tap()
    }

    // MARK: Tests

    /// Every tracker the TV signs in to is listed with its state.
    func testListShowsEachTrackersState() throws {
        let app = openTrackers()
        wait(app, "tracker-trakt", "value == 'Reconnect needed'", "Trakt does not ask for a reconnect")
        wait(app, "tracker-simkl", "value == 'Connected as harbor-fan'", "Simkl is not connected")
        wait(app, "tracker-anilist", "value == 'Connected as HarborFan'", "AniList is not connected")
        wait(app, "tracker-mal", "value == 'Not connected'", "MyAnimeList is connected")
        wait(app, "tracker-letterboxd", "value == 'Not connected'", "Letterboxd is connected")
        snap(app, "trackers-list")
    }

    /// Sync now stamps the time; Disconnect (confirmed) signs Simkl out, here and on the list.
    func testSyncAndSignOut() throws {
        let app = openTrackers()
        tap(app, "tracker-simkl")
        expect(app, "tracker-page-simkl")
        wait(app, "tracker-page-status", "label == 'Connected as harbor-fan'", "the page does not show the session")
        wait(app, "tracker-synced", "label BEGINSWITH 'Synced'", "Simkl's last sync is not shown")
        expect(app, "tracker-list-total")
        snap(app, "tracker-simkl")

        tap(app, "tracker-sync")
        wait(app, "tracker-synced", "label == 'Synced just now'", "Sync now did not stamp the time")

        let signOut = expect(app, "tracker-signout")
        if !signOut.isHittable { app.swipeUp() }
        signOut.tap()
        let confirm = element(app, "tracker-signout-confirm")
        if confirm.waitForExistence(timeout: 10) {
            confirm.tap()
        } else {
            let byLabel = app.buttons.matching(NSPredicate(format: "label == 'Disconnect'")).element(boundBy: 1)
            XCTAssertTrue(byLabel.waitForExistence(timeout: 5), "no Disconnect confirmation")
            byLabel.tap()
        }
        wait(app, "tracker-page-status", "label == 'Not connected'", "Simkl is still signed in", timeout: 45)
        // The signed-out layout is up once Connect is; then the two signed-in buttons are checked.
        expect(app, "tracker-connect", timeout: 45)
        XCTAssertTrue(buttonGone(app, "tracker-signout"), "Disconnect stayed after the sign-out")
        XCTAssertTrue(buttonGone(app, "tracker-sync"), "Sync now stayed after the sign-out")
        snap(app, "tracker-simkl-signed-out")

        back(app)
        wait(app, "tracker-simkl", "value == 'Not connected'", "the list still shows Simkl connected")
        wait(app, "tracker-anilist", "value == 'Connected as HarborFan'", "the sign-out reached AniList")
    }

    /// A signed-out tracker's page offers Connect; on fixtures it says so rather than reaching out.
    func testSignedOutPageOffersConnect() throws {
        let app = openTrackers()
        tap(app, "tracker-mal")
        wait(app, "tracker-page-status", "label == 'Not connected'", "MyAnimeList's page shows a session")
        XCTAssertFalse(element(app, "tracker-signout").exists, "a signed-out tracker offers Disconnect")
        tap(app, "tracker-connect")
        expect(app, "tracker-note")
    }
}
