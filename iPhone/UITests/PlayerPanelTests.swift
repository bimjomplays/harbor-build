import XCTest

/// The phone player's panel sheets and lock on fixtures: `--fixtures detail
/// --fixture-streams --phone-picker` opens the play picker on a fixture film and a pick opens the player
/// over its stand-in engine (PhoneFixturePlayer). The stand-in has two audio tracks (1 English, 2 Japanese)
/// and two subtitle tracks (3 English, 4 Spanish), and its label (`player-fixture`) reads "fixture <pos> /
/// 2:00:00 · fit|fill · audio <id|off> · sub <id|off> · rate <n> · delay <audio>/<sub> · … · saved …", so
/// a change a sheet makes is read back from the engine, and the HUD's buttons read it back from the
/// session. The sheets open from the HUD's gear menu (a system menu: its rows are found by their titles).
/// Under fixtures the HUD holds 30 s after the last touch. The English UI is assumed.
final class PlayerPanelTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: Helpers

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        launchHarbor(["--fixtures", "detail", "--fixture-streams", "--phone-picker"] + extra)
    }

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

    private func dumpTree(_ app: XCUIApplication, _ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "hierarchy-\(name)"
        tree.lifetime = .keepAlways
        add(tree)
    }

    @discardableResult
    private func expect(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let found = element(app, id)
        if !found.waitForExistence(timeout: timeout) {
            dumpTree(app, "missing-\(id)")
            snap("missing-\(id)")
            XCTFail("no element \(id)", file: file, line: line)
        }
        return found
    }

    private func tap(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        expect(app, id, timeout: timeout, file: file, line: line).tap()
    }

    private func expectGone(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let wait = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, id))
        if XCTWaiter.wait(for: [wait], timeout: timeout) != .completed {
            dumpTree(app, "still-\(id)")
            snap("still-\(id)")
            XCTFail("\(id) is still on screen", file: file, line: line)
        }
    }

    private func seconds(_ clock: String) -> Double? {
        let parts = clock.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    private func fixtureText(_ app: XCUIApplication) -> String {
        let label = element(app, "player-fixture")
        return label.exists ? label.label : ""
    }

    private func position(_ app: XCUIApplication) -> Double? {
        guard let head = fixtureText(app).components(separatedBy: " · ").first, head.hasPrefix("fixture ") else { return nil }
        return seconds(String(head.dropFirst("fixture ".count).split(separator: " ").first ?? ""))
    }

    /// Waits until the stand-in's label has `part` in it ("audio 2", "rate 1.5").
    private func expectFixture(_ app: XCUIApplication, _ part: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let reads = NSPredicate { _, _ in self.fixtureText(app).contains(part) }
        if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: reads, object: nil)], timeout: timeout) != .completed {
            snap("fixture-\(part)")
            XCTFail("the engine does not read \"\(part)\": \"\(fixtureText(app))\"", file: file, line: line)
        }
    }

    private func expectPosition(_ app: XCUIApplication, _ what: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line, _ ok: @escaping (Double) -> Bool) {
        let reads = NSPredicate { _, _ in self.position(app).map(ok) ?? false }
        if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: reads, object: nil)], timeout: timeout) != .completed {
            snap("position-\(what)")
            XCTFail("the player is not \(what): \"\(fixtureText(app))\"", file: file, line: line)
        }
    }

    /// The value a HUD button reads out (its accessibilityValue).
    private func value(_ app: XCUIApplication, _ id: String) -> String {
        (element(app, id).value as? String) ?? ""
    }

    private func expectValue(_ app: XCUIApplication, _ id: String, _ want: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        let reads = NSPredicate { _, _ in self.value(app, id) == want }
        if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: reads, object: nil)], timeout: timeout) != .completed {
            snap("value-\(id)")
            XCTFail("\(id) reads \"\(value(app, id))\", not \"\(want)\"", file: file, line: line)
        }
    }

    private func pickFirst(_ app: XCUIApplication) {
        expect(app, "phone-picker", timeout: 40)
        tap(app, "stream-0", timeout: 30)
        expect(app, "player-screen", timeout: 20)
        expect(app, "player-fixture", timeout: 10)
        if element(app, "player-resume").waitForExistence(timeout: 2) { tap(app, "player-resume") }
    }

    private func wakeHUD(_ app: XCUIApplication) {
        if !element(app, "player-hud").exists {
            expect(app, "player-stage").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        }
        expect(app, "player-hud", timeout: 5)
    }

    /// A row of the open gear menu whose title starts with `title` (menu rows carry no identifiers).
    private func menuRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func tapMenuRow(_ app: XCUIApplication, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = menuRow(app, title)
        if !row.waitForExistence(timeout: 5) {
            dumpTree(app, "missing-menu-\(title)")
            snap("missing-menu-\(title)")
            XCTFail("no menu row \(title)", file: file, line: line)
            return
        }
        row.tap()
    }

    /// The gear menu's way to each sheet: the audio row's Audio Sync, the subtitle row's Search, Sync &
    /// Style, the rest under Advanced Options.
    private func menuPath(_ panel: String) -> [String] {
        switch panel {
        case "audio": return ["English - ", "Audio Sync"]
        case "subtitles": return ["None", "Search, Sync"]
        case "speed": return ["Advanced Options", "Speed & Sleep"]
        case "stats": return ["Advanced Options", "Stats"]
        case "sources": return ["Advanced Options", "Sources"]
        default: return ["Advanced Options", panel.capitalized]
        }
    }

    /// Opens a panel through the HUD's gear menu: its sheet comes up and the HUD goes behind it.
    private func open(_ app: XCUIApplication, _ panel: String) {
        wakeHUD(app)
        tap(app, "player-gear", timeout: 5)
        for row in menuPath(panel) { tapMenuRow(app, row) }
        expect(app, "player-sheet-\(panel)", timeout: 10)
        // The sources sheet is the play picker, with its own header.
        if panel != "sources" { expect(app, "player-sheet-title", timeout: 5) }
        expectGone(app, "player-hud", timeout: 8)
    }

    /// Dismisses the open sheet: the sheet goes and the HUD comes back.
    private func dismiss(_ app: XCUIApplication, _ panel: String) {
        tap(app, "player-sheet-close", timeout: 5)
        expectGone(app, "player-sheet-\(panel)", timeout: 10)
        expect(app, "player-hud", timeout: 8)
    }

    private func close(_ app: XCUIApplication) {
        wakeHUD(app)
        tap(app, "player-close", timeout: 5)
        if element(app, "player-leave").waitForExistence(timeout: 3) { tap(app, "player-leave") }
        expectGone(app, "player-screen", timeout: 25)
    }

    // MARK: Tests

    /// The HUD is laid out like Infuse's, and its gear menu lists Volume Boost, Playback Speed, the audio
    /// track, the subtitle (None) and Advanced Options, which holds every panel the title gets; a film
    /// without a home server or X-Ray has no Quality or X-Ray.
    func testGearMenu() {
        let app = launch()
        pickFirst(app)
        wakeHUD(app)
        for id in ["player-close", "player-fill", "player-volume", "player-gear", "player-airplay", "player-lock"] {
            expect(app, id, timeout: 5)
        }
        tap(app, "player-gear", timeout: 5)
        for row in ["Volume Boost", "Playback Speed", "English - AC3 5.1", "None", "Advanced Options"] {
            XCTAssertTrue(menuRow(app, row).waitForExistence(timeout: 5), "the gear menu has no \(row) row")
        }
        snap("player-gear-menu")
        tapMenuRow(app, "Advanced Options")
        for row in ["Sleep Timer", "Sources", "Stats", "Speed & Sleep"] {
            XCTAssertTrue(menuRow(app, row).waitForExistence(timeout: 5), "Advanced Options has no \(row)")
        }
        XCTAssertFalse(menuRow(app, "Quality").exists, "a fixture film has no home-server copy")
        snap("player-gear-advanced")
        // Away from the menu: a tap outside closes it, and the HUD is still up.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: menuRow(app, "Sleep Timer"))
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, "the gear menu stayed up")
        expect(app, "player-hud", timeout: 5)
        close(app)
    }

    /// The gear menu's lists act at once: a speed plays, a boost reaches the engine, a track switches.
    func testGearMenuLists() {
        let app = launch()
        pickFirst(app)
        expectFixture(app, "audio 1")
        wakeHUD(app)
        tap(app, "player-gear", timeout: 5)
        tapMenuRow(app, "Playback Speed")
        tapMenuRow(app, "1.5x")
        expectFixture(app, "rate 1.5")
        wakeHUD(app)
        tap(app, "player-gear", timeout: 5)
        tapMenuRow(app, "Volume Boost")
        tapMenuRow(app, "+100%")
        expectFixture(app, "boost 100")
        wakeHUD(app)
        tap(app, "player-gear", timeout: 5)
        tapMenuRow(app, "English - AC3 5.1")
        tapMenuRow(app, "Japanese - AAC 2.0")
        expectFixture(app, "audio 2")
        wakeHUD(app)
        expectValue(app, "player-gear", "Japanese, Off")
        tap(app, "player-gear", timeout: 5)
        tapMenuRow(app, "None")
        tapMenuRow(app, "Spanish")
        expectFixture(app, "sub 4")
        wakeHUD(app)
        expectValue(app, "player-gear", "Japanese, Spanish")
        close(app)
    }

    /// Audio: the track list and sync; a pick plays at once and the sheet stays; the gear reads it.
    func testAudioPanel() {
        let app = launch()
        pickFirst(app)
        expectFixture(app, "audio 1")
        wakeHUD(app)
        expectValue(app, "player-gear", "English, Off")
        open(app, "audio")
        snap("player-audio-sheet")
        expect(app, "panel-audio-1")
        tap(app, "panel-audio-2")
        expectFixture(app, "audio 2")
        expect(app, "player-sheet-audio", timeout: 2)
        // The sync offset: +0.1 s reaches the engine.
        tap(app, "panel-audio-delay-+0.1")
        expectFixture(app, "delay 0.1/0.0")
        XCTAssertTrue(element(app, "panel-audio-delay-value").label.contains("0.10"), "the offset reads \(element(app, "panel-audio-delay-value").label)")
        dismiss(app, "audio")
        expectValue(app, "player-gear", "Japanese, Off")
        close(app)
    }

    /// Subtitles: a track plays, the delay moves, the look lane's size changes; the gear reads the track.
    func testSubtitlesPanel() {
        let app = launch()
        pickFirst(app)
        wakeHUD(app)
        expectValue(app, "player-gear", "English, Off")
        open(app, "subtitles")
        snap("player-subtitles-sheet")
        tap(app, "panel-subs-track-3")
        expectFixture(app, "sub 3")
        tap(app, "panel-subs-lane-sync")
        tap(app, "panel-subs-delay-+0.5")
        expectFixture(app, "/0.5")
        XCTAssertTrue(element(app, "panel-subs-delay-value").label.contains("0.5"), "the delay reads \(element(app, "panel-subs-delay-value").label)")
        tap(app, "panel-subs-lane-look")
        expect(app, "panel-subs-size-value")
        tap(app, "panel-subs-style-outline")
        tap(app, "panel-subs-lane-find")
        expect(app, "panel-subs-query")
        tap(app, "panel-subs-lane-tracks")
        tap(app, "panel-subs-off")
        expectFixture(app, "sub off")
        // The list is the viewer's languages (Spanish is not in it): pick English again and the gear reads it.
        tap(app, "panel-subs-track-3")
        expectFixture(app, "sub 3")
        dismiss(app, "subtitles")
        expectValue(app, "player-gear", "English, English")
        close(app)
    }

    /// Speed & Sleep (under Advanced Options): a pick sets the rate and closes the sheet; the sleep timer
    /// arms from the same sheet, Advanced Options' Sleep Timer row shows its countdown, and it cancels.
    func testSpeedAndSleepPanel() {
        let app = launch()
        pickFirst(app)
        open(app, "speed")
        snap("player-speed-sheet")
        tap(app, "panel-speed-1.5")
        expectGone(app, "player-sheet-speed", timeout: 10)
        expectFixture(app, "rate 1.5")

        open(app, "speed")
        tap(app, "panel-sleep-0")
        expect(app, "panel-sleep-cancel", timeout: 5)
        expect(app, "player-sheet-speed", timeout: 2)
        dismiss(app, "speed")
        // The countdown is on the gear menu's Sleep Timer row.
        tap(app, "player-gear", timeout: 5)
        tapMenuRow(app, "Advanced Options")
        let sleepRow = menuRow(app, "Sleep Timer")
        XCTAssertTrue(sleepRow.waitForExistence(timeout: 5), "no Sleep Timer row")
        XCTAssertNotNil(sleepRow.label.range(of: #"\d+:\d\d"#, options: .regularExpression), "the row reads \(sleepRow.label)")
        snap("player-sleep-armed")
        sleepRow.tap()
        tapMenuRow(app, "Cancel Timer")

        open(app, "speed")
        expectGone(app, "panel-sleep-cancel", timeout: 5)
        tap(app, "panel-speed-1")
        expectGone(app, "player-sheet-speed", timeout: 10)
        expectFixture(app, "rate 1 ")
        close(app)
    }

    /// Stats: the engine and the source host; the full URL is not shown.
    func testStatsPanel() {
        let app = launch()
        pickFirst(app)
        open(app, "stats")
        snap("player-stats-sheet")
        expect(app, "panel-stats-row-0")
        expect(app, "panel-stats-row-1")
        dismiss(app, "stats")
        close(app)
    }

    /// Sources: the picker's list in a sheet; a pick swaps the stream and the player is on the same spot.
    func testSourcesPanelKeepsThePosition() {
        let app = launch(["--fixture-resume", "1800"])
        pickFirst(app)
        expectPosition(app, "at the saved spot") { $0 >= 1795 }
        open(app, "sources")
        snap("player-sources-sheet")
        expect(app, "stream-1", timeout: 30)
        tap(app, "stream-1")
        expectGone(app, "player-sheet-sources", timeout: 20)
        expect(app, "player-screen", timeout: 5)
        // The new stream opens on the spot (the stand-in plays from 0 for 1.5 s before its seek lands).
        expectPosition(app, "still at the spot after the switch", timeout: 25) { $0 >= 1795 }
        close(app)
    }

    /// Lock: the HUD and the picture ignore touches until Unlock; the film keeps playing.
    func testLockControls() {
        let app = launch()
        pickFirst(app)
        wakeHUD(app)
        tap(app, "player-lock", timeout: 5)
        expectGone(app, "player-hud", timeout: 8)
        expect(app, "player-lock-layer", timeout: 5)
        snap("player-locked")
        let before = position(app) ?? 0
        // A touch on the picture does not bring the HUD back, nor pause; the Unlock button comes up.
        expect(app, "player-lock-layer").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expect(app, "player-unlock", timeout: 5)
        XCTAssertFalse(element(app, "player-hud").exists, "the HUD came up on a locked player")
        sleep(2)
        XCTAssertGreaterThan(position(app) ?? 0, before, "the film stopped while locked: \"\(fixtureText(app))\"")
        snap("player-unlock-button")
        tap(app, "player-unlock")
        expectGone(app, "player-lock-layer", timeout: 5)
        expect(app, "player-hud", timeout: 8)
        // Unlocked, the controls answer again.
        tap(app, "player-playpause")
        close(app)
    }
}
