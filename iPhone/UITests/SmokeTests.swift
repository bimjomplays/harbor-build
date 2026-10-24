import XCTest

/// Taps through HarborPhone on the fixture profiles (`--fixtures onboarding|who|shell`, see
/// App/Shared/App/Fixtures.swift) and attaches a screenshot of each screen. Nothing here touches the
/// network except the engine boot test, which runs the bundled engine and no more.
///
/// The English UI is assumed: tab and chip names are looked up by their English labels.
final class SmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = launchHarbor(arguments)
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

    /// Anything on screen with this accessibility identifier, whatever kind of element it is.
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Anything whose identifier starts with `prefix`.
    private func element(_ app: XCUIApplication, prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
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

    private func enterPin(_ app: XCUIApplication, _ digits: String) {
        expect(app, "pin-pad")
        for digit in digits {
            tap(app, "pin-key-\(digit)")
        }
    }

    /// The back button of a screen pushed in the account sheet (it carries the sheet's title).
    private func back(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons["Account"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no back button")
        button.tap()
    }

    /// Leaves the title page: the link sheet's close button, else the bar's Back.
    private func closeDetail(_ app: XCUIApplication) {
        if element(app, "detail-close").exists {
            element(app, "detail-close").tap()
        } else {
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    private func waitForShell(_ app: XCUIApplication) {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "no tab bar")
    }

    // MARK: Tests

    /// Setup → the first profile → the shell. Language, TMDB and Stremio are all skipped, so nothing
    /// here needs the engine or the network.
    func testOnboardingToShell() throws {
        let app = launch(["--fixtures", "onboarding"])
        expect(app, "onboarding", timeout: 30)
        snap(app, "onboarding-language")

        tap(app, "onboarding-continue")
        expect(app, "tmdb-key")
        snap(app, "onboarding-tmdb")
        tap(app, "tmdb-skip")

        expect(app, "stremio-email")
        snap(app, "onboarding-stremio")
        tap(app, "stremio-skip")

        expect(app, "onboarding-recap")
        snap(app, "onboarding-done")
        tap(app, "onboarding-start")

        // Setup made the one profile; with a single profile the app goes straight to the shell.
        // Either shows within 10 s; the wait ends on whichever comes.
        let who = element(app, "who-is-watching")
        if firstToExist([who, app.tabBars.firstMatch], timeout: 10) == who {
            tap(app, "profile-Harbor")
        }
        waitForShell(app)
        snap(app, "onboarding-shell")
    }

    /// Who's watching, a PIN profile, then the shell on that profile.
    func testWhoIsWatchingAndPin() throws {
        let app = launch(["--fixtures", "who"])
        expect(app, "who-is-watching", timeout: 30)
        expect(app, "profile-Skipper")
        expect(app, "profile-Guest")
        expect(app, "profile-Kiddo")
        snap(app, "who-is-watching")

        tap(app, "profile-Guest")
        enterPin(app, "1234")
        snap(app, "pin-entered")
        waitForShell(app)
        expect(app, "account-button")
    }

    /// A wrong PIN shakes and stays; the right one gets in.
    func testWrongPinStaysOnPad() throws {
        let app = launch(["--fixtures", "who"])
        tap(app, "profile-Guest", timeout: 30)
        enterPin(app, "9999")
        expect(app, "pin-pad")
        snap(app, "pin-wrong")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "a wrong PIN let the profile in")
    }

    /// Every tab on the shell fixtures, with the chips of the tabs that have them (Live and Library).
    func testEveryTabAndChips() throws {
        let app = launch(["--fixtures", "shell"])
        waitForShell(app)

        // Home: the feed builds from the fixture rows, with Continue Watching on top of them.
        expect(app, "rail-Continue Watching", timeout: 30)
        XCTAssertTrue(element(app, prefix: "tile-").waitForExistence(timeout: 10), "no title tiles on Home")
        snap(app, "tab-home")
        // Home is one screen the viewer arranges: no room chips, an Edit Home button instead.
        expect(app, "home-edit")
        XCTAssertFalse(element(app, "chips-Home").exists, "Home still has room chips")
        XCTAssertFalse(element(app, "chip-Movies").exists, "Movies is still a chip")

        let tabs: [(tab: String, chips: [String])] = [
            ("Discover", []),
            ("Live", ["Live TV", "Sports"]),
            ("Library", ["Library", "Collections", "Calendar"]),
        ]
        for entry in tabs {
            tapTab(app, entry.tab)
            for chip in entry.chips {
                tap(app, "chip-\(chip)")
                snap(app, "tab-\(entry.tab.lowercased())-\(chip.lowercased().replacingOccurrences(of: " ", with: "-"))")
            }
            if entry.chips.isEmpty { snap(app, "tab-\(entry.tab.lowercased())") }
        }

        tapTab(app, "Home")
        expect(app, "rail-Continue Watching")

        // Search goes last: with the search tab selected the iOS 26 bar folds the other tabs away, so
        // there is no way back to Home by its tab button from there.
        tapTab(app, "Search")
        snap(app, "tab-search")
    }

    /// The Resume strip is an iOS 26.1 API: it is looked for and photographed, but its absence on
    /// an older runtime does not fail the run.
    func testResumeAccessory() throws {
        let app = launch(["--fixtures", "shell"])
        waitForShell(app)
        expect(app, "rail-Continue Watching", timeout: 30)
        let strip = element(app, "resume-accessory")
        _ = strip.waitForExistence(timeout: 10)
        snap(app, "resume-accessory")
    }

    /// The profile button's sheet, About (which boots the engine), and back out through Who's watching.
    func testAccountSheetAboutAndSwitchProfile() throws {
        let app = launch(["--fixtures", "shell"])
        waitForShell(app)
        tap(app, "account-button", timeout: 30)
        expect(app, "account-sheet")
        XCTAssertEqual(element(app, "account-name").label, "Skipper")
        snap(app, "account-sheet")

        tap(app, "account-settings")
        expect(app, "settings-root")
        snap(app, "account-settings")
        back(app)

        tap(app, "account-about")
        let status = expect(app, "engine-status", timeout: 30)
        expect(app, "build-label")
        let booted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "Engine booted"), object: status)
        let result = XCTWaiter().wait(for: [booted], timeout: 120)
        snap(app, "about-engine")
        XCTAssertEqual(result, .completed, "engine did not boot: \(status.label)")
        back(app)

        tap(app, "account-switch-profile")
        expect(app, "who-is-watching", timeout: 20)
        snap(app, "who-from-account")
    }

    /// A kid profile gets the kids shell, and leaving it asks for the parent PIN.
    func testKidShellAndParentPin() throws {
        let app = launch(["--fixtures", "who"])
        tap(app, "profile-Kiddo", timeout: 30)
        expect(app, "kids-shell")
        expect(app, "kids-greeting")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "a kid profile got the adult tab bar")
        snap(app, "kids-shell")

        tap(app, "kids-exit")
        enterPin(app, "4321")
        expect(app, "who-is-watching", timeout: 20)
    }

    /// The curfew cover (launched as if the allowance were spent) holds the kid until a parent PIN lifts it.
    func testCurfewCoverAndParentPin() throws {
        let app = launch(["--fixtures", "who", "--phone-curfew"])
        tap(app, "profile-Kiddo", timeout: 30)
        expect(app, "curfew-cover")
        snap(app, "curfew-cover")

        tap(app, "curfew-parent-pin")
        enterPin(app, "4321")
        let cover = element(app, "curfew-cover")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: cover)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 20), .completed, "the cover stayed up after the parent PIN")
        expect(app, "kids-shell")
    }

    /// A harbor:// link opens the title page once the shell is clear.
    func testDeepLinkOpensTitle() throws {
        let app = launch(["--fixtures", "shell", "--phone-open", "harbor://detail/movie/tt0000001"])
        expect(app, "detail-sheet", timeout: 40)
        expect(app, "detail-page")
        expect(app, "detail-actions")
        snap(app, "deep-link-title")
        tap(app, "detail-close")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, "detail-page"))
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 20), .completed, "the title page did not close")
    }

    /// An addon link opens the install sheet and reads the link (this one is no addon: it says so).
    /// AddonsTests installs one from a link.
    func testDeepLinkInstall() throws {
        let app = launch(["--fixtures", "shell", "--phone-open", "stremio://example.invalid/manifest.json"])
        expect(app, "install-sheet", timeout: 40)
        expect(app, "install-error")
        snap(app, "deep-link-install")
        tap(app, "install-done")
    }

    /// A tile opens the title page.
    func testTileOpensTitle() throws {
        let app = launch(["--fixtures", "shell"])
        waitForShell(app)
        let tile = element(app, prefix: "tile-")
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "no tiles on Home")
        tile.tap()
        expect(app, "detail-page")
        expect(app, "detail-actions")
        snap(app, "tile-title")
        closeDetail(app)
        expect(app, "feed-home")
    }
}
