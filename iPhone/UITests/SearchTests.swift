import XCTest

/// The Search tab on the shell fixtures (`--fixtures shell`): SearchModel and AISearchModel answer
/// from App/Shared/Search/SearchFixtures.swift, so nothing here needs the network. A test types
/// into the iOS 26 search field; the others seed the query with `--query` (like the TV's Search
/// screenshots), so a keyboard that will not come up in the simulator fails one test, not all.
///
/// The English UI is assumed.
final class SearchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = launchHarbor(["--fixtures", "shell"] + arguments)
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        // A screenshot the runner cannot deliver in time is evidence lost, not a failed test.
        let lenient = XCTExpectedFailure.Options()
        lenient.isStrict = false
        var shot: XCUIScreenshot?
        XCTExpectFailure("the screenshot service can time out", options: lenient) {
            shot = app.screenshot()
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

    /// Swipes the page up (slowly, at most eight times) until the element can take a tap.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) -> XCUIElement {
        var swipes = 0
        while !element.isHittable && swipes < 8 {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        return element
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        if XCTWaiter().wait(for: [match], timeout: timeout) != .completed {
            XCTFail("label is \"\(element.label)\", not \"\(label)\"", file: file, line: line)
        }
    }

    private func openSearchTab(_ app: XCUIApplication) {
        tapTab(app, "Search")
        expect(app, "search-screen")
    }

    /// Every group the fixture answers with, by the rail that holds it.
    private func expectGroupedResults(_ app: XCUIApplication) {
        expect(app, "rail-Movies", timeout: 30)
        expect(app, "rail-Shows")
        expect(app, "rail-People")
        expect(app, "rail-Anime")
        expect(app, "rail-Fixture Addon")
        expect(app, "person-Timothée Chalamet")
    }

    /// Leaves the title page: the link sheet's close button, else the bar's Back.
    private func closeDetail(_ app: XCUIApplication) {
        if element(app, "detail-close").exists {
            element(app, "detail-close").tap()
        } else {
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    private func openFirstMovie(_ app: XCUIApplication) {
        tap(app, "tile-fx-search-m-0")
        expect(app, "detail-page")
        XCTAssertEqual(expect(app, "detail-name").label, "Dune: Part Two")
        snap(app, "search-result-opened")
        closeDetail(app)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, "detail-page"))
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 20), .completed, "the title page did not close")
    }

    // MARK: Tests

    /// Type a query in the search field: the results group, a result opens, and the query is
    /// filed under Recent once the field is cleared.
    func testTypeQueryGroupsResultsAndOpensOne() throws {
        let app = launch([])
        openSearchTab(app)
        snap(app, "search-empty")

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field")
        field.tap()
        field.typeText("dune")
        expectGroupedResults(app)
        snap(app, "search-grouped")

        openFirstMovie(app)

        // Clear the field (a delete per letter): the empty screen lists the query under Recent.
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        expect(app, "search-recent")
        expect(app, "recent-dune")
        snap(app, "search-recent")
    }

    /// The same results from a seeded query: grouped rails, the kind chips, and a stub title page.
    func testSeededQueryGroupsResultsAndOpensOne() throws {
        let app = launch(["--query", "dune"])
        openSearchTab(app)
        expectGroupedResults(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chip-All")).firstMatch.waitForExistence(timeout: 10),
                      "no All chip")
        snap(app, "search-seeded")

        // A chip narrows the results to its group.
        let movies = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chip-Movies")).firstMatch
        XCTAssertTrue(movies.waitForExistence(timeout: 10), "no Movies chip")
        movies.tap()
        expect(app, "rail-Movies")
        XCTAssertFalse(element(app, "rail-Shows").exists, "Shows stayed under the Movies chip")
        snap(app, "search-chip-movies")

        openFirstMovie(app)
    }

    /// A person hit pushes their page: the name, Known For and the filmography with its count; a
    /// filmography title opens, and a Rating chip cuts the filmography (the fixture person from
    /// iPhone/Sources/Detail/PhonePersonPage.swift).
    func testPersonPageShowsFilmographyAndOpensATitle() throws {
        let app = launch(["--query", "dune"])
        openSearchTab(app)
        let tile = expect(app, "person-Timothée Chalamet", timeout: 30)
        reveal(app, tile).tap()

        expect(app, "person-page")
        waitForLabel(expect(app, "person-name"), "Timothée Chalamet")
        expect(app, "rail-knownFor")
        expect(app, "rail-collaborators")
        snap(app, "person-page")

        // The fixture bio runs past four lines, so Read more opens it and Show less closes it again.
        let more = expect(app, "person-bio-more")
        waitForLabel(more, "Read more")
        more.tap()
        waitForLabel(more, "Show less")
        more.tap()
        waitForLabel(more, "Read more")

        // The Movies section of the filmography, and a title in it.
        let movies = expect(app, "rail-film:movies")
        expect(app, "rail-film:shows")
        waitForLabel(expect(app, "person-count"), "5 of 5")
        let wonka = movies.descendants(matching: .any).matching(identifier: "tile-fx-person-m-1").firstMatch
        XCTAssertTrue(wonka.waitForExistence(timeout: 10), "no Wonka in the Movies section")
        reveal(app, wonka)
        snap(app, "person-filmography")
        wonka.tap()
        expect(app, "detail-page")
        XCTAssertEqual(expect(app, "detail-name").label, "Wonka")
        snap(app, "person-title-opened")
        closeDetail(app)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, "detail-page"))
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 20), .completed, "the title page did not close")

        // Rated 8+: Wonka (7.1) leaves, Dune: Part Two (8.5) and Homeland (8.3) stay.
        expect(app, "person-page")
        let rated = expect(app, "chip-Rated 8+")
        reveal(app, rated).tap()
        waitForLabel(element(app, "person-count"), "2 of 5")
        let wonkaGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: wonka)
        XCTAssertEqual(XCTWaiter().wait(for: [wonkaGone], timeout: 10), .completed, "Wonka stayed under Rated 8+")
        XCTAssertTrue(movies.descendants(matching: .any).matching(identifier: "tile-fx-person-m-0").firstMatch.exists,
                      "Dune: Part Two left under Rated 8+")
        // The selected chip is scrolled into view, not left past the right edge of its row.
        let inView = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: rated)
        XCTAssertEqual(XCTWaiter().wait(for: [inView], timeout: 5), .completed, "the selected Rated 8+ chip is out of view")
        snap(app, "person-rated-8")
    }

    /// A Frequent Collaborator pushes their page on the tab's path; a title opened from it pushes
    /// above it, and Back comes down to the collaborator, then to the first person.
    func testCollaboratorPageOpensATitleAndBackLandsOnIt() throws {
        let app = launch(["--query", "dune"])
        openSearchTab(app)
        let tile = expect(app, "person-Timothée Chalamet", timeout: 30)
        reveal(app, tile).tap()
        waitForLabel(expect(app, "person-name"), "Timothée Chalamet")

        let villeneuve = expect(app, "collaborator-137427")
        reveal(app, villeneuve).tap()
        waitForLabel(expect(app, "person-name"), "Denis Villeneuve")
        snap(app, "collaborator-page")

        let wonka = element(app, "tile-fx-person-m-1")
        XCTAssertTrue(wonka.waitForExistence(timeout: 10), "no Wonka on the collaborator's page")
        reveal(app, wonka).tap()
        expect(app, "detail-page")
        XCTAssertEqual(expect(app, "detail-name").label, "Wonka")
        closeDetail(app)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, "detail-page"))
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 20), .completed, "the title page did not close")

        // Back from the title lands on the collaborator, not past them.
        expect(app, "person-page")
        waitForLabel(expect(app, "person-name"), "Denis Villeneuve")
        snap(app, "collaborator-back")

        app.navigationBars.buttons.firstMatch.tap()
        waitForLabel(expect(app, "person-name"), "Timothée Chalamet")
    }

    /// A query nothing answers says so.
    func testNothingFound() throws {
        let app = launch(["--query", "nothing"])
        openSearchTab(app)
        expect(app, "empty-state", timeout: 30)
        snap(app, "search-nothing")
    }

    /// AI search: the chip turns AI mode on, the picks arrive on their own, and a pick opens.
    func testAISearchPicks() throws {
        let app = launch(["--query", "dune part two"])
        openSearchTab(app)
        tap(app, "chip-AI search", timeout: 30)
        expect(app, "search-ai-section")
        expect(app, "ai-result-fx-ai-0", timeout: 40)
        expect(app, "ai-result-fx-ai-1")
        snap(app, "search-ai-picks")

        tap(app, "ai-result-fx-ai-0")
        expect(app, "detail-page")
        snap(app, "search-ai-opened")
        closeDetail(app)
    }
}
