import XCTest

/// The poster-grid page behind See all, a streaming service and an addon, on the fixture rooms
/// (`--fixtures shell|bands`): open a row → see all → the title page, infinite load to the end, the
/// genre filter and sort, a failed page and its Try again, the chips of a service and an addon, and
/// the column count at large text. Every step attaches a screenshot. Nothing here touches the network.
///
/// The English UI is assumed: menu items and buttons are looked up by their English labels.
final class CatalogTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = launchHarbor(arguments)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "no tab bar")
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
            // The element tree goes with the failure, so a miss can be read from the run.
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "hierarchy-missing-\(id)"
            tree.lifetime = .keepAlways
            add(tree)
            snap(app, "missing-\(id)")
            XCTFail("no element \(id)", file: file, line: line)
        }
        return found
    }

    /// Drags the page by `fraction` of the screen between two points, never `app.swipeUp()`: a swipe
    /// starts mid-screen, which near the top of Home is the 500-pt hero, and a drag that starts and ends
    /// on its art opens the title page instead of scrolling. On the feed, while the hero holds the start
    /// point, the drag starts under it (or ends above it when it reaches that low). The drag is slow, so
    /// it moves the list about its own length and does not fling past what the test looks for.
    private func drag(_ app: XCUIApplication, up: Bool = true, by fraction: CGFloat = 0.4, heroAware: Bool = false) {
        var low: CGFloat = 0.72
        var high: CGFloat = low - fraction
        let hero = element(app, "hero-carousel")
        if heroAware, hero.exists {
            let height = max(1, app.frame.height)
            let top = hero.frame.minY / height
            let bottom = hero.frame.maxY / height
            if low > top && low < bottom {
                if bottom < 0.8 {
                    low = bottom + 0.03
                    high = low - fraction
                } else {
                    high = min(high, top - 0.06)
                }
            }
        }
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: low))
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: max(0.08, high)))
        if up {
            lower.press(forDuration: 0.05, thenDragTo: upper)
        } else {
            upper.press(forDuration: 0.05, thenDragTo: lower)
        }
    }

    /// Leaves the title page: the link sheet's close button, else the bar's Back.
    private func closeDetail(_ app: XCUIApplication) {
        if element(app, "detail-close").exists {
            element(app, "detail-close").tap()
        } else {
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    /// A drag that opened the title page anyway: kept as a screenshot, then closed.
    private func closeStrayTitle(_ app: XCUIApplication) {
        guard element(app, "detail-page").exists else { return }
        snap(app, "scroll-opened-title")
        closeDetail(app)
        _ = gone(app, "detail-page", timeout: 10)
    }

    /// Scrolls until the element can be tapped (the feed, or a grid's Try again).
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = expect(app, id, timeout: 30, file: file, line: line)
        var drags = 0
        while !target.isHittable && drags < 16 {
            drag(app, heroAware: true)
            closeStrayTitle(app)
            drags += 1
        }
        XCTAssertFalse(element(app, "detail-page").exists, "a title page covers the page", file: file, line: line)
        return target
    }

    /// Drags the grid up, then back down, until the element exists (a lazy grid builds it once it is
    /// near), at most `limit` drags each way. One query per drag keeps the element snapshots of the
    /// grid few, and a slow drag gives the grid no fling to lay out while pages land.
    private func scrollTo(_ app: XCUIApplication, _ id: String, limit: Int = 30) -> Bool {
        let target = element(app, id)
        if target.exists { return true }
        for _ in 0..<limit {
            drag(app)
            if target.exists { return true }
        }
        if target.waitForExistence(timeout: 5) { return true }
        for _ in 0..<limit {
            drag(app, up: false)
            if target.exists { return true }
        }
        return target.waitForExistence(timeout: 5)
    }

    /// Waits for the grid's progress marker (one static element outside the lazy grid) to match a predicate
    /// on `label` ("N titles") or `value` ("more" / "end").
    private func progress(_ app: XCUIApplication, _ format: String, _ pattern: String, timeout: TimeInterval) -> Bool {
        let met = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, pattern), object: element(app, "catalog-progress"))
        return XCTWaiter().wait(for: [met], timeout: timeout) == .completed
    }

    /// Drags the grid up, slowly, until the marker's `label` ("N titles") matches `pattern`, or with
    /// `value: true` until its value does ("more" / "end"): pages are followed through that one element,
    /// never by probing cells of the lazy grid, which a busy app times out on.
    private func scrollUntilProgress(_ app: XCUIApplication, _ pattern: String, value: Bool = false, limit: Int = 40) -> Bool {
        let format = value ? "value MATCHES %@" : "label MATCHES %@"
        for _ in 0..<limit {
            if progress(app, format, pattern, timeout: 2) { return true }
            drag(app)
        }
        return progress(app, format, pattern, timeout: 15)
    }

    private func scrollUntilCount(_ app: XCUIApplication, _ pattern: String, limit: Int = 40) -> Bool {
        scrollUntilProgress(app, pattern, limit: limit)
    }

    private func gone(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20) -> Bool {
        let missing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, id))
        return XCTWaiter().wait(for: [missing], timeout: timeout) == .completed
    }

    private func menuItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func openSeeAll(_ app: XCUIApplication) {
        let seeAll = reveal(app, "seeall-Trending This Week")
        // A plain tap, as before: it scrolls the button into view itself. (A tap at a centre coordinate of a
        // frame that is not hittable can land on whatever covers it and never opens the page.)
        seeAll.tap()
        if !element(app, "route-catalog").waitForExistence(timeout: 8) {
            // Once more, with the tree kept: the first tap may have landed while the feed was still settling.
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "hierarchy-see-all-first-tap"
            tree.lifetime = .keepAlways
            add(tree)
            snap(app, "see-all-first-tap")
            reveal(app, "seeall-Trending This Week").tap()
        }
        expect(app, "route-catalog")
        expect(app, "tile-t-0")
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
    }

    // MARK: Tests

    /// Open a row → See all → a title opens the title page → Done → Back to the feed.
    func testSeeAllOpensDetail() throws {
        let app = launch(["--fixtures", "shell"])
        openSeeAll(app)
        snap(app, "catalog-see-all")
        expect(app, "filter-genre")
        expect(app, "filter-year")
        expect(app, "filter-sort")
        // The twelve seeded titles leave the footer in view, so the next pages (15 each) can already be
        // landing: the count is 12, 27 or 42 here, and settles on 42 once the end shows.
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", "(12|27|42) titles"), object: element(app, "catalog-count"))
        XCTAssertEqual(XCTWaiter().wait(for: [counted], timeout: 30), .completed, "count reads \(element(app, "catalog-count").label)")

        element(app, "tile-t-0").tap()
        expect(app, "detail-page", timeout: 30)
        XCTAssertEqual(expect(app, "detail-name").label, "Dune: Part Two")
        snap(app, "catalog-detail")
        closeDetail(app)
        XCTAssertTrue(gone(app, "detail-page"), "the title page did not close")

        back(app)
        expect(app, "feed-home")
    }

    /// Scrolling to the end reads the next pages one after the other, then says it is everything.
    func testInfiniteLoadReachesTheEnd() throws {
        let app = launch(["--fixtures", "shell"])
        openSeeAll(app)
        expect(app, "catalog-progress")
        // Pages are 12, then 15 and 15 more; one may land before the next is looked at.
        XCTAssertTrue(scrollUntilCount(app, "(27|42) titles"), "the second page never loaded: \(element(app, "catalog-progress").label)")
        snap(app, "catalog-page-two")
        XCTAssertTrue(scrollUntilCount(app, "42 titles"), "the third page never loaded: \(element(app, "catalog-progress").label)")
        // The last page is only known to be the last when the footer asks for one more and gets nothing:
        // the footer exists only near the bottom of the grid, so keep dragging until the marker says "end".
        XCTAssertTrue(scrollUntilProgress(app, "end", value: true), "the list never said it was complete: \(element(app, "catalog-progress").label), \(String(describing: element(app, "catalog-progress").value))")
        // The end is in reach: a few more drags if the footer is not on screen yet, one query each.
        let end = element(app, "catalog-end")
        var drags = 0
        while !end.waitForExistence(timeout: 5) && drags < 6 {
            drag(app)
            drags += 1
        }
        XCTAssertTrue(end.exists, "no end of list")
        snap(app, "catalog-end")
        XCTAssertTrue(element(app, "tile-fx-trending-41").waitForExistence(timeout: 10), "the last title is missing")
    }

    /// The genre chip filters what has loaded; Clear brings the rest back. Sort reorders.
    func testGenreFilterAndSort() throws {
        let app = launch(["--fixtures", "shell"])
        openSeeAll(app)

        element(app, "filter-genre").tap()
        XCTAssertTrue(menuItem(app, "Thriller").waitForExistence(timeout: 10), "no Thriller in the genre menu")
        snap(app, "catalog-genre-menu")
        menuItem(app, "Thriller").tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Thriller"), object: element(app, "filter-genre"))
        XCTAssertEqual(XCTWaiter().wait(for: [chosen], timeout: 10), .completed, "the genre chip did not take the choice")

        XCTAssertTrue(element(app, "tile-t-0").exists, "the Thriller title was filtered out")

        // The short list keeps asking for pages until the feed ends; none of them is a Thriller.
        XCTAssertTrue(scrollTo(app, "catalog-end"), "the feed never ended")
        XCTAssertFalse(element(app, "tile-fx-trending-12").exists, "a title outside the genre shows")
        snap(app, "catalog-genre-filtered")

        element(app, "chip-Clear").tap()
        XCTAssertTrue(scrollTo(app, "tile-fx-trending-12"), "Clear did not bring the other titles back")

        element(app, "filter-sort").tap()
        XCTAssertTrue(menuItem(app, "A to Z").waitForExistence(timeout: 10), "no A to Z in the sort menu")
        menuItem(app, "A to Z").tap()
        snap(app, "catalog-sorted")
    }

    /// A page that fails shows Try again under the grid, and the retry reads it.
    func testFailedPageRetries() throws {
        let app = launch(["--fixtures", "shell", "--phone-catalog-fail"])
        openSeeAll(app)
        XCTAssertTrue(scrollTo(app, "catalog-retry"), "no Try again after the failed page")
        snap(app, "catalog-page-failed")
        reveal(app, "catalog-retry").tap()
        XCTAssertTrue(scrollTo(app, "tile-fx-trending-12"), "the retry did not load the next page")
        XCTAssertTrue(gone(app, "catalog-retry"), "Try again stayed up")
    }

    /// A service page: one chip per category over the grid; a chip loads its own titles.
    func testServicePageChips() throws {
        let app = launch(["--fixtures", "bands"])
        reveal(app, "tile-service:fixture-0").tap()
        expect(app, "route-service")
        expect(app, "chip-Popular")
        expect(app, "chip-Top Rated")
        expect(app, "tile-fx-svc-fixture-0-popular-0")
        snap(app, "catalog-service")

        element(app, "chip-Top Rated").tap()
        expect(app, "tile-fx-svc-fixture-0-toprated-0")
        XCTAssertTrue(gone(app, "tile-fx-svc-fixture-0-popular-0"), "the old chip's titles stayed")
        snap(app, "catalog-service-top-rated")
    }

    /// An addon page: one chip per catalog, each read through the feed.
    func testAddonPageChips() throws {
        let app = launch(["--fixtures", "bands"])
        reveal(app, "tile-addon:https://addon.invalid/fixture-0").tap()
        expect(app, "route-addon")
        expect(app, "chip-Popular · movie")
        expect(app, "chip-Featured · series")
        expect(app, "tile-fx-addon-popular-0", timeout: 30)
        snap(app, "catalog-addon")

        element(app, "chip-Featured · series").tap()
        expect(app, "tile-fx-addon-featured-0", timeout: 30)
        snap(app, "catalog-addon-featured")
    }

    /// Three posters across at the normal text size.
    func testThreeColumns() throws {
        let app = launch(["--fixtures", "shell"])
        openSeeAll(app)
        let first = expect(app, "tile-t-0").frame
        let third = expect(app, "tile-t-2").frame
        XCTAssertGreaterThan(third.minX, first.minX + 10, "the third poster is not beside the first")
        XCTAssertEqual(third.minY, first.minY, accuracy: 2, "the third poster is on another row")
    }

    /// Two across at accessibility text sizes.
    func testTwoColumnsAtLargeText() throws {
        let app = launch(["--fixtures", "shell", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        openSeeAll(app)
        let first = expect(app, "tile-t-0").frame
        let third = expect(app, "tile-t-2").frame
        XCTAssertEqual(third.minX, first.minX, accuracy: 2, "the third poster is not under the first")
        XCTAssertGreaterThan(third.minY, first.minY + 10, "the third poster is on the first row")
        snap(app, "catalog-large-text")
    }
}
