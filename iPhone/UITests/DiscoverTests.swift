import XCTest

/// The Discover tab on the fixture profile (`--fixtures shell`): its bands, the pages they open, and
/// the Discovery Queue's swipes and buttons. Offline, the screen draws its own fixture content (six
/// picks in the queue, two award bodies, four genres), so none of this touches the network.
///
/// The English UI is assumed.
final class DiscoverTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = launchHarbor(arguments)
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        // The screen, not the app: it needs no element snapshot, so a busy app cannot time it out.
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

    /// Waits until the element's label contains `text`; a miss fails with the label it did have.
    private func expectLabel(_ app: XCUIApplication, _ id: String, contains text: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let found = expect(app, id, file: file, line: line)
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: found)
        let result = XCTWaiter().wait(for: [match], timeout: timeout)
        if result != .completed {
            snap(app, "label-\(id)")
            XCTFail("\(id) reads \"\(found.label)\", not \"\(text)\"", file: file, line: line)
        }
    }

    /// The shell, on the Discover tab, with its first band drawn.
    private func openDiscover() -> XCUIApplication {
        let app = launch(["--fixtures", "shell"])
        tapTab(app, "Discover")
        expect(app, "discover", timeout: 30)
        return app
    }

    /// Scrolls the Discover feed until the element is on screen (the bands are lazy). A slow drag
    /// between two points, as on the feed, not `app.swipeUp()`: a swipe that starts on a card and ends
    /// on it can open it instead of scrolling.
    private func reveal(_ app: XCUIApplication, _ id: String) {
        let target = element(app, id)
        var tries = 0
        while !target.isHittable && tries < 14 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
            from.press(forDuration: 0.05, thenDragTo: to)
            tries += 1
        }
        XCTAssertTrue(target.waitForExistence(timeout: 5), "\(id) never came into view")
    }

    private func openQueue(_ app: XCUIApplication) {
        reveal(app, "discover-queue-card")
        tap(app, "discover-queue-card")
        expect(app, "queue")
        expect(app, "queue-card")
        expectLabel(app, "queue-position", contains: "1 of 6")
    }

    // MARK: Bands

    func testDiscoverBands() throws {
        let app = openDiscover()
        expect(app, "discover-queue-card")
        snap(app, "discover-top")
        reveal(app, "discover-awards")
        expect(app, "award-oscars")
        snap(app, "discover-awards")
        reveal(app, "discover-voyage")
        snap(app, "discover-voyage")
        reveal(app, "discover-genres")
        expect(app, "genre-Action")
        expect(app, "genre-surprise")
        snap(app, "discover-genres")
    }

    /// Leaves the title page: the link sheet's close button, else the bar's Back.
    private func closeDetail(_ app: XCUIApplication) {
        if element(app, "detail-close").exists {
            element(app, "detail-close").tap()
        } else {
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    // MARK: Pages

    func testAwardPageOpensAWinner() throws {
        let app = openDiscover()
        reveal(app, "award-oscars")
        tap(app, "award-oscars")
        expect(app, "award-page")
        expect(app, "award-title")
        snap(app, "award-page")
        tap(app, "award-winner-best-picture#0")
        expect(app, "detail-page")
        XCTAssertEqual(expect(app, "detail-name").label, "Past Lives")
        closeDetail(app)
    }

    func testGenrePageShowsTitles() throws {
        let app = openDiscover()
        reveal(app, "genre-Action")
        tap(app, "genre-Action")
        expect(app, "genre-page")
        XCTAssertTrue(element(app, prefix: "tile-", in: app).waitForExistence(timeout: 20), "no titles on the genre page")
        snap(app, "genre-page")
    }

    func testVoyagePageListsDirections() throws {
        let app = openDiscover()
        reveal(app, "discover-voyage")
        tap(app, "discover-voyage")
        expect(app, "voyage-page")
        expect(app, "voyage-theme-fixture-noir")
        snap(app, "voyage-page")
    }

    private func element(_ app: XCUIApplication, prefix: String, in scope: XCUIApplication) -> XCUIElement {
        scope.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    // MARK: The Discovery Queue

    /// A swipe left skips: the card goes, the deck is one shorter and the tally counts it.
    func testQueueSwipeLeftSkips() throws {
        let app = openDiscover()
        openQueue(app)
        snap(app, "queue-start")
        expectLabel(app, "queue-tally", contains: "Skipped 0")

        expect(app, "queue-card").swipeLeft()
        expectLabel(app, "queue-tally", contains: "Skipped 1")
        expectLabel(app, "queue-position", contains: "1 of 5")
        snap(app, "queue-after-skip")
    }

    /// A swipe up saves to the watchlist and moves on: the deck keeps the card, the tally counts it.
    func testQueueSwipeUpSaves() throws {
        let app = openDiscover()
        openQueue(app)
        expectLabel(app, "queue-tally", contains: "Saved 0")

        expect(app, "queue-card").swipeUp()
        expectLabel(app, "queue-tally", contains: "Saved 1")
        expectLabel(app, "queue-position", contains: "2 of 6")
        snap(app, "queue-after-save")
    }

    /// A swipe right accepts: the title opens over the shell and the tally counts it.
    func testQueueSwipeRightOpensTitle() throws {
        let app = openDiscover()
        openQueue(app)

        expect(app, "queue-card").swipeRight()
        expect(app, "detail-page")
        snap(app, "queue-after-accept")
        closeDetail(app)
        expectLabel(app, "queue-tally", contains: "Opened 1")
    }

    /// Every swipe has a button: skip, save and watch change the same state.
    func testQueueButtons() throws {
        let app = openDiscover()
        openQueue(app)

        tap(app, "queue-skip")
        expectLabel(app, "queue-tally", contains: "Skipped 1")
        expectLabel(app, "queue-position", contains: "1 of 5")

        tap(app, "queue-watchlist")
        expectLabel(app, "queue-tally", contains: "Saved 1")
        expectLabel(app, "queue-position", contains: "2 of 5")

        tap(app, "queue-accept")
        expect(app, "detail-page")
        closeDetail(app)
        expectLabel(app, "queue-tally", contains: "Opened 1")
        snap(app, "queue-after-buttons")
    }

    /// The deck can be worked through: skipping every card ends on the empty state, and Done leaves.
    func testQueueRunsOutAndDoneLeaves() throws {
        let app = openDiscover()
        openQueue(app)
        for done in 1...6 {
            tap(app, "queue-skip")
            // The buttons are off while a card flies away: wait for the answer to land before the next tap.
            // (The last card takes the header with it, so that one is waited for as the empty state below.)
            if done < 6 { expectLabel(app, "queue-tally", contains: "Skipped \(done)") }
        }
        expect(app, "queue-empty")
        snap(app, "queue-empty")
        tap(app, "queue-done")
        expect(app, "discover")
    }
}
