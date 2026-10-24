import XCTest

/// Remote-navigation checks, fifth batch: screens merged on 2026-09-27 that the first four batches
/// do not drive. Offline fixture scenarios only (`--fixtures shell|detail`): Settings' Spoilers
/// panel, and Detail's episode strip on the `detail` fixture, which now also carries a Special
/// and an episode 0 for DetailModel.buildEpisodes to drop. Focus is only asserted where the app
/// places it itself; everything else is polled, with the same helpers and waits as NavigationTests4.
final class NavigationTests5: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var remote: XCUIRemote { XCUIRemote.shared }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixtures", scenario]
        app.launch()
        return app
    }

    // MARK: helpers (as NavigationTests4)

    /// A failed check leaves a screenshot and the element tree behind, then stops the test.
    private func require(_ ok: Bool, _ message: @autoclosure () -> String, _ app: XCUIApplication) {
        guard !ok else { return }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "failure-screen"
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "failure-hierarchy"
        tree.lifetime = .keepAlways
        add(tree)
        XCTFail(message())
    }

    /// The identifier of the focused button, if one has focus.
    private func focusedId(_ app: XCUIApplication) -> String? {
        let f = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return f.exists ? f.identifier : nil
    }

    /// A chip re-renders when its value cycles, so a captured element can vanish mid-read ("Failed
    /// to get matching snapshot", run 36313558727): read the label through a fresh, exists-guarded query.
    private func chipLabel(_ id: String, _ app: XCUIApplication) -> String {
        let e = app.buttons[id]
        return e.exists ? e.label : ""
    }

    private func focusNote(_ app: XCUIApplication) -> String { focusedId(app) ?? "none" }

    /// Polls until the focused button's identifier matches; returns it, or nil on timeout.
    @discardableResult
    private func waitForFocus(_ app: XCUIApplication, timeout: TimeInterval, where match: (String) -> Bool) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let id = focusedId(app), match(id) { return id }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    /// Presses `button` until the focus matches (checked before the first press too).
    @discardableResult
    private func press(_ button: XCUIRemote.Button, _ app: XCUIApplication, max presses: Int, until match: (String) -> Bool) -> String? {
        if let id = waitForFocus(app, timeout: 1, where: match) { return id }
        for _ in 0..<presses {
            remote.press(button)
            if let id = waitForFocus(app, timeout: 1, where: match) { return id }
        }
        return nil
    }

    /// Walks a row (or a column: `first` .up / .down) to the element with `id`: one way first, then
    /// back the other, so neither the starting cell nor an overshoot matters.
    private func seek(_ id: String, _ app: XCUIApplication, max presses: Int = 25, first: XCUIRemote.Button = .right) -> Bool {
        let then: XCUIRemote.Button
        switch first {
        case .left: then = .right
        case .up: then = .down
        case .down: then = .up
        default: then = .left
        }
        if press(first, app, max: presses, until: { $0 == id }) != nil { return true }
        return press(then, app, max: presses, until: { $0 == id }) != nil
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    private static func isHomeCard(_ id: String) -> Bool { id.hasPrefix("cw-") || id.hasPrefix("tile-") }
    private static func inBar(_ id: String) -> Bool { id.hasPrefix("tab-") || id == "profile-chip" || id == "account-menu" }

    /// Fixture Home is up and its first-focus seed (Continue Watching, else the first row) has landed.
    private func waitForHome(_ app: XCUIApplication) {
        require(app.buttons["tile-trending-0"].waitForExistence(timeout: 30), "fixture Home rows never appeared", app)
        let seeded = waitForFocus(app, timeout: 20, where: Self.isHomeCard)
        require(seeded != nil, "Home never seeded focus on a card (focus: \(focusNote(app)))", app)
    }

    /// Up from Home's cards until the ring is in the top bar.
    private func goToBar(_ app: XCUIApplication) {
        let at = press(.up, app, max: 5, until: Self.inBar)
        require(at != nil, "Up never reached the top bar (focus: \(focusNote(app)))", app)
    }

    // MARK: tests

    /// Settings → Spoilers (App/Sources/Settings/SpoilersPanel.swift): the master toggle
    /// (`spoilers-hide`) shows and hides the three nested toggles at once, and Menu — with no
    /// BPSettingsView column open, the only place Settings itself catches it (testSettingsBackSteps)
    /// — is not caught here either: it reaches the shell, which goes Home, same as any other
    /// Settings row.
    func testSpoilersMasterToggleAndMenu() {
        let app = launch("shell")
        waitForHome(app)
        goToBar(app)
        require(seek("tab-settings", app), "could not walk the top bar to Settings (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(app.staticTexts["Settings"].waitForExistence(timeout: 15), "Settings did not open", app)
        let master = app.buttons["spoilers-hide"]
        require(master.waitForExistence(timeout: 20), "the Spoilers panel's master toggle never appeared", app)
        require(!app.buttons["spoilers-thumb"].exists, "the nested toggles show before Blur spoilers is on", app)
        sleep(1)
        require(press(.down, app, max: 60, until: { $0 == "spoilers-hide" }) != nil, "Down never reached the Spoilers panel (focus: \(focusNote(app)))", app)
        require(master.label == "Blur spoilers: Off", "Blur spoilers started as \"\(master.label)\", not \"Blur spoilers: Off\"", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { master.label == "Blur spoilers: On" }, "Select on Blur spoilers did not turn it on (now \"\(master.label)\")", app)
        require(app.buttons["spoilers-thumb"].waitForExistence(timeout: 5), "turning Blur spoilers on did not show the nested toggles", app)
        require(app.buttons["spoilers-title"].exists && app.buttons["spoilers-desc"].exists && app.buttons["spoilers-skip-next"].exists,
                "turning Blur spoilers on did not show every nested toggle", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { master.label == "Blur spoilers: Off" }, "Select on Blur spoilers did not turn it off again (now \"\(master.label)\")", app)
        require(!app.buttons["spoilers-thumb"].exists, "turning Blur spoilers off again left the nested toggles up", app)
        sleep(1)
        remote.press(.menu)
        require(waitUntil(timeout: 15) { app.buttons["tab-home"].isSelected }, "Menu from the Spoilers panel did not go Home", app)
        require(app.buttons["tile-trending-0"].waitForExistence(timeout: 30), "Home rows did not come back", app)
    }

    /// `--fixtures detail`: the fixture series' raw video list now also carries a Special (season 0)
    /// and an episode 0, so DetailModel.buildEpisodes' `guard s > 0, e > 0` (open-items sweep 4) has
    /// something real to drop. The strip still opens on episode 1 with no Special or episode-0 cell
    /// anywhere in it, and no "Specials" button exists on the page (the season stays a lone
    /// Season 1, same as NavigationTests3's "a one-season series shows a lone Season 1 chip").
    func testDetailEpisodeStripDropsSpecialsAndEpisodeZero() {
        let app = launch("detail")
        waitForHome(app)
        let row = press(.down, app, max: 8, until: { $0.hasPrefix("tile-series-") })
        require(row != nil, "Down never reached the Trending Series row (focus: \(focusNote(app)))", app)
        let opener = "tile-series-2"
        require(seek(opener, app, max: 14), "could not walk the row to \(opener) (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(app.buttons["detail-play"].waitForExistence(timeout: 30), "Detail did not open from \(opener)", app)
        require(app.buttons["episode-1-1"].waitForExistence(timeout: 20), "the fixture series' episodes never appeared on Detail", app)
        require(!app.buttons["episode-0-1"].exists, "the Special (season 0) still has a cell in the strip", app)
        require(!app.buttons["episode-1-0"].exists, "episode 0 still has a cell in the strip", app)
        let specials = app.buttons.matching(NSPredicate(format: "label == %@", "Specials"))
        require(specials.count == 0, "a Specials chip shows even though the season is dropped from the strip", app)
        // The strip is a LazyHStack: only the first cells exist until the ring walks the row, so
        // the six real episodes are proven by walking to the last one.
        for n in 1...3 {
            require(app.buttons["episode-1-\(n)"].exists, "episode \(n) is missing from the strip", app)
        }
        let onPlay: String? = waitForFocus(app, timeout: 5, where: { $0 == "detail-play" }) ?? press(.left, app, max: 12, until: { $0 == "detail-play" })
        require(onPlay != nil, "could not put the ring on Play (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.down)
        require(waitForFocus(app, timeout: 5, where: { $0.hasPrefix("episode-1-") }) != nil, "one Down from Play did not reach the episodes (focus: \(focusNote(app)))", app)
        sleep(1)
        require(press(.right, app, max: 8, until: { $0 == "episode-1-6" }) != nil, "Right along the strip never reached episode 6 (focus: \(focusNote(app)))", app)
        require(!app.buttons["episode-1-0"].exists && !app.buttons["episode-0-1"].exists, "a dropped cell appeared once the strip scrolled", app)
    }
}
