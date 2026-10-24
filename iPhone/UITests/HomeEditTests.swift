import XCTest

/// Edit Home on the fixture rooms (`--fixtures shell`): Home has no Movies / Shows / Anime chips; rows
/// from those pages, AniList and the addons are added from the editor's source picker; the hero source
/// is picked; a row is moved, removed, swiped away, and Home is reset. Each launch starts from the
/// standard Home (fixture layouts live in memory). Every step attaches a screenshot. Nothing here
/// touches the network.
///
/// Rows are moved with the row page's Move buttons, not by dragging, so the order is deterministic.
/// The English UI is assumed: buttons are looked up by their English labels where they have no id.
final class HomeEditTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch() -> XCUIApplication {
        let app = launchHarbor(["--fixtures", "shell"])
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

    private func tap(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        expect(app, id, timeout: timeout, file: file, line: line).tap()
    }

    private func gone(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20) -> Bool {
        let missing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, id))
        return XCTWaiter().wait(for: [missing], timeout: timeout) == .completed
    }

    /// Scrolls Home up by `fraction` of the screen with a drag that starts below the hero (a drag on
    /// the hero's art can open the title page), as FeedTests does.
    private func scrollFeed(_ app: XCUIApplication, by fraction: CGFloat = 0.4) {
        var from: CGFloat = 0.72
        var to: CGFloat = from - fraction
        let hero = element(app, "hero-carousel")
        if hero.exists {
            let height = max(1, app.frame.height)
            let top = hero.frame.minY / height
            let bottom = hero.frame.maxY / height
            if from > top && from < bottom {
                if bottom < 0.8 {
                    from = bottom + 0.03
                    to = from - fraction
                } else {
                    to = min(to, top - 0.06)
                }
            }
        }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: max(0.08, to)))
        start.press(forDuration: 0.05, thenDragTo: end)
        if element(app, "detail-page").exists {
            snap(app, "scroll-opened-title")
            closeDetail(app)
            _ = gone(app, "detail-page", timeout: 10)
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

    @discardableResult
    private func reveal(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = expect(app, id, timeout: 30, file: file, line: line)
        var drags = 0
        while !target.isHittable && drags < 16 {
            scrollFeed(app)
            drags += 1
        }
        return target
    }

    private func openEditor(_ app: XCUIApplication) {
        tap(app, "home-edit", timeout: 30)
        expect(app, "home-editor-add")
    }

    private func closeEditor(_ app: XCUIApplication) {
        tap(app, "home-editor-done")
        XCTAssertTrue(gone(app, "home-editor-add"), "the editor stayed up")
    }

    /// From the editor: Add a row → search → the entry. The entry turns up once the editor's
    /// all-sources pass has read the other rooms, the trackers and the addons.
    private func addRow(_ app: XCUIApplication, search: String, entry: String) {
        tap(app, "home-editor-add")
        expect(app, "home-source-picker")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search field on the source picker")
        field.tap()
        field.typeText(search)
        let id = "home-source-\(entry)"
        expect(app, id, timeout: 30)
        snap(app, "home-source-\(search)")
        tap(app, id)
        // Adding goes back to the row list, the new row at the bottom.
        expect(app, "home-row-\(entry)")
    }

    /// Back from a page the editor pushed, by its navigation bar (titled `title`).
    private func back(_ app: XCUIApplication, from title: String) {
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "no navigation bar \(title)")
        bar.buttons.element(boundBy: 0).tap()
        expect(app, "home-editor-add")
    }

    // MARK: Tests

    /// Home has no room chips; the editor lists the standard Home: Automatic hero, Continue Watching, Home rows.
    func testHomeHasNoRoomChipsAndOpensTheEditor() throws {
        let app = launch()
        expect(app, "hero-carousel", timeout: 30)
        expect(app, "home-edit")
        XCTAssertFalse(element(app, "chips-Home").exists, "Home still has room chips")
        XCTAssertFalse(element(app, "chip-Movies").exists, "Movies is still a chip")
        XCTAssertFalse(element(app, "chip-Shows").exists, "Shows is still a chip")
        XCTAssertFalse(element(app, "chip-Anime").exists, "Anime is still a chip")
        snap(app, "home-no-chips")

        openEditor(app)
        expect(app, "home-row-Continue Watching")
        expect(app, "home-row-Home rows")
        XCTAssertTrue(expect(app, "home-editor-hero").label.contains("Automatic"), "the hero is not Automatic")
        XCTAssertFalse(expect(app, "home-editor-reset").isEnabled, "Reset is on for the standard Home")
        snap(app, "home-editor")

        // Reorder shows the drag handles; tapping it again leaves.
        tap(app, "home-editor-reorder")
        snap(app, "home-editor-reorder")
        tap(app, "home-editor-reorder")
        closeEditor(app)

        // The footer opens the same editor.
        reveal(app, "home-edit-footer").tap()
        expect(app, "home-editor-add")
        closeEditor(app)
    }

    /// A Movies row (the Top 10 cells, rank and all) added from the picker shows on Home.
    func testAddMoviesTopTenRow() throws {
        let app = launch()
        expect(app, "hero-carousel", timeout: 30)
        openEditor(app)
        addRow(app, search: "Top 10 Movies", entry: "Top 10 Movies Today")
        XCTAssertTrue(expect(app, "home-editor-reset").isEnabled, "Reset is off after an edit")
        snap(app, "home-editor-added-movies")
        closeEditor(app)

        let rail = reveal(app, "rail-Top 10 Movies Today")
        let first = rail.descendants(matching: .any).matching(identifier: "tile-m-0").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "no Top 10 cell in the Movies row")
        XCTAssertEqual(first.label, "1, Dune: Part Two")
        snap(app, "home-movies-row")

        // Already on Home: the picker ticks it and will not add it twice.
        openEditor(app)
        tap(app, "home-editor-add")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Top 10 Movies")
        XCTAssertFalse(expect(app, "home-source-Top 10 Movies Today", timeout: 30).isEnabled, "a row on Home can be added again")
        snap(app, "home-source-on-home")
    }

    /// An AniList list as a row, then as the hero; Off drops the hero and Automatic brings it back.
    func testAniListRowAndHeroSource() throws {
        let app = launch()
        expect(app, "hero-play-t-0", timeout: 30)
        openEditor(app)
        addRow(app, search: "AniList", entry: "AniList · Watching")

        tap(app, "home-editor-hero")
        expect(app, "home-hero-picker")
        snap(app, "home-hero-picker")
        tap(app, "home-hero-AniList · Watching")
        // Picking goes back to the row list, which names the new hero.
        XCTAssertTrue(expect(app, "home-editor-hero").label.contains("AniList · Watching"), "the hero line did not follow")
        closeEditor(app)

        expect(app, "hero-play-fx-anilist-watching-0", timeout: 30)
        reveal(app, "rail-AniList · Watching")
        snap(app, "home-anilist-hero")

        openEditor(app)
        tap(app, "home-editor-hero")
        tap(app, "home-hero-off")
        closeEditor(app)
        XCTAssertTrue(gone(app, "hero-carousel"), "Off kept the hero")
        snap(app, "home-hero-off")

        openEditor(app)
        tap(app, "home-editor-hero")
        tap(app, "home-hero-auto")
        closeEditor(app)
        expect(app, "hero-play-t-0", timeout: 30)
    }

    /// Continue Watching moved below the Home rows, removed, then the standard Home back by Reset;
    /// a row swiped away from the list goes too.
    func testMoveRemoveSwipeAndReset() throws {
        let app = launch()
        expect(app, "rail-Continue Watching", timeout: 30)

        openEditor(app)
        tap(app, "home-row-Continue Watching")
        expect(app, "home-row-remove")
        XCTAssertFalse(expect(app, "home-row-up").isEnabled, "the top row can move up")
        snap(app, "home-row-detail")
        tap(app, "home-row-down")
        back(app, from: "Continue Watching")
        closeEditor(app)

        // Home's rows now come first: Trending This Week sits above Continue Watching.
        let trending = expect(app, "rail-Trending This Week", timeout: 30)
        let resuming = expect(app, "rail-Continue Watching")
        XCTAssertLessThan(trending.frame.minY, resuming.frame.minY, "Continue Watching did not move down")
        reveal(app, "rail-Continue Watching")
        snap(app, "home-cw-moved")

        openEditor(app)
        tap(app, "home-row-Continue Watching")
        tap(app, "home-row-remove")
        XCTAssertTrue(gone(app, "home-row-Continue Watching"), "the removed row is still listed")
        closeEditor(app)
        XCTAssertTrue(gone(app, "rail-Continue Watching"), "the removed row is still on Home")
        snap(app, "home-cw-removed")

        openEditor(app)
        tap(app, "home-editor-reset")
        // A confirmation dialog's button may not carry its identifier to XCUITest: fall back to its label.
        let confirm = element(app, "home-editor-reset-confirm")
        if confirm.waitForExistence(timeout: 5) {
            confirm.tap()
        } else {
            let byLabel = app.buttons["Reset"]
            XCTAssertTrue(byLabel.waitForExistence(timeout: 10), "no Reset button in the dialog")
            byLabel.tap()
        }
        expect(app, "home-row-Continue Watching")
        XCTAssertFalse(expect(app, "home-editor-reset").isEnabled, "Reset is on after a reset")
        snap(app, "home-editor-reset")

        // Swipe-to-delete on the list.
        let row = expect(app, "home-row-Continue Watching")
        row.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "no Delete after a swipe")
        snap(app, "home-editor-swipe")
        delete.tap()
        XCTAssertTrue(gone(app, "home-row-Continue Watching"), "the swiped row is still listed")
        closeEditor(app)
        XCTAssertTrue(gone(app, "rail-Continue Watching"), "the swiped row is still on Home")
    }

    /// An addon catalog as a row, given its own name on its page.
    func testAddAndRenameAddonRow() throws {
        let app = launch()
        expect(app, "hero-carousel", timeout: 30)
        openEditor(app)
        addRow(app, search: "Featured", entry: "Featured")
        tap(app, "home-row-Featured")
        let name = expect(app, "home-row-name")
        name.tap()
        name.typeText("Addon picks\n")
        snap(app, "home-row-renamed")
        // The page's title follows the new name; the list row (hidden under the pushed page) is checked after Back.
        back(app, from: "Addon picks")
        expect(app, "home-row-Addon picks")
        closeEditor(app)

        let rail = reveal(app, "rail-Addon picks")
        XCTAssertTrue(rail.descendants(matching: .any).matching(identifier: "tile-fx-addon-featured-0").firstMatch.waitForExistence(timeout: 10),
                      "the addon row has no titles")
        snap(app, "home-addon-row")
    }
}
