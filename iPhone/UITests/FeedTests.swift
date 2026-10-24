import XCTest

/// The Home feed on the fixture rooms (`--fixtures shell|bands`): hero, Continue Watching, rows and
/// bands, long-press menus, row leads and the Home layout choice. Movies, Shows and Anime rows on Home
/// are HomeEditTests'. Every step attaches a screenshot. Nothing here touches the network.
///
/// The English UI is assumed: menu items and buttons are looked up by their English labels.
final class FeedTests: XCTestCase {
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

    /// Scrolls the feed up by `fraction` of the screen with a drag between two points, never
    /// `app.swipeUp()`: a swipe starts mid-screen, which near the top of Home is the 500-pt hero, and a
    /// drag that starts and ends on its art opens the title page instead of scrolling. While the hero
    /// holds the start point, the drag starts under it, or ends above it when it reaches that low. A
    /// title page that opens anyway is closed, so it never covers what the test looks for.
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
        closeStrayTitle(app)
    }

    /// A drag that opened the title page anyway: kept as a screenshot, then closed.
    private func closeStrayTitle(_ app: XCUIApplication) {
        guard element(app, "detail-page").exists else { return }
        snap(app, "scroll-opened-title")
        closeDetail(app)
        _ = gone(app, "detail-page", timeout: 10)
    }

    /// Leaves the title page: the link sheet's close button, else the bar's Back.
    private func closeDetail(_ app: XCUIApplication) {
        if element(app, "detail-close").exists {
            element(app, "detail-close").tap()
        } else {
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    /// What the hero's Play started over the title page (it plays at once, as Continue Watching's
    /// resume does): the play picker, closed with its ✕ (or the Back of the "No streaming sources
    /// yet" dialog the shell fixtures, with no addon, raise over it), or the player, closed with Close
    /// (and Leave).
    private func closePlayback(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let picker = element(app, "phone-picker"), player = element(app, "player-screen")
        let up = NSPredicate { _, _ in picker.exists || player.exists }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: up, object: nil)], timeout: 15) == .completed else { return }
        if player.exists {
            if !element(app, "player-hud").exists { element(app, "player-stage").tap() }
            expect(app, "player-close", timeout: 5, file: file, line: line).tap()
            if element(app, "player-leave").waitForExistence(timeout: 3) { element(app, "player-leave").tap() }
            XCTAssertTrue(gone(app, "player-screen"), "the player did not close", file: file, line: line)
        } else {
            let back = element(app, "dialog-back"), close = element(app, "picker-close")
            let deadline = Date().addingTimeInterval(30)
            while picker.exists && Date() < deadline {
                if back.exists && back.isHittable {
                    back.tap()
                } else if close.exists && close.isHittable {
                    close.tap()
                }
                _ = gone(app, "phone-picker", timeout: 2)
            }
        }
        XCTAssertTrue(gone(app, "phone-picker"), "the play picker did not close", file: file, line: line)
    }

    /// Scrolls the feed until the element can be tapped.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = expect(app, id, timeout: 30, file: file, line: line)
        var drags = 0
        while !target.isHittable && drags < 16 {
            scrollFeed(app)
            drags += 1
        }
        XCTAssertFalse(element(app, "detail-page").exists, "a title page covers the feed", file: file, line: line)
        return target
    }

    private func gone(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20) -> Bool {
        let missing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, id))
        return XCTWaiter().wait(for: [missing], timeout: timeout) == .completed
    }

    private func menuItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Long-presses the element. With `centred` it is first scrolled into the upper part of the screen,
    /// away from the tab bar and the bottom edge, where a press can be taken by the system instead of the
    /// card's menu.
    private func openMenu(_ app: XCUIApplication, on id: String, hold: TimeInterval = 1.2, centred: Bool = false) {
        let target = reveal(app, id)
        var nudges = 0
        while centred && target.frame.midY > app.frame.height * 0.6 && nudges < 4 {
            scrollFeed(app, by: 0.3)
            nudges += 1
        }
        target.press(forDuration: hold)
    }

    // MARK: Tests

    /// Home: the hero with its logo-less title, Play and Watchlist; Continue Watching; the rows.
    func testHomeHeroAndRails() throws {
        let app = launch(["--fixtures", "shell"])
        expect(app, "hero-carousel", timeout: 30)
        expect(app, "hero-play-t-0")
        expect(app, "hero-watchlist-t-0")
        snap(app, "feed-home-hero")

        expect(app, "rail-Continue Watching")
        expect(app, "resume-cw1")
        reveal(app, "rail-Trending This Week")
        snap(app, "feed-home-rails")
        expect(app, "seeall-Trending This Week")
        expect(app, "tile-t-0")
    }

    /// The hero's Watchlist button flips to Saved and back.
    func testHeroWatchlistToggles() throws {
        let app = launch(["--fixtures", "shell"])
        let button = expect(app, "hero-watchlist-t-0", timeout: 30)
        XCTAssertEqual(button.label, "Watchlist")
        button.tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Saved"), object: button)
        XCTAssertEqual(XCTWaiter().wait(for: [saved], timeout: 10), .completed, "the button did not turn to Saved")
        snap(app, "feed-hero-saved")
        button.tap()
        let unsaved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Watchlist"), object: button)
        XCTAssertEqual(XCTWaiter().wait(for: [unsaved], timeout: 10), .completed, "the button did not turn back")
    }

    /// Play reaches the title page and starts the film there (the picker, or the player with instant play).
    func testHeroOpensTitle() throws {
        let app = launch(["--fixtures", "shell"])
        element(app, "hero-play-t-0").tap()
        expect(app, "detail-page", timeout: 30)
        XCTAssertEqual(expect(app, "detail-name").label, "Dune: Part Two")
        snap(app, "feed-hero-title")
        closePlayback(app)
        closeDetail(app)
        XCTAssertTrue(gone(app, "detail-page"), "the title page did not close")
        expect(app, "feed-home")
    }

    /// A row's See all pushes the catalog page and Back returns to the feed.
    func testSeeAllPushesCatalogPage() throws {
        let app = launch(["--fixtures", "shell"])
        reveal(app, "seeall-Trending This Week").tap()
        expect(app, "route-catalog")
        snap(app, "feed-see-all")
        app.navigationBars.buttons.firstMatch.tap()
        expect(app, "feed-home")
    }

    /// Long press: Add to Watchlist, then the menu says Remove; Mark as Watched is offered for a film.
    func testContextMenuWatchlistAndWatched() throws {
        let app = launch(["--fixtures", "shell"])
        openMenu(app, on: "tile-t-1")
        XCTAssertTrue(menuItem(app, "Details").waitForExistence(timeout: 10), "no Details item")
        XCTAssertTrue(menuItem(app, "Mark as Watched").exists, "no Mark as Watched item for a film")
        XCTAssertTrue(menuItem(app, "Play").exists, "no Play item on a Home tile")
        XCTAssertTrue(menuItem(app, "Share").exists, "no Share item")
        snap(app, "feed-context-menu")
        menuItem(app, "Add to Watchlist").tap()

        openMenu(app, on: "tile-t-1")
        XCTAssertTrue(menuItem(app, "Remove from Watchlist").waitForExistence(timeout: 10), "the menu did not turn to Remove")
        snap(app, "feed-context-menu-saved")
        menuItem(app, "Mark as Watched").tap()

        openMenu(app, on: "tile-t-1")
        XCTAssertTrue(menuItem(app, "Mark as Unwatched").waitForExistence(timeout: 10), "the menu did not turn to Unwatched")
        menuItem(app, "Details").tap()
        expect(app, "detail-page", timeout: 30)
        XCTAssertEqual(expect(app, "detail-name").label, "Oppenheimer")
    }

    /// Continue Watching cards carry a menu with Remove, and Remove takes the card away.
    func testContinueWatchingRemove() throws {
        let app = launch(["--fixtures", "shell"])
        expect(app, "resume-cw1", timeout: 30)
        let remove = menuItem(app, "Remove from Continue Watching")
        var opened = false
        for hold in [1.2, 2.0] where !opened {
            openMenu(app, on: "resume-cw1", hold: hold, centred: true)
            opened = remove.waitForExistence(timeout: 8)
            if !opened {
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "hierarchy-no-remove-item-\(hold)"
                tree.lifetime = .keepAlways
                add(tree)
                snap(app, "missing-remove-item-\(hold)")
                // Back to the feed first, if the press opened the title page or left a menu up.
                if element(app, "detail-page").exists {
                    closeDetail(app)
                } else {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).tap()
                }
            }
        }
        XCTAssertTrue(opened, "no Remove item")
        snap(app, "feed-cw-menu")
        menuItem(app, "Remove from Continue Watching").tap()
        XCTAssertTrue(gone(app, "resume-cw1"), "the card stayed after Remove")
        expect(app, "resume-cw2")
    }

    /// The band rows: services, addons and collections open their pages; the collections lead goes
    /// to the Collections room; services and addons have no lead on the phone.
    func testBandsRoute() throws {
        let app = launch(["--fixtures", "bands"])
        reveal(app, "rail-Your streaming")
        snap(app, "feed-bands")
        XCTAssertFalse(element(app, "seeall-Your streaming").exists, "services carry a lead")
        XCTAssertFalse(element(app, "seeall-Your addons").exists, "addons carry a lead")

        reveal(app, "tile-service:fixture-0").tap()
        expect(app, "route-service")
        snap(app, "feed-service-page")
        app.navigationBars.buttons.firstMatch.tap()

        reveal(app, "tile-addon:https://addon.invalid/fixture-0").tap()
        expect(app, "route-addon")
        app.navigationBars.buttons.firstMatch.tap()

        reveal(app, "tile-collection:tmdb:900").tap()
        expect(app, "route-collection")
        app.navigationBars.buttons.firstMatch.tap()

        reveal(app, "seeall-Collections").tap()
        expect(app, "chips-Library", timeout: 20)
        snap(app, "feed-collections-room")
    }

    /// Classic mode drops the hero; Harbor brings it back.
    func testClassicHomeMode() throws {
        let app = launch(["--fixtures", "shell"])
        expect(app, "hero-carousel", timeout: 30)
        reveal(app, "home-layout")
        snap(app, "feed-layout-harbor")
        app.buttons["Classic"].tap()
        XCTAssertTrue(gone(app, "hero-carousel"), "Classic kept the hero")
        snap(app, "feed-layout-classic")
        expect(app, "rail-Continue Watching")
        app.buttons["Harbor"].tap()
        expect(app, "hero-carousel")
    }

    /// Pull to refresh reloads and keeps the page.
    func testPullToRefresh() throws {
        let app = launch(["--fixtures", "shell"])
        let feed = expect(app, "feed-home", timeout: 30)
        let from = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let to = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        from.press(forDuration: 0.1, thenDragTo: to)
        expect(app, "rail-Continue Watching", timeout: 30)
        snap(app, "feed-refreshed")
    }
}
