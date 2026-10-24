import XCTest

/// Remote-navigation checks for the Apple TV's customizable Home: Edit Home opens from
/// the end of Home's rail, adds a row from the source picker (Movies' Top 10), moves it, removes a
/// row, picks the hero, empties Home and resets it to the default. Offline fixture scenario only
/// (`--fixtures shell`), where the layout lives in memory: every launch starts on the default
/// layout, the Home the other UI tests walk. Same helpers and waits as NavigationTests3.
final class NavigationTests9: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var remote: XCUIRemote { XCUIRemote.shared }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixtures", scenario]
        app.launch()
        return app
    }

    // MARK: helpers (as NavigationTests3)

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

    private func focused(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    /// The identifier of the focused button, if one has focus.
    private func focusedId(_ app: XCUIApplication) -> String? {
        let f = focused(app)
        return f.exists ? f.identifier : nil
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

    /// Walks the ring to the button `id` by where it sits on screen against the focused one: Down
    /// or Up while it is below or above, then Right or Left. For a grid or a list of rows, where a
    /// fixed walk would depend on the column the ring enters on.
    private func walk(to id: String, _ app: XCUIApplication, max presses: Int = 24) -> Bool {
        let target = app.buttons[id]
        guard target.waitForExistence(timeout: 15) else { return false }
        for _ in 0..<presses {
            if focusedId(app) == id { return true }
            let from = focused(app)
            let direction: XCUIRemote.Button
            if from.exists {
                let a = from.frame, b = target.frame
                if b.midY > a.maxY { direction = .down }
                else if b.midY < a.minY { direction = .up }
                else if b.midX > a.midX { direction = .right }
                else { direction = .left }
            } else {
                direction = .down
            }
            remote.press(direction)
            if waitForFocus(app, timeout: 0.8, where: { $0 == id }) != nil { return true }
        }
        return focusedId(app) == id
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private static func isHomeCard(_ id: String) -> Bool { id.hasPrefix("cw-") || id.hasPrefix("tile-") }

    /// Fixture Home is up and its first-focus seed (Continue Watching, else the first row) has landed.
    private func waitForHome(_ app: XCUIApplication) {
        require(app.buttons["tile-trending-0"].waitForExistence(timeout: 30), "fixture Home rows never appeared", app)
        let seeded = waitForFocus(app, timeout: 20, where: Self.isHomeCard)
        require(seeded != nil, "Home never seeded focus on a card (focus: \(focusNote(app)))", app)
    }

    /// Down from Home's cards, past the last row, to Edit Home; Select opens it with the ring on Add a row.
    private func openEditor(_ app: XCUIApplication) {
        let footer = press(.down, app, max: 16, until: { $0 == "home-edit" })
        require(footer != nil, "Down past Home's last row never reached Edit Home (focus: \(focusNote(app)))", app)
        // The rail scrolls the focused footer clear of the hint bar and the fade over it (BP.hintHeight
        // 52 px canvas + 24 px = 112 pt above the screen's bottom edge).
        let button = app.buttons["home-edit"]
        let clearLine: CGFloat = app.windows.firstMatch.frame.height - 112
        let until = Date().addingTimeInterval(4)
        while button.frame.maxY > clearLine && Date() < until { usleep(200_000) }
        require(button.frame.maxY <= clearLine, "Focused Edit Home footer sits under the hint bar (bottom \(button.frame.maxY), clear line \(clearLine))", app)
        remote.press(.select)
        require(app.buttons["home-edit-add"].waitForExistence(timeout: 10), "Edit Home did not open", app)
        let lead = waitForFocus(app, timeout: 5, where: { $0 == "home-edit-add" })
        require(lead != nil, "Edit Home did not open with the ring on Add a row (focus: \(focusNote(app)))", app)
    }

    /// Menu closes Edit Home; Home is back.
    private func closeEditor(_ app: XCUIApplication) {
        remote.press(.menu)
        require(waitForGone(app.buttons["home-edit-add"], timeout: 10), "Menu did not close Edit Home", app)
    }

    private func pick(_ id: String, _ app: XCUIApplication) {
        require(app.buttons[id].waitForExistence(timeout: 20), "the source picker never listed \(id)", app)
        require(walk(to: id, app), "could not walk the picker to \(id) (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(waitForGone(app.buttons[id], timeout: 10), "picking \(id) did not close the picker", app)
    }

    // MARK: tests

    /// The default layout is today's Home (Continue Watching, then every Home row). Edit Home adds
    /// Movies' Top 10 from the picker with the ring on the new row's Move up, moves it above Home's
    /// rows (and no higher than Continue Watching), removes Home's rows, and Home shows the result;
    /// Reset to default (after its confirmation) brings today's Home back.
    func testEditHomeAddMoveRemoveAndReset() {
        let app = launch("shell")
        waitForHome(app)
        openEditor(app)
        require(app.buttons["home-edit-remove-cw:home"].exists, "the default layout lacks Continue Watching", app)
        require(app.buttons["home-edit-remove-room:home"].exists, "the default layout lacks Home's rows", app)
        require(!app.buttons["home-edit-up-cw:home"].exists, "Continue Watching offered Move up (it is pinned first)", app)

        // Add Movies' Top 10.
        remote.press(.select)
        pick("home-source-row:movies:bp-top10", app)
        let added = waitForFocus(app, timeout: 6, where: { $0 == "home-edit-up-row:movies:bp-top10" })
        require(added != nil, "the new row's Move up did not take the ring (focus: \(focusNote(app)))", app)

        // Up once: above Home's rows. Again: it stays under Continue Watching, the ring on the button.
        remote.press(.select)
        Thread.sleep(forTimeInterval: 0.8)
        remote.press(.select)
        Thread.sleep(forTimeInterval: 0.8)
        require(focusedId(app) == "home-edit-up-row:movies:bp-top10", "Move up lost the ring (focus: \(focusNote(app)))", app)
        let top10 = app.buttons["home-edit-remove-row:movies:bp-top10"].frame
        let homeRows = app.buttons["home-edit-remove-room:home"].frame
        let cw = app.buttons["home-edit-remove-cw:home"].frame
        require(top10.minY < homeRows.minY, "Move up did not put Top 10 above Home's rows", app)
        require(cw.minY < top10.minY, "Top 10 moved above Continue Watching", app)

        // Remove Home's rows: the ring goes to the row now last (Top 10).
        require(walk(to: "home-edit-remove-room:home", app), "could not reach Home rows' Remove (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(waitForGone(app.buttons["home-edit-remove-room:home"], timeout: 5), "Remove did not take Home's rows away", app)
        require(waitForFocus(app, timeout: 5, where: { $0.hasPrefix("home-edit-remove-") }) != nil,
                "the ring did not stay on a row's Remove (focus: \(focusNote(app)))", app)

        closeEditor(app)
        require(app.buttons["tile-movies.bp-top10-0"].waitForExistence(timeout: 20), "Home did not show the Movies Top 10 row", app)
        require(waitForGone(app.buttons["tile-trending-0"], timeout: 10), "Home still shows its own rows after they were removed", app)
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cw-'"))
        require(cards.firstMatch.waitForExistence(timeout: 10), "Continue Watching left Home", app)

        // Reset to default.
        openEditor(app)
        require(walk(to: "home-edit-reset", app), "could not reach Reset to default (focus: \(focusNote(app)))", app)
        remote.press(.select)
        let confirm = waitForFocus(app, timeout: 5, where: { $0 == "home-edit-reset-confirm" })
        require(confirm != nil, "Reset did not ask first with the ring on its Reset (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(app.buttons["home-edit-remove-room:home"].waitForExistence(timeout: 5), "Reset did not bring Home's rows back", app)
        require(!app.buttons["home-edit-remove-row:movies:bp-top10"].exists, "Reset kept the added row", app)
        closeEditor(app)
        require(app.buttons["tile-trending-0"].waitForExistence(timeout: 20), "Home's own rows did not come back after Reset", app)
        require(waitForGone(app.buttons["tile-movies.bp-top10-0"], timeout: 10), "the Movies row stayed after Reset", app)
    }

    /// The hero picker: Automatic by default, Off, then a source (Movies' Top 10); Edit Home names
    /// each and keeps the ring on Hero. Home is still there afterwards.
    func testEditHomeHeroPicker() {
        let app = launch("shell")
        waitForHome(app)
        openEditor(app)
        let hero = app.buttons["home-edit-hero"]
        require(hero.label.contains("Automatic"), "the default hero is not Automatic (\(hero.label))", app)
        require(walk(to: "home-edit-hero", app), "could not reach Hero (focus: \(focusNote(app)))", app)

        remote.press(.select)
        pick("home-source-hero-off", app)
        require(waitForFocus(app, timeout: 5, where: { $0 == "home-edit-hero" }) != nil, "the ring did not come back to Hero (focus: \(focusNote(app)))", app)
        require(app.buttons["home-edit-hero"].label.contains("Off"), "Hero did not read Off (\(app.buttons["home-edit-hero"].label))", app)

        remote.press(.select)
        pick("home-source-row:movies:bp-top10", app)
        require(waitForFocus(app, timeout: 5, where: { $0 == "home-edit-hero" }) != nil, "the ring did not come back to Hero (focus: \(focusNote(app)))", app)
        let named = app.buttons["home-edit-hero"].label
        require(!named.contains("Off") && !named.contains("Automatic"), "Hero did not name the source picked (\(named))", app)

        closeEditor(app)
        // A changed layout opens Home afresh: its first row on screen, the ring back on a card.
        require(app.buttons["tile-trending-0"].waitForExistence(timeout: 20), "Home's rows left after a hero change", app)
        require(waitForFocus(app, timeout: 20, where: Self.isHomeCard) != nil,
                "Home did not put the ring on a card after the edit (focus: \(focusNote(app)))", app)
    }

    /// Removing every row leaves Home with its Edit Home message (never a dead end); the message
    /// opens the editor, and Reset to default brings today's Home back.
    func testEmptyHomeOffersEditHome() {
        let app = launch("shell")
        waitForHome(app)
        openEditor(app)
        for id in ["home-edit-remove-room:home", "home-edit-remove-cw:home"] {
            require(walk(to: id, app), "could not reach \(id) (focus: \(focusNote(app)))", app)
            remote.press(.select)
            require(waitForGone(app.buttons[id], timeout: 5), "\(id) did not remove its row", app)
        }
        require(app.staticTexts["home-edit-empty"].waitForExistence(timeout: 5), "Edit Home did not say Home has no rows", app)
        closeEditor(app)

        require(app.buttons["home-empty-edit"].waitForExistence(timeout: 20), "an empty Home did not offer Edit Home", app)
        require(press(.down, app, max: 4, until: { $0 == "home-empty-edit" }) != nil, "Down never reached the empty Home's Edit Home (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(app.buttons["home-edit-reset"].waitForExistence(timeout: 10), "the empty Home's Edit Home did not open the editor", app)
        require(walk(to: "home-edit-reset", app), "could not reach Reset to default (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(waitForFocus(app, timeout: 5, where: { $0 == "home-edit-reset-confirm" }) != nil, "Reset did not ask first (focus: \(focusNote(app)))", app)
        remote.press(.select)
        closeEditor(app)
        require(app.buttons["tile-trending-0"].waitForExistence(timeout: 20), "Reset did not bring Home's rows back", app)
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cw-'"))
        require(cards.firstMatch.waitForExistence(timeout: 10), "Reset did not bring Continue Watching back", app)
    }
}
