import XCTest

/// Settings from the account sheet on the shell fixtures (`--fixtures shell`), the phone's take on the
/// TV's NavigationTests6/8: every page opens, a value changed on each saved page is still set after a
/// relaunch, and hiding every room of a tab takes the tab out of the bar. A `--fixtures` relaunch keeps
/// the profile's settings (ProfilesStore.reset clears only the profile list), so each test puts back
/// what it changed, and starts from a known value instead of assuming the last run's.
///
/// The saved values go through the engine, which boots in the background on fixtures; the first change
/// on a launch waits for it. The English UI is assumed.
final class SettingsTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

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
        reveal(app, id, timeout: timeout, file: file, line: line).tap()
    }

    /// Waits until `predicate` holds for the element; a miss fails with the screen attached.
    private func wait(_ app: XCUIApplication, _ id: String, _ predicate: String, _ what: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let found = expect(app, id, file: file, line: line)
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: found)
        if XCTWaiter().wait(for: [match], timeout: timeout) != .completed {
            snap(app, "wait-\(id)")
            XCTFail("\(id): \(what) (label \"\(found.label)\", value \"\(String(describing: found.value))\")", file: file, line: line)
        }
    }

    private func gone(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 15) -> Bool {
        let missing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, id))
        return XCTWaiter().wait(for: [missing], timeout: timeout) == .completed
    }

    /// Drags the page up until the element can be tapped (the Forms run past one screen).
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        // A Form builds its rows lazily: one below the fold does not exist until it is scrolled to.
        let target = element(app, id)
        _ = target.waitForExistence(timeout: 3)
        var drags = 0
        while !(target.exists && target.isHittable) && drags < 12 {
            if drags % 3 == 2 {
                // A held drag that starts on a row sometimes does not scroll; a slow swipe on the list does.
                let list = app.collectionViews.firstMatch
                (list.exists ? list : app).swipeUp(velocity: .slow)
            } else {
                let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
                lower.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
            }
            drags += 1
        }
        _ = expect(app, id, timeout: timeout, file: file, line: line)
        XCTAssertTrue(target.isHittable, "\(id) cannot be reached", file: file, line: line)
        settle(target)
        return target
    }

    /// Waits until the element has stopped moving: a tap on a list still coasting from a drag only stops
    /// the scroll, so the control never sees it (run 39614575410, Harbor's tile after the relaunch).
    private func settle(_ target: XCUIElement) {
        var last = target.frame
        var still = 0
        let deadline = Date().addingTimeInterval(10)
        while still < 2 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let now = target.frame
            still = now == last ? still + 1 : 0
            last = now
        }
    }

    /// A switch's state: "1" on, "0" off.
    private func isOn(_ app: XCUIApplication, _ id: String) -> Bool {
        (expect(app, id).value as? String) == "1"
    }

    /// Flips a switch to `on` and waits for the saved value to come back. A SwiftUI Toggle in a Form
    /// only flips through its switch, not a tap in the row's middle.
    private func setSwitch(_ app: XCUIApplication, _ id: String, _ on: Bool, timeout: TimeInterval = 90, file: StaticString = #filePath, line: UInt = #line) {
        let row = reveal(app, id, file: file, line: line)
        guard isOn(app, id) != on else { return }
        let inner = row.switches.firstMatch
        if inner.exists && inner.isHittable {
            inner.tap()
        } else {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        wait(app, id, "value == '\(on ? "1" : "0")'", "did not turn \(on ? "on" : "off")", timeout: timeout, file: file, line: line)
    }

    /// A fresh `--fixtures shell` launch with Settings open from the account sheet.
    private func openSettings() -> XCUIApplication {
        let app = launchHarbor(["--fixtures", "shell"])
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "no tab bar")
        tap(app, "account-button", timeout: 30)
        expect(app, "account-sheet")
        tap(app, "account-settings")
        expect(app, "settings-root")
        return app
    }

    /// From the Settings list, one page.
    @discardableResult
    private func open(_ app: XCUIApplication, _ page: String, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        tap(app, "settings-row-\(page)", file: file, line: line)
        return expect(app, id, timeout: 30, file: file, line: line)
    }

    private func back(_ app: XCUIApplication, to title: String = "Settings") {
        let button = app.navigationBars.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no back button to \(title)")
        button.tap()
    }

    /// Closes the account sheet (Done sits on its first page, so Settings pages go back to it first)
    /// and waits for the shell under it.
    private func closeSheet(_ app: XCUIApplication) {
        if !element(app, "settings-root").exists { back(app) }
        back(app, to: "Account")
        tap(app, "account-done")
        XCTAssertTrue(gone(app, "account-sheet"), "the account sheet stayed up")
    }

    /// Every element whose identifier starts with `prefix`.
    private func elements(_ app: XCUIApplication, prefix: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    // MARK: Tests

    /// The list has every section; each built page opens, and a page held for a later stage says so.
    func testEveryPageOpens() throws {
        let app = openSettings()
        snap(app, "settings-root")
        let pages: [(String, String)] = [
            ("appearance", "settings-appearance"), ("tabs", "settings-tabs"), ("homeRows", "settings-home-rows"),
            ("animeRows", "settings-anime-rows"), ("spoilers", "settings-spoilers"), ("player", "player-settings"),
            ("streamPriority", "settings-priority"), ("subtitles", "settings-subtitles"),
            ("anime4k", "settings-anime4k"), ("stremio", "settings-stremio"), ("trackers", "trackers-screen"),
            ("tmdb", "settings-tmdb"), ("homeServers", "settings-servers"), ("aiSearch", "settings-ai"),
            ("profiles", "settings-profiles"), ("startup", "settings-startup"), ("about", "settings-about"),
        ]
        for (page, id) in pages {
            open(app, page, id)
            snap(app, "settings-\(page)")
            back(app)
            expect(app, "settings-root")
        }
        open(app, "about", "settings-about")
        wait(app, "settings-about-build", "label BEGINSWITH 'Build '", "no build line")
        tap(app, "settings-about-engine")
        expect(app, "engine-status", timeout: 30)
    }

    /// Spoilers: the switch saves for the profile and shows what it blurs; the list's row says On.
    func testSpoilersPersist() throws {
        var app = openSettings()
        open(app, "spoilers", "settings-spoilers")
        setSwitch(app, "spoilers-hide", false)
        XCTAssertTrue(gone(app, "spoilers-thumb"), "the blur options show with spoilers off")
        setSwitch(app, "spoilers-hide", true)
        expect(app, "spoilers-thumb")
        expect(app, "spoilers-skip-next")
        snap(app, "spoilers-on")
        sleep(2)

        app = openSettings()
        wait(app, "settings-row-spoilers", "label CONTAINS 'On'", "the list does not say On", timeout: 60)
        open(app, "spoilers", "settings-spoilers")
        wait(app, "spoilers-hide", "value == '1'", "hiding spoilers did not survive the relaunch", timeout: 60)
        setSwitch(app, "spoilers-hide", false)
        XCTAssertTrue(gone(app, "spoilers-thumb"), "the blur options stayed after turning spoilers off")
    }

    /// Appearance: a theme pick and Titles under posters both survive a relaunch.
    func testAppearancePersists() throws {
        var app = openSettings()
        open(app, "appearance", "settings-appearance")
        tap(app, "theme-cool-grey", timeout: 60)
        wait(app, "theme-cool-grey", "selected == true", "Harbor did not become the theme", timeout: 60)
        let other = elements(app, prefix: "theme-").matching(NSPredicate(format: "identifier != 'theme-cool-grey'")).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 10), "no other theme to pick")
        let picked = other.identifier
        other.tap()
        wait(app, picked, "selected == true", "\(picked) did not become the theme", timeout: 60)
        setSwitch(app, "appearance-poster-titles", true)
        setSwitch(app, "appearance-poster-titles", false)
        snap(app, "appearance-changed")
        sleep(2)

        app = openSettings()
        open(app, "appearance", "settings-appearance")
        wait(app, picked, "selected == true", "\(picked) did not survive the relaunch", timeout: 60)
        reveal(app, "appearance-poster-titles")
        wait(app, "appearance-poster-titles", "value == '0'", "Titles under posters did not survive the relaunch", timeout: 60)
        setSwitch(app, "appearance-poster-titles", true)
        let harbor = elements(app, prefix: "theme-cool-grey").firstMatch
        if !harbor.isHittable {
            let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            for _ in 0..<4 where !harbor.isHittable {
                upper.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
            }
        }
        tap(app, "theme-cool-grey")
        wait(app, "theme-cool-grey", "selected == true", "Harbor did not come back as the theme", timeout: 60)
    }

    /// Home rows and Anime rows: a Continue Watching switch and an anime pick are saved in the engine.
    func testHomeAndAnimeRowsPersist() throws {
        var app = openSettings()
        open(app, "homeRows", "settings-home-rows")
        expect(app, "home-rows-edit")
        expect(app, "home-rows-cw-advance", timeout: 90)
        let advance = !isOn(app, "home-rows-cw-advance")
        setSwitch(app, "home-rows-cw-advance", advance)
        back(app)
        open(app, "animeRows", "settings-anime-rows")
        expect(app, "anime-hide-watched", timeout: 90)
        let hideWatched = !isOn(app, "anime-hide-watched")
        setSwitch(app, "anime-hide-watched", hideWatched)
        snap(app, "anime-rows-changed")
        sleep(2)

        app = openSettings()
        open(app, "homeRows", "settings-home-rows")
        wait(app, "home-rows-cw-advance", "value == '\(advance ? "1" : "0")'", "the Continue Watching switch did not survive the relaunch", timeout: 90)
        setSwitch(app, "home-rows-cw-advance", !advance)
        back(app)
        open(app, "animeRows", "settings-anime-rows")
        wait(app, "anime-hide-watched", "value == '\(hideWatched ? "1" : "0")'", "Hide anime I've already watched did not survive the relaunch", timeout: 90)
        setSwitch(app, "anime-hide-watched", !hideWatched)
    }

    /// Stream priority: tapping an addon puts it first, still first after a relaunch; Installed order
    /// puts the list back.
    func testStreamPriorityPersists() throws {
        var app = openSettings()
        open(app, "streamPriority", "settings-priority")
        expect(app, "priority-row-fixture.streams", timeout: 60)
        if element(app, "priority-reset").exists { tap(app, "priority-reset") }
        tap(app, "priority-row-fixture.torrents")
        wait(app, "priority-row-fixture.torrents", "value == 'First'", "Fixture Torrents did not lead", timeout: 90)
        snap(app, "priority-first")
        sleep(2)

        app = openSettings()
        open(app, "streamPriority", "settings-priority")
        wait(app, "priority-row-fixture.torrents", "value == 'First'", "the order did not survive the relaunch", timeout: 90)
        tap(app, "priority-reset")
        XCTAssertTrue(gone(app, "priority-reset"), "Installed order stayed after it was used")
        wait(app, "priority-row-fixture.torrents", "value != 'First'", "Fixture Torrents still leads", timeout: 60)
    }

    /// Subtitles: a language switched on is still on after a relaunch.
    func testSubtitleLanguagesPersist() throws {
        var app = openSettings()
        open(app, "subtitles", "settings-subtitles")
        reveal(app, "subs-lang-Japanese", timeout: 60)
        if element(app, "subs-lang-Japanese").isSelected { tap(app, "subs-lang-Japanese") }
        wait(app, "subs-lang-Japanese", "selected == false", "Japanese stayed chosen", timeout: 90)
        tap(app, "subs-lang-Japanese")
        wait(app, "subs-lang-Japanese", "selected == true", "Japanese was not chosen", timeout: 90)
        expect(app, "subs-reorder")
        snap(app, "subtitles-japanese")
        sleep(2)

        app = openSettings()
        open(app, "subtitles", "settings-subtitles")
        reveal(app, "subs-lang-Japanese", timeout: 60)
        wait(app, "subs-lang-Japanese", "selected == true", "Japanese did not survive the relaunch", timeout: 90)
        tap(app, "subs-lang-Japanese")
        wait(app, "subs-lang-Japanese", "selected == false", "Japanese stayed chosen", timeout: 90)
    }

    /// Anime4K: its switch and the Indicator are set; the Indicator is still set after a relaunch.
    func testAnime4KPersists() throws {
        var app = openSettings()
        open(app, "anime4k", "settings-anime4k")
        setSwitch(app, "anime4k-on", true)
        expect(app, "anime4k-mode-A")
        expect(app, "anime4k-download")
        reveal(app, "anime4k-indicator")
        let indicator = !isOn(app, "anime4k-indicator")
        setSwitch(app, "anime4k-indicator", indicator)
        snap(app, "anime4k-changed")
        setSwitch(app, "anime4k-on", false)
        sleep(2)

        app = openSettings()
        open(app, "anime4k", "settings-anime4k")
        reveal(app, "anime4k-indicator", timeout: 90)
        wait(app, "anime4k-indicator", "value == '\(indicator ? "1" : "0")'", "the Indicator did not survive the relaunch", timeout: 90)
        setSwitch(app, "anime4k-indicator", !indicator)
    }

    /// AI search: the provider and Live web context are saved; with no key the Save buttons wait.
    func testAISearchPersists() throws {
        var app = openSettings()
        open(app, "aiSearch", "settings-ai")
        expect(app, "ai-provider-openrouter", timeout: 90)
        tap(app, "ai-provider-groq")
        wait(app, "ai-provider-groq", "selected == true", "Groq was not chosen", timeout: 90)
        XCTAssertFalse(element(app, "ai-key-save").isEnabled, "Save is on with no key typed")
        reveal(app, "ai-web")
        let web = !isOn(app, "ai-web")
        setSwitch(app, "ai-web", web)
        snap(app, "ai-groq")
        sleep(2)

        app = openSettings()
        open(app, "aiSearch", "settings-ai")
        wait(app, "ai-provider-groq", "selected == true", "Groq did not survive the relaunch", timeout: 90)
        // The provider rows sit above the fold once Live web is revealed, so put OpenRouter back first.
        tap(app, "ai-provider-openrouter")
        wait(app, "ai-provider-openrouter", "selected == true", "OpenRouter did not come back", timeout: 90)
        reveal(app, "ai-web", timeout: 90)
        wait(app, "ai-web", "value == '\(web ? "1" : "0")'", "Live web did not survive the relaunch", timeout: 90)
        setSwitch(app, "ai-web", !web)
    }

    /// Stremio and TMDB: signed out and no key on the fixtures, so each shows its form, and Sign in /
    /// Verify wait for what they need. (A sign-in and a key check go to the network, not run here.)
    func testStremioAndTmdbForms() throws {
        let app = openSettings()
        open(app, "stremio", "settings-stremio")
        expect(app, "stremio-email")
        expect(app, "stremio-password")
        XCTAssertFalse(element(app, "stremio-sign-in").isEnabled, "Sign in is on with nothing typed")
        back(app)
        open(app, "tmdb", "settings-tmdb")
        expect(app, "tmdb-status")
        expect(app, "tmdb-key")
        XCTAssertFalse(element(app, "tmdb-verify").isEnabled, "Verify is on with no key typed")
        XCTAssertFalse(element(app, "tmdb-remove").exists, "Remove key shows with no key saved")
        snap(app, "tmdb-empty")
    }

    /// Home servers: a Jellyfin server is added (in memory on the fixtures), tested, and removed.
    func testHomeServerAddAndRemove() throws {
        let app = openSettings()
        open(app, "homeServers", "settings-servers")
        expect(app, "servers-empty")
        tap(app, "server-address")
        // Return moves to the next field and the last one puts the keyboard away, so no field is ever under it.
        element(app, "server-address").typeText("http://192.168.1.20:8096\n")
        element(app, "server-username").typeText("sam\n")
        element(app, "server-password").typeText("secret\n")
        tap(app, "server-connect")
        expect(app, "server-row-fx-1", timeout: 30)
        XCTAssertTrue(gone(app, "servers-empty"), "the empty line stayed with a server added")
        snap(app, "servers-added")
        tap(app, "server-test-fx-1")
        // The result line is the last section, below the add form; then back up to the server's rows.
        reveal(app, "servers-note", timeout: 30)
        snap(app, "servers-tested")
        for _ in 0..<3 { app.collectionViews.firstMatch.swipeDown() }
        expect(app, "server-enabled-fx-1")
        setSwitch(app, "server-enabled-fx-1", false)
        setSwitch(app, "server-enabled-fx-1", true)
        tap(app, "server-remove-fx-1")
        tap(app, "server-remove-confirm")
        XCTAssertTrue(gone(app, "server-row-fx-1"), "the server stayed after Remove")
        expect(app, "servers-empty")
    }

    /// Edit Home opens from Home rows over Settings and closes back to it.
    func testHomeRowsOpensEditHome() throws {
        let app = openSettings()
        open(app, "homeRows", "settings-home-rows")
        tap(app, "home-rows-edit")
        expect(app, "home-editor-add", timeout: 30)
        snap(app, "home-rows-editor")
        tap(app, "home-editor-done")
        XCTAssertTrue(gone(app, "home-editor-add"), "Edit Home stayed up")
        expect(app, "settings-home-rows")
    }

    /// Startup & default: the prompt interval is saved and the list's row shows it.
    func testStartupDefaultsPersist() throws {
        var app = openSettings()
        open(app, "startup", "settings-startup")
        tap(app, "startup-interval-launch")
        wait(app, "startup-interval-launch", "selected == true", "Every launch is not marked", timeout: 90)
        tap(app, "startup-interval-never")
        wait(app, "startup-interval-never", "selected == true", "Never is not marked", timeout: 60)
        expect(app, "startup-default-none")
        snap(app, "startup-never")
        sleep(2)

        app = openSettings()
        reveal(app, "settings-row-startup")
        wait(app, "settings-row-startup", "label CONTAINS 'Never'", "the list does not say Never", timeout: 60)
        open(app, "startup", "settings-startup")
        wait(app, "startup-interval-never", "selected == true", "Never did not survive the relaunch", timeout: 60)
        tap(app, "startup-interval-launch")
        wait(app, "startup-interval-launch", "selected == true", "Every launch did not come back", timeout: 60)
    }

    /// Tabs: Live TV and Sports off takes the Live tab out of the bar, still after a relaunch; Show all
    /// tabs brings it back. Calendar off leaves Library's chips without it.
    func testHidingATabsRoomsRemovesTheTab() throws {
        var app = openSettings()
        open(app, "tabs", "settings-tabs")
        expect(app, "tabs-toggle-live", timeout: 60)
        if element(app, "tabs-show-all").isEnabled { tap(app, "tabs-show-all") }
        wait(app, "tabs-toggle-live", "value == '1'", "Live TV is not shown to start with", timeout: 90)
        setSwitch(app, "tabs-toggle-live", false)
        setSwitch(app, "tabs-toggle-sports", false)
        setSwitch(app, "tabs-toggle-calendar", false)
        snap(app, "tabs-hidden")
        closeSheet(app)

        let bar = app.tabBars.firstMatch
        let liveGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: bar.buttons["Live"].firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [liveGone], timeout: 15), .completed, "the Live tab stayed with all its rooms hidden")
        XCTAssertTrue(bar.buttons["Library"].firstMatch.exists, "the Library tab went too")
        tapTab(app, "Library")
        expect(app, "chip-Library", timeout: 30)
        XCTAssertTrue(gone(app, "chip-Calendar"), "Calendar is still a Library chip")
        snap(app, "tabs-without-live")
        sleep(2)

        app = openSettings()
        open(app, "tabs", "settings-tabs")
        wait(app, "tabs-toggle-live", "value == '0'", "hiding Live TV did not survive the relaunch", timeout: 60)
        closeSheet(app)
        XCTAssertFalse(app.tabBars.firstMatch.buttons["Live"].firstMatch.waitForExistence(timeout: 3), "the Live tab is back after the relaunch")

        tap(app, "account-button")
        tap(app, "account-settings")
        open(app, "tabs", "settings-tabs")
        tap(app, "tabs-show-all")
        wait(app, "tabs-toggle-live", "value == '1'", "Show all tabs did not show Live TV", timeout: 60)
        wait(app, "tabs-toggle-calendar", "value == '1'", "Show all tabs did not show Calendar", timeout: 60)
        closeSheet(app)
        XCTAssertTrue(app.tabBars.firstMatch.buttons["Live"].firstMatch.waitForExistence(timeout: 15), "the Live tab did not come back")
        tapTab(app, "Library")
        expect(app, "chip-Calendar", timeout: 30)
    }
}
