import XCTest

/// Profiles on the shell fixtures (`--fixtures shell`: Skipper the primary, Guest with PIN 1234, Kiddo a kid
/// profile synced from the TV), the phone's take on the TV's NavigationTests6/8: add, edit and delete a
/// profile from Settings → Profiles, a saved change is still there after a relaunch (`--keep-profiles`
/// stops the fixtures resetting the list), a PIN gates switching to its profile, and a Who's watching
/// long-press opens the editor. A kid profile is listed and editable-in-place only as the TV set it up.
/// The English UI is assumed.
final class ProfilesTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func snap(_ name: String) {
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
            snap("missing-\(id)")
            XCTFail("no element \(id)", file: file, line: line)
        }
        return found
    }

    private func gone(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 15) -> Bool {
        let missing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, id))
        return XCTWaiter().wait(for: [missing], timeout: timeout) == .completed
    }

    /// Drags the page up until the element can be tapped (a Form builds its rows lazily).
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(app, id)
        _ = target.waitForExistence(timeout: 3)
        var drags = 0
        while !(target.exists && target.isHittable) && drags < 12 {
            let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            lower.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
            drags += 1
        }
        _ = expect(app, id, timeout: timeout, file: file, line: line)
        XCTAssertTrue(target.isHittable, "\(id) cannot be reached", file: file, line: line)
        return target
    }

    private func tap(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        reveal(app, id, timeout: timeout, file: file, line: line).tap()
    }

    private func wait(_ app: XCUIApplication, _ id: String, _ predicate: String, _ what: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let found = expect(app, id, file: file, line: line)
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: found)
        if XCTWaiter().wait(for: [match], timeout: timeout) != .completed {
            snap("wait-\(id)")
            XCTFail("\(id): \(what) (label \"\(found.label)\", value \"\(String(describing: found.value))\")", file: file, line: line)
        }
    }

    private func enterPin(_ app: XCUIApplication, _ digits: String, file: StaticString = #filePath, line: UInt = #line) {
        expect(app, "pin-pad", file: file, line: line)
        for digit in digits {
            tap(app, "pin-key-\(digit)", file: file, line: line)
        }
    }

    /// A launch on the shell fixtures with Settings → Profiles open.
    private func openProfiles(_ extra: [String] = []) -> XCUIApplication {
        let app = launchHarbor(["--fixtures", "shell"] + extra)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "no tab bar")
        tap(app, "account-button", timeout: 30)
        expect(app, "account-sheet")
        tap(app, "account-settings")
        expect(app, "settings-root")
        tap(app, "settings-row-profiles")
        expect(app, "settings-profiles", timeout: 30)
        return app
    }

    private func back(_ app: XCUIApplication, to title: String) {
        let button = app.navigationBars.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no back button to \(title)")
        button.tap()
    }

    /// Replaces the name field's text.
    private func typeName(_ app: XCUIApplication, _ text: String) {
        let field = expect(app, "profile-name-field")
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != "Who is this for?" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    /// Saves the open editor and waits for it to close.
    private func save(_ app: XCUIApplication) {
        tap(app, "profile-save")
        XCTAssertTrue(gone(app, "profile-editor"), "the editor stayed open after saving")
    }

    // MARK: Tests

    /// Add a profile, rename it, delete it (TV NavigationTests6/8: add / edit / delete a profile).
    func testAddEditDeleteProfile() throws {
        let app = openProfiles()
        expect(app, "manage-profile-p_fix_1")
        expect(app, "manage-profile-p_fix_2")
        expect(app, "manage-profile-p_fix_3")
        snap("profiles-list")

        tap(app, "settings-add-profile")
        expect(app, "profile-editor")
        expect(app, "profile-save")
        XCTAssertFalse(app.buttons["profile-save"].firstMatch.isEnabled, "Create is on with no name")
        typeName(app, "Nova")
        snap("profile-new")
        save(app)
        let nova = app.buttons["Edit Nova"].firstMatch
        XCTAssertTrue(nova.waitForExistence(timeout: 15), "the new profile is not listed")

        nova.tap()
        expect(app, "profile-editor")
        typeName(app, "Nova2")
        save(app)
        XCTAssertTrue(app.buttons["Edit Nova2"].firstMatch.waitForExistence(timeout: 15), "the rename is not listed")
        XCTAssertFalse(app.buttons["Edit Nova"].firstMatch.exists, "the old name is still listed")

        app.buttons["Edit Nova2"].firstMatch.tap()
        expect(app, "profile-editor")
        tap(app, "profile-delete")
        let confirm = app.alerts.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no delete confirmation")
        confirm.tap()
        XCTAssertTrue(gone(app, "profile-editor"), "the editor stayed open after deleting")
        XCTAssertTrue(app.buttons["Edit Nova2"].firstMatch.waitForNonExistence(timeout: 15), "the deleted profile is still listed")
        snap("profile-deleted")
    }

    /// A saved rename is still there after the app is relaunched.
    func testSavePersistsAfterRelaunch() throws {
        var app = openProfiles()
        tap(app, "manage-profile-p_fix_2")
        expect(app, "profile-editor")
        typeName(app, "Visitor")
        save(app)
        XCTAssertTrue(app.buttons["Edit Visitor"].firstMatch.waitForExistence(timeout: 15), "the rename is not listed")
        sleep(2)

        app = openProfiles(["--keep-profiles"])
        let renamed = app.buttons["Edit Visitor"].firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 30), "the rename did not survive the relaunch")
        snap("profile-persisted")

        // Put the fixture back.
        renamed.tap()
        expect(app, "profile-editor")
        typeName(app, "Guest")
        save(app)
        XCTAssertTrue(app.buttons["Edit Guest"].firstMatch.waitForExistence(timeout: 15))
    }

    /// Set a PIN on the primary profile; switching away and back then asks for it, a wrong PIN stays on the pad.
    func testPinGatesSwitching() throws {
        let app = openProfiles()
        tap(app, "manage-profile-p_fix_1")
        expect(app, "profile-editor")
        wait(app, "profile-pin-state", "label == 'PIN off'", "Skipper starts with a PIN")
        tap(app, "profile-pin-set")
        enterPin(app, "2468")
        // The confirm step asks for it again.
        sleep(1)
        enterPin(app, "2468")
        XCTAssertTrue(gone(app, "pin-pad"), "the PIN pad stayed up after confirming")
        wait(app, "profile-pin-state", "label == 'PIN on'", "the PIN was not set")
        snap("profile-pin-on")
        save(app)
        wait(app, "manage-profile-p_fix_1", "value CONTAINS 'Primary'", "the list lost the primary")

        back(app, to: "Settings")
        back(app, to: "Account")
        tap(app, "account-switch-profile")
        expect(app, "who-is-watching", timeout: 20)
        tap(app, "profile-Guest")
        enterPin(app, "1234")
        expect(app, "account-button", timeout: 30)

        tap(app, "account-button")
        expect(app, "account-sheet")
        tap(app, "account-switch-profile")
        expect(app, "who-is-watching", timeout: 20)
        tap(app, "profile-Skipper")
        enterPin(app, "0000")
        expect(app, "pin-pad")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "a wrong PIN let the profile in")
        snap("profile-pin-wrong")
        // The pad cleared its dots and takes the right PIN next.
        enterPin(app, "2468")
        expect(app, "account-button", timeout: 30)
    }

    /// Change and remove a PIN: both ask for the current one first.
    func testChangeAndRemovePin() throws {
        let app = openProfiles()
        tap(app, "manage-profile-p_fix_1")
        expect(app, "profile-editor")
        tap(app, "profile-pin-set")
        enterPin(app, "1357")
        sleep(1)
        enterPin(app, "1357")
        XCTAssertTrue(gone(app, "pin-pad"))
        wait(app, "profile-pin-state", "label == 'PIN on'", "the PIN was not set")

        tap(app, "profile-pin-remove")
        // The active profile just set its PIN, so the session is unlocked: removing may not ask.
        if element(app, "pin-pad").waitForExistence(timeout: 3) {
            enterPin(app, "1357")
        }
        wait(app, "profile-pin-state", "label == 'PIN off'", "the PIN was not removed")
        save(app)
    }

    /// A kid profile synced from the TV still lists, shows how it was set up, and has no kid controls to change.
    func testKidProfileStillLists() throws {
        let app = openProfiles()
        let row = expect(app, "manage-profile-p_fix_3")
        XCTAssertTrue((row.value as? String ?? "").contains("Kid profile"), "the kid row does not say Kid profile (\(String(describing: row.value)))")
        row.tap()
        expect(app, "profile-editor")
        expect(app, "profile-kid-info")
        XCTAssertFalse(element(app, "profile-pin-set").exists, "a kid profile offers an adult PIN")
        snap("profile-kid")
        tap(app, "profile-cancel")
        XCTAssertTrue(gone(app, "profile-editor"))
    }

    /// Touch and hold a face on Who's watching → Edit profile.
    func testLongPressOpensEditor() throws {
        let app = launchHarbor(["--fixtures", "shell"])
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "no tab bar")
        tap(app, "account-button", timeout: 30)
        expect(app, "account-sheet")
        tap(app, "account-switch-profile")
        expect(app, "who-is-watching", timeout: 20)
        let guest = expect(app, "profile-Guest")
        guest.press(forDuration: 1.2)
        let edit = expect(app, "who-edit-p_fix_2", timeout: 10)
        snap("who-context-menu")
        edit.tap()
        expect(app, "profile-editor")
        let field = expect(app, "profile-name-field")
        XCTAssertEqual(field.value as? String, "Guest")
        tap(app, "profile-cancel")
        XCTAssertTrue(gone(app, "profile-editor"))
    }
}
