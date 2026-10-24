import XCTest

/// The title page on the detail fixtures (`--fixtures detail`): every series carries two seasons of
/// six episodes (PhoneDetailFixtures), so the season switch, the AI search episode pick and the
/// harbor://detail link can be driven offline. Play opens the play picker on StreamsModel's fixture
/// streams (`--fixture-streams`, App/Shared/Streams/StreamsFixtures.swift). Every step attaches a
/// screenshot.
///
/// The English UI is assumed: menu items are looked up by their English labels when their
/// identifiers do not reach the accessibility tree.
final class DetailTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = launchHarbor(["--fixtures", "detail", "--fixture-streams"] + arguments)
        return app
    }

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

    private func gone(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20) -> Bool {
        let missing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, id))
        return XCTWaiter().wait(for: [missing], timeout: timeout) == .completed
    }

    /// Drags the page up by `fraction` of the screen, from below the backdrop so no tap lands.
    private func scrollPage(_ app: XCUIApplication, by fraction: CGFloat = 0.35) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7 - fraction))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Scrolls the page until the element sits in the upper part of the screen, clear of the tab bar.
    @discardableResult
    private func bringUp(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = expect(app, id, timeout: 30, file: file, line: line)
        var drags = 0
        while (!target.isHittable || target.frame.midY > app.frame.height * 0.55) && drags < 8 {
            scrollPage(app)
            drags += 1
        }
        XCTAssertTrue(target.isHittable, "\(id) never came into view", file: file, line: line)
        return target
    }

    /// Picks a season from the season menu: its item by identifier, else by its English label.
    private func pickSeason(_ app: XCUIApplication, _ season: Int) {
        bringUp(app, "detail-season-menu").tap()
        let byLabel = app.buttons["Season \(season)"].firstMatch
        guard let item = firstToExist([element(app, "season-\(season)"), byLabel], timeout: 10) else {
            XCTFail("no Season \(season) in the season menu")
            return
        }
        snap(app, "detail-season-menu-open")
        item.tap()
    }

    /// What Play opened, checked and closed again. With instant play on (the default) the picker's auto
    /// step plays the best fixture source: the player cover opens on the title (the fixture engine,
    /// PhonePlayerView), and Close (with Leave, when asked) comes back. With it off the picker stays on
    /// its list, which names the title, and its ✕ closes it. Either way the title page is back.
    private func checkPlay(_ app: XCUIApplication, _ shot: String, title: String, episode: Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        let player = element(app, "player-screen")
        // Instant play on a quick fixture: the picker can be gone and the player up by the first look.
        if firstToExist([element(app, "phone-picker"), player], timeout: 40) == nil {
            snap(app, "\(shot)-nothing")
            XCTFail("Play opened neither the picker nor the player", file: file, line: line)
        }
        let row = element(app, "stream-0")
        let auto = element(app, "auto-caption")
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if player.exists { break }
            // The list with no auto step over it, and no player or auto step within 2 s: instant play is off.
            if row.exists && !auto.exists {
                if firstToExist([player, auto], timeout: 2) == nil { break }
                continue
            }
            _ = firstToExist([player, row], timeout: 1)
        }
        if player.exists {
            snap(app, "\(shot)-player")
            // The HUD fades after 3 s; a tap on the picture brings it back.
            if !element(app, "player-hud").exists { element(app, "player-stage").tap() }
            let name = expect(app, "player-title", timeout: 5, file: file, line: line)
            XCTAssertTrue(name.label.contains(title), "the player plays \(name.label), not \(title)", file: file, line: line)
            if episode { expect(app, "player-subtitle", timeout: 5, file: file, line: line) }
            tap(app, "player-close", timeout: 5, file: file, line: line)
            if element(app, "player-leave").waitForExistence(timeout: 3) { tap(app, "player-leave", file: file, line: line) }
            XCTAssertTrue(gone(app, "player-screen"), "the player did not close", file: file, line: line)
        } else {
            expect(app, "stream-0", timeout: 20, file: file, line: line)
            XCTAssertEqual(expect(app, "picker-title", file: file, line: line).label, title, file: file, line: line)
            if episode { expect(app, "picker-episode", file: file, line: line) }
            snap(app, "\(shot)-sheet")
            tap(app, "picker-close", file: file, line: line)
        }
        XCTAssertTrue(gone(app, "phone-picker"), "the play picker did not close", file: file, line: line)
        expect(app, "detail-page", timeout: 20, file: file, line: line)
    }

    // MARK: Tests

    /// A Home tile opens the title page: the name and the action bar show, a season switch swaps the
    /// episodes, and Play opens the play picker on the premiere.
    func testOpenFromHomeAndSwitchSeason() throws {
        let app = launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "no tab bar")
        expect(app, "feed-home", timeout: 30)
        // "Trending Series" leads with s-0; the feed is scrolled until its tile can be tapped. A drag
        // that opens a title page anyway is backed out of.
        let tile = element(app, "tile-s-0")
        var drags = 0
        while !(tile.exists && tile.isHittable) && drags < 12 {
            scrollPage(app, by: 0.3)
            if element(app, "detail-page").exists {
                app.navigationBars.buttons.firstMatch.tap()
                _ = gone(app, "detail-page", timeout: 10)
            }
            drags += 1
        }
        XCTAssertTrue(tile.isHittable, "the Trending Series row never came into view")
        tile.tap()

        expect(app, "detail-page", timeout: 30)
        XCTAssertEqual(expect(app, "detail-name").label, "Dune: Part Two")
        expect(app, "detail-actions")
        expect(app, "detail-play")
        expect(app, "detail-watchlist")
        expect(app, "detail-share")
        snap(app, "detail-top")

        XCTAssertEqual(bringUp(app, "detail-season-menu").label, "Season 1")
        expect(app, "episode-1-1", timeout: 30)
        snap(app, "detail-season-1")

        pickSeason(app, 2)
        expect(app, "episode-2-1")
        XCTAssertTrue(gone(app, "episode-1-1"), "season 1's episodes are still listed")
        XCTAssertEqual(element(app, "detail-season-menu").label, "Season 2")
        snap(app, "detail-season-2")

        // Play: the player (instant play) or the play picker names the title and the episode. The page is
        // dragged back down until Play sits below the inline navigation bar: XCUI calls a button under
        // the bar hittable, but the tap lands on the bar.
        let play = element(app, "detail-play")
        let bar = app.navigationBars.firstMatch
        func underBar() -> Bool { bar.exists && play.frame.minY < bar.frame.maxY + 8 }
        var back = 0
        while (!play.isHittable || underBar()) && back < 8 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
            back += 1
        }
        play.tap()
        checkPlay(app, "detail-play", title: "Dune: Part Two", episode: true)

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(gone(app, "detail-page"), "Back did not leave the title page")
        expect(app, "feed-home")
    }

    /// A harbor://detail link opens the title page over the shell, named from its fixture row, and
    /// its Play picker is presented by the page's own sheet.
    func testDeepLinkOpensDetail() throws {
        let app = launch(["--phone-open", "harbor://detail/series/s-3"])
        expect(app, "detail-sheet", timeout: 40)
        expect(app, "detail-page")
        XCTAssertEqual(expect(app, "detail-name").label, "Severance")
        expect(app, "detail-actions")
        snap(app, "detail-deep-link")

        tap(app, "detail-play")
        checkPlay(app, "detail-deep-link-play", title: "Severance", episode: false)

        tap(app, "detail-close")
        XCTAssertTrue(gone(app, "detail-sheet"), "the title sheet did not close")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "no tab bar under the sheet")
    }

    /// An AI search episode pick (Severance S2E4) opens the page on season 2 with that episode marked.
    func testAIPickLandsOnTheEpisode() throws {
        let app = launch(["--query", "severance"])
        tapTab(app, "Search")
        expect(app, "search-screen")
        tap(app, "chip-AI search", timeout: 30)
        tap(app, "ai-result-fx-ai-1", timeout: 40)

        expect(app, "detail-page", timeout: 30)
        XCTAssertEqual(expect(app, "detail-name").label, "Severance")
        let episode = expect(app, "episode-2-4", timeout: 30)
        XCTAssertTrue(episode.isSelected, "the picked episode is not marked")
        XCTAssertFalse(element(app, "episode-1-1").exists, "season 1 is listed instead of season 2")
        XCTAssertEqual(element(app, "detail-season-menu").label, "Season 2")
        snap(app, "detail-ai-episode")
    }
}
