import XCTest

/// The Library tab on the fixture library (`--fixtures shell`, PhoneLibraryFixtures): each segment
/// shows its titles, the type filter and the sort change what shows and in what order, a list row
/// swipes to Remove, the More menu opens Stats as a story, the Calendar chip opens the Calendar and
/// the Collections chip Collections, and a failed read shows the error plate. Every step attaches a screenshot.
///
/// The English UI is assumed: segments, menu items and buttons are looked up by their English labels.
final class LibraryTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

    /// Launches on the fixtures and opens the Library tab on its Library room.
    private func launchLibrary(_ extra: [String] = []) -> XCUIApplication {
        let app = launchHarbor(["--fixtures", "shell"] + extra)
        tapTab(app, "Library")
        expect(app, "library", timeout: 30)
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        // The screen, not the app: it needs no element snapshot, so a busy app cannot time it out.
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

    private func gone(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20) -> Bool {
        let missing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, id))
        return XCTWaiter().wait(for: [missing], timeout: timeout) == .completed
    }

    /// The hittable element labelled `label` (a menu item, a swipe button): another tab's screen can
    /// hold an element with the same label off screen.
    private func tapLabel(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let query = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
                hit.tap()
                return
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        snap(app, "missing-label-\(label)")
        XCTFail("nothing hittable labelled \(label)", file: file, line: line)
    }

    /// Picks a segment of the Library's segmented control.
    private func segment(_ app: XCUIApplication, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let control = expect(app, "library-filters", file: file, line: line)
        let button = control.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(label) segment", file: file, line: line)
        button.tap()
    }

    /// Waits for the invisible order marker to read `names` in this order.
    private func expectOrder(_ app: XCUIApplication, _ names: [String], timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let marker = expect(app, "library-order", file: file, line: line)
        let joined = names.joined(separator: "|")
        let met = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", joined), object: marker)
        if XCTWaiter().wait(for: [met], timeout: timeout) != .completed {
            snap(app, "order-\(names.first ?? "none")")
            XCTFail("the library reads \(String(describing: marker.value)), not \(joined)", file: file, line: line)
        }
    }

    // MARK: Tests

    /// Saved, Watchlist, In progress and Watched each show their own titles.
    func testSegmentsShowTheirTitles() throws {
        let app = launchLibrary()
        expect(app, "tile-lib-past-lives")
        expectOrder(app, ["Past Lives", "The Bear", "Dune: Part Two", "Poor Things"])
        snap(app, "library-saved")

        segment(app, "Watchlist")
        expect(app, "tile-lib-oppenheimer")
        expectOrder(app, ["Oppenheimer", "Shōgun", "Fallout"])
        XCTAssertFalse(element(app, "tile-lib-past-lives").exists, "a saved title shows on the watchlist")
        snap(app, "library-watchlist")

        segment(app, "In progress")
        expect(app, "tile-lib-holdovers")
        expectOrder(app, ["The Holdovers", "Ripley"])
        snap(app, "library-in-progress")

        segment(app, "Watched")
        expect(app, "tile-lib-anatomy")
        expectOrder(app, ["Anatomy of a Fall", "Civil War", "Severance"])
        XCTAssertFalse(element(app, "tile-lib-holdovers").exists, "an in-progress title shows under Watched")
        snap(app, "library-watched")

        segment(app, "Saved")
        expectOrder(app, ["Past Lives", "The Bear", "Dune: Part Two", "Poor Things"])
    }

    /// The type menu narrows the tab to films or shows; All brings everything back.
    func testTypeFilter() throws {
        let app = launchLibrary()
        expect(app, "tile-lib-bear")
        expect(app, "library-type").tap()
        tapLabel(app, "Shows")
        expectOrder(app, ["The Bear"])
        snap(app, "library-shows")

        expect(app, "library-type").tap()
        tapLabel(app, "Movies")
        expectOrder(app, ["Past Lives", "Dune: Part Two", "Poor Things"])
        XCTAssertTrue(gone(app, "tile-lib-bear", timeout: 5), "a show is still in the films")

        expect(app, "library-type").tap()
        tapLabel(app, "All")
        expectOrder(app, ["Past Lives", "The Bear", "Dune: Part Two", "Poor Things"])
    }

    /// The sort menu: A-Z, then Year, then back to Recent.
    func testSortChangesOrder() throws {
        let app = launchLibrary()
        expectOrder(app, ["Past Lives", "The Bear", "Dune: Part Two", "Poor Things"])
        expect(app, "library-sort").tap()
        tapLabel(app, "A-Z")
        expectOrder(app, ["Dune: Part Two", "Past Lives", "Poor Things", "The Bear"])
        XCTAssertTrue(app.staticTexts["A to Z"].firstMatch.waitForExistence(timeout: 5), "no A to Z header")
        snap(app, "library-a-z")

        expect(app, "library-sort").tap()
        tapLabel(app, "Year")
        expectOrder(app, ["Dune: Part Two", "Poor Things", "Past Lives", "The Bear"])

        expect(app, "library-sort").tap()
        tapLabel(app, "Recent")
        expectOrder(app, ["Past Lives", "The Bear", "Dune: Part Two", "Poor Things"])
    }

    /// The list layout: a row swipes left to Remove and goes; the grid comes back with the button.
    func testListSwipeRemoves() throws {
        let app = launchLibrary()
        expect(app, "library-layout").tap()
        expect(app, "library-list")
        let row = expect(app, "row-lib-past-lives")
        snap(app, "library-list")

        row.swipeLeft()
        // A long swipe can run the full-swipe action at once; otherwise the Remove button is out.
        if !gone(app, "row-lib-past-lives", timeout: 2) {
            snap(app, "library-swiped")
            tapLabel(app, "Remove")
        }
        XCTAssertTrue(gone(app, "row-lib-past-lives", timeout: 10), "the removed row is still there")
        expectOrder(app, ["The Bear", "Dune: Part Two", "Poor Things"])
        snap(app, "library-removed")

        expect(app, "library-layout").tap()
        expect(app, "library-grid")
        XCTAssertFalse(element(app, "tile-lib-past-lives").exists, "the removed title came back in the grid")
    }

    /// More → Stats opens the story on its first card; a swipe up reaches the next; Close puts it away.
    func testStatsOpensTheStory() throws {
        let app = launchLibrary()
        expect(app, "library-menu").tap()
        tapLabel(app, "Stats")
        expect(app, "wrapped-story")
        expect(app, "wrapped-card-hero")
        snap(app, "wrapped-hero")

        element(app, "wrapped-story").swipeUp()
        expect(app, "wrapped-card-highlights")
        snap(app, "wrapped-highlights")

        expect(app, "wrapped-close").tap()
        XCTAssertTrue(gone(app, "wrapped-story"), "the story did not close")
        expect(app, "library")
    }

    /// The menu's Repair library and Letterboxd open their sheets.
    func testMenuOpensRepairAndLetterboxd() throws {
        let app = launchLibrary()
        expect(app, "library-menu").tap()
        tapLabel(app, "Repair library")
        expect(app, "library-repair")
        snap(app, "library-repair")
        expect(app, "repair-done").tap()
        XCTAssertTrue(gone(app, "library-repair"), "the repair sheet did not close")

        expect(app, "library-menu").tap()
        tapLabel(app, "Letterboxd")
        expect(app, "letterboxd-username")
        snap(app, "library-letterboxd")
        expect(app, "letterboxd-done").tap()
        XCTAssertTrue(gone(app, "letterboxd"), "the Letterboxd sheet did not close")
    }

    /// My Lists from the menu: its chip is lit, and the chip goes back to Saved.
    func testMenuTabOpensAndCloses() throws {
        let app = launchLibrary()
        expect(app, "library-menu").tap()
        tapLabel(app, "My Lists")
        expectOrder(app, ["Dune: Part Two", "Shōgun"])
        expect(app, "chip-My Lists").tap()
        expectOrder(app, ["Past Lives", "The Bear", "Dune: Part Two", "Poor Things"])
    }

    /// The Calendar chip opens the Calendar, the Collections chip Collections.
    func testCalendarAndCollectionsChips() throws {
        let app = launchLibrary()
        expect(app, "chip-Calendar").tap()
        expect(app, "calendar")
        expect(app, "chip-Collections").tap()
        expect(app, "collections-room", timeout: 30)
        expect(app, "chip-Library").tap()
        expect(app, "library")
    }

    /// A library that cannot be read shows the error plate.
    func testFailedReadShowsError() throws {
        let app = launchLibrary(["--phone-library-fail"])
        expect(app, "error-plate")
        snap(app, "library-error")
    }
}
