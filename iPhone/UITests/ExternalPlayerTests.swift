import XCTest

/// External players: the Player setting (account sheet → Settings → Player) and the play picker's
/// "Open in…" menu, on fixtures. A simulator has none of the players installed, which is the state
/// most of this checks; `--phone-external-players` makes the app count Infuse, VLC and VidHub as
/// installed so the lists can be seen (opening one then fails, as it would with the app deleted).
/// The English UI is assumed.
final class ExternalPlayerTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func snap(_ app: XCUIApplication, _ name: String) {
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

    private func missing(_ app: XCUIApplication, _ what: String, file: StaticString, line: UInt) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "hierarchy-missing-\(what)"
        tree.lifetime = .keepAlways
        add(tree)
        snap(app, "missing-\(what)")
        XCTFail("no \(what)", file: file, line: line)
    }

    @discardableResult
    private func expect(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let found = element(app, id)
        if !found.waitForExistence(timeout: timeout) { missing(app, id, file: file, line: line) }
        return found
    }

    private func tap(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        expect(app, id, timeout: timeout, file: file, line: line).tap()
    }

    /// A menu item, by its title (a context menu's items are UIKit's, labelled with the title).
    @discardableResult
    private func menuItem(_ app: XCUIApplication, _ title: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let item = app.buttons[title].firstMatch
        if !item.waitForExistence(timeout: timeout) { missing(app, "menu item \(title)", file: file, line: line) }
        return item
    }

    private func expectSelected(_ element: XCUIElement, _ selected: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let wait = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == %@", NSNumber(value: selected)), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 10), .completed,
                       "\(element.identifier) is \(selected ? "not " : "")selected", file: file, line: line)
    }

    /// The Player setting, from the profile button's sheet through Settings.
    private func openPlayerSetting(_ app: XCUIApplication) {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "no tab bar")
        tap(app, "account-button", timeout: 30)
        expect(app, "account-sheet")
        tap(app, "account-settings")
        expect(app, "settings-root")
        tap(app, "settings-row-player")
        expect(app, "player-settings")
    }

    private func launchPicker(_ extra: [String] = []) -> XCUIApplication {
        let app = launchHarbor(["--fixtures", "detail", "--fixture-streams", "--phone-picker"] + extra)
        expect(app, "phone-picker", timeout: 40)
        expect(app, "stream-0", timeout: 30)
        return app
    }

    /// Touch and hold on the first row, then "Open in…".
    private func openInMenu(_ app: XCUIApplication) {
        expect(app, "stream-0").press(forDuration: 1.2)
        menuItem(app, "Open in…").tap()
    }

    // MARK: Tests

    /// Harbor's own player is the default, and with nothing installed the screen says so.
    func testSettingDefaultsToBuiltIn() {
        let app = launchHarbor(["--fixtures", "shell"])
        openPlayerSetting(app)
        expectSelected(expect(app, "player-choice-builtin"), true)
        expect(app, "player-none-installed")
        expect(app, "player-footer")
        XCTAssertFalse(element(app, "player-choice-infuse").exists, "a player shows that is not installed")
        snap(app, "player-setting-default")
    }

    /// With players installed they are listed, Infuse first, and a choice sticks.
    func testSettingListsPlayersAndKeepsTheChoice() {
        let app = launchHarbor(["--fixtures", "shell", "--phone-external-players"])
        openPlayerSetting(app)
        let infuse = expect(app, "player-choice-infuse")
        expect(app, "player-choice-vlc")
        expect(app, "player-choice-vidhub")
        XCTAssertFalse(element(app, "player-none-installed").exists)
        XCTAssertLessThan(infuse.frame.minY, element(app, "player-choice-vlc").frame.minY, "Infuse is not first")
        expectSelected(element(app, "player-choice-builtin"), true)
        snap(app, "player-setting-players")

        infuse.tap()
        expectSelected(infuse, true)
        expectSelected(element(app, "player-choice-builtin"), false)
        // Back to Settings, whose row names Infuse, and in again: the choice is still there.
        let back = app.navigationBars.buttons["Settings"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no back button")
        back.tap()
        let row = expect(app, "settings-row-player")
        let named = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Infuse'"), object: row)
        XCTAssertEqual(XCTWaiter().wait(for: [named], timeout: 10), .completed, "the Player row does not say Infuse")
        row.tap()
        expectSelected(expect(app, "player-choice-infuse"), true)
        snap(app, "player-setting-infuse")
    }

    /// A row's menu has "Open in…"; with no player installed it says so, and a tap on the row still
    /// plays in Harbor.
    func testOpenInWithNoPlayersAndBuiltInPath() {
        let app = launchPicker()
        openInMenu(app)
        let none = menuItem(app, "No other video players installed")
        XCTAssertFalse(none.isEnabled, "the no-players line is a button that does something")
        XCTAssertFalse(app.buttons["Infuse"].exists, "a player shows that is not installed")
        XCTAssertFalse(app.buttons["Play in Harbor"].exists, "Play in Harbor shows with Harbor already the player")
        snap(app, "open-in-none")

        // A plain tap on the row plays as it always did. A fresh launch, not a tap beside the menu: an
        // open context menu takes taps outside it unreliably on the simulator.
        let fresh = launchPicker()
        tap(fresh, "stream-0")
        expect(fresh, "player-screen", timeout: 30)
        let title = element(fresh, "player-title")
        if title.waitForExistence(timeout: 5) {
            XCTAssertTrue(title.label.contains("Dune"), "the player names \(title.label)")
        }
        XCTAssertFalse(element(fresh, "picker-external-note").exists)
    }

    /// With players "installed", "Open in…" lists them; a player that does not open leaves the
    /// picker up with a note, and Harbor's player does not open.
    func testOpenInPlayerThatWillNotOpen() {
        let app = launchPicker(["--phone-external-players"])
        openInMenu(app)
        menuItem(app, "VLC")
        menuItem(app, "VidHub")
        snap(app, "open-in-players")
        menuItem(app, "Infuse").tap()
        let note = expect(app, "picker-external-note", timeout: 20)
        XCTAssertTrue(note.label.contains("Infuse"), "the note reads \(note.label)")
        XCTAssertFalse(element(app, "player-screen").exists, "a failed hand-off went to Harbor's player")
        expect(app, "phone-picker")
        snap(app, "open-in-failed")
    }
}
