import XCTest

/// Addons on the fixture list (`--fixtures shell`): reached from the account sheet, an
/// addon installed from a typed URL, the order changed and saved, an addon swiped away, the QR scan
/// on a device without a camera (the simulator), a stremio:// link from another app installed, and
/// Play on a title from an addon's catalog opening the play picker inside the account sheet.
/// The fixture list (PhoneAddonsFixtures) starts as Cinemeta, OpenSubtitles, Fixture Streams on every
/// launch and never touches the network. Every step attaches a screenshot.
///
/// Rows are moved with their Move menu, not by dragging, so the order is deterministic. The English UI
/// is assumed where a control has no id (menu items, swipe actions).
final class AddonsTests: XCTestCase {
    private let installable = "https://fixture.example/community/manifest.json"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

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

    private func tap(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        expect(app, id, timeout: timeout, file: file, line: line).tap()
    }

    private func gone(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20) -> Bool {
        let missing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, id))
        return XCTWaiter().wait(for: [missing], timeout: timeout) == .completed
    }

    /// An item of an open menu: by its id where the menu passes it on, else by its English label.
    private func tapMenuItem(_ app: XCUIApplication, id: String, label: String, file: StaticString = #filePath, line: UInt = #line) {
        let byId = element(app, id)
        if byId.waitForExistence(timeout: 5) {
            byId.tap()
            return
        }
        let byLabel = app.buttons[label].firstMatch
        XCTAssertTrue(byLabel.waitForExistence(timeout: 5), "no menu item \(label)", file: file, line: line)
        byLabel.tap()
    }

    /// The shell, then the account sheet, then Addons (it opens on Installed).
    private func openAddons() -> XCUIApplication {
        let app = launchHarbor(["--fixtures", "shell"])
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "no tab bar")
        tap(app, "account-button", timeout: 30)
        expect(app, "account-sheet")
        tap(app, "account-addons")
        expect(app, "addons-screen")
        expect(app, "addon-row-Cinemeta")
        snap(app, "addons-installed")
        return app
    }

    private func names(_ app: XCUIApplication, _ rows: [String]) -> [String] {
        rows.map { (name: $0, y: element(app, "addon-row-\($0)").frame.minY) }.sorted { $0.y < $1.y }.map(\.name)
    }

    // MARK: Tests

    /// The account sheet's Addons lists the installed addons; an addon opens its page.
    func testInstalledListAndAddonPage() throws {
        let app = openAddons()
        expect(app, "addon-row-OpenSubtitles")
        expect(app, "addon-row-Fixture Streams")
        XCTAssertEqual(names(app, ["Cinemeta", "OpenSubtitles", "Fixture Streams"]), ["Cinemeta", "OpenSubtitles", "Fixture Streams"])

        tap(app, "addon-row-Cinemeta")
        expect(app, "addon-page")
        expect(app, "addon-page-primary")
        expect(app, "addon-page-catalogs")
        snap(app, "addon-page")
    }

    /// An addon's catalog opens a title inside the account sheet, and its Play opens the play picker
    /// there too (the shell's play host sits under the sheet and could not present it).
    func testPlayFromAnAddonCatalog() throws {
        let app = launchHarbor(["--fixtures", "shell", "--fixture-streams"])
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "no tab bar")
        tap(app, "account-button", timeout: 30)
        tap(app, "account-addons")
        tap(app, "addon-row-Cinemeta")
        expect(app, "addon-page")
        let browse = expect(app, "addon-page-browse")
        var drags = 0
        while !browse.isHittable && drags < 6 {
            app.swipeUp()
            drags += 1
        }
        browse.tap()
        expect(app, "route-addon")
        tap(app, "tile-fx-addon-popular-0", timeout: 30)
        expect(app, "detail-page", timeout: 30)
        let play = expect(app, "detail-play")
        drags = 0
        while !play.isHittable && drags < 6 {
            app.swipeUp()
            drags += 1
        }
        snap(app, "addon-title")
        play.tap()
        // Instant play on a fixture film can go straight past the picker to the player.
        let player = element(app, "player-screen")
        if firstToExist([element(app, "phone-picker"), player], timeout: 40) == nil {
            snap(app, "addon-title-nothing")
            XCTFail("Play opened neither the picker nor the player")
        }
        snap(app, "addon-title-picker")
        if player.exists {
            tap(app, "player-close", timeout: 5)
            if element(app, "player-leave").waitForExistence(timeout: 3) { tap(app, "player-leave") }
            XCTAssertTrue(gone(app, "player-screen"), "the player did not close")
            expect(app, "detail-page", timeout: 20)
        }
        XCTAssertTrue(element(app, "account-sheet").exists, "the account sheet closed under the picker")
    }

    /// Add from URL: type the manifest URL, Read, Install; the sheet closes and the addon is listed last.
    func testInstallByUrl() throws {
        let app = openAddons()
        XCTAssertFalse(element(app, "addon-row-Fixture Community").exists)

        tap(app, "addons-add")
        tapMenuItem(app, id: "addons-add-url", label: "Add from URL")
        expect(app, "install-sheet")
        let field = expect(app, "install-url")
        field.tap()
        field.typeText(installable)
        snap(app, "install-typed")
        tap(app, "install-read")
        expect(app, "install-card")
        snap(app, "install-read")
        tap(app, "install-confirm")
        expect(app, "install-finished")
        snap(app, "install-finished")
        // The success card closes itself after two seconds.
        XCTAssertTrue(gone(app, "install-sheet", timeout: 15), "the install sheet stayed up")

        expect(app, "addon-row-Fixture Community")
        XCTAssertEqual(names(app, ["Cinemeta", "Fixture Streams", "Fixture Community"]), ["Cinemeta", "Fixture Streams", "Fixture Community"])
        snap(app, "install-listed")
    }

    /// A link that is not an addon says so and installs nothing.
    func testInstallByUrlRejectsABadLink() throws {
        let app = openAddons()
        tap(app, "addons-add")
        tapMenuItem(app, id: "addons-add-url", label: "Add from URL")
        let field = expect(app, "install-url")
        field.tap()
        field.typeText("not a link")
        tap(app, "install-read")
        expect(app, "install-error")
        XCTAssertFalse(element(app, "install-confirm").exists)
        snap(app, "install-error")
        tap(app, "install-done")
        XCTAssertTrue(gone(app, "install-sheet"), "Done did not close the sheet")
    }

    /// Reorder: Fixture Streams moved to the top and saved; the list follows.
    func testReorder() throws {
        let app = openAddons()
        tap(app, "addons-reorder")
        expect(app, "reorder-sheet")
        expect(app, "reorder-row-Fixture Streams")
        snap(app, "reorder-sheet")
        // The button itself: an any-type id query read Save as enabled while it showed greyed out (run 39194356968).
        let save = app.buttons.matching(identifier: "reorder-save").firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "no Save button")
        XCTAssertFalse(save.isEnabled, "Save is on before anything moved")

        tap(app, "reorder-move-Fixture Streams")
        tapMenuItem(app, id: "reorder-to-top", label: "Move to top")
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: save)
        XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 10), .completed, "Save stayed off after a move")
        snap(app, "reorder-moved")
        save.tap()
        XCTAssertTrue(gone(app, "reorder-sheet"), "the reorder sheet stayed up after Save")

        let reordered = ["Fixture Streams", "Cinemeta", "OpenSubtitles"]
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.names(app, reordered) == reordered }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [settled], timeout: 15), .completed,
                       "installed order is \(names(app, reordered)), not \(reordered)")
        snap(app, "reorder-saved")
    }

    /// Swipe a row left and Remove: the addon leaves the list.
    func testUninstallBySwipe() throws {
        let app = openAddons()
        let row = expect(app, "addon-row-OpenSubtitles")
        row.swipeLeft()
        // A long swipe can remove at once; otherwise the Remove action is showing.
        let remove = app.buttons["Remove"].firstMatch
        if remove.waitForExistence(timeout: 5) {
            snap(app, "uninstall-swipe")
            remove.tap()
        }
        XCTAssertTrue(gone(app, "addon-row-OpenSubtitles"), "the removed addon is still listed")
        expect(app, "addon-row-Cinemeta")
        snap(app, "uninstall-done")
    }

    /// Scan QR code: the scan button is there, and the simulator (no camera) gets "camera unavailable".
    func testScanWithoutACamera() throws {
        let app = openAddons()
        tap(app, "addons-add")
        tapMenuItem(app, id: "addons-scan", label: "Scan QR code")
        expect(app, "addon-scanner")
        expect(app, "addon-scan-unavailable", timeout: 30)
        snap(app, "scan-unavailable")
        tap(app, "addon-scan-cancel")
        XCTAssertTrue(gone(app, "addon-scanner"), "the scanner stayed up")
        // The install sheet under it keeps its own Scan button and the paste route.
        expect(app, "install-scan")
        expect(app, "install-paste")
    }

    /// A stremio:// link from another app opens the install sheet, read, and installs.
    func testDeepLinkInstalls() throws {
        let app = launchHarbor(["--fixtures", "shell", "--phone-open", "stremio://fixture.example/community/manifest.json"])
        expect(app, "install-sheet", timeout: 40)
        expect(app, "install-card")
        snap(app, "deep-link-read")
        tap(app, "install-confirm")
        XCTAssertTrue(gone(app, "install-sheet", timeout: 15), "the install sheet stayed up")

        tap(app, "account-button", timeout: 30)
        tap(app, "account-addons")
        expect(app, "addon-row-Fixture Community")
        snap(app, "deep-link-installed")
    }
}
