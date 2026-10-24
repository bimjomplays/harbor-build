import XCTest

/// The phone player's panel sheets and lock on fixtures: `--fixtures detail
/// --fixture-streams --phone-picker` opens the play picker on a fixture film and a pick opens the player
/// over its stand-in engine (PhoneFixturePlayer). The stand-in has two audio tracks (1 English, 2 Japanese)
/// and two subtitle tracks (3 English, 4 Spanish), and its label (`player-fixture`) reads "fixture <pos> /
/// 2:00:00 · fit|fill · audio <id|off> · sub <id|off> · rate <n> · delay <audio>/<sub> · … · saved …", so
/// a change a sheet makes is read back from the engine, and the HUD's buttons read it back from the
/// session. Under fixtures the HUD holds 30 s after the last touch. The English UI is assumed.
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

    /// Opens a panel from the HUD: its sheet comes up and the HUD goes behind it.
    private func open(_ app: XCUIApplication, _ panel: String) {
        wakeHUD(app)
        tap(app, "player-panel-\(panel)", timeout: 5)
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

    /// The HUD has a button for each panel the title gets; a film without a home server or X-Ray has
    /// no Quality or X-Ray.
    func testPanelButtons() {
        let app = launch()
        pickFirst(app)
        wakeHUD(app)
        for panel in ["subtitles", "audio", "speed", "sources", "stats"] {
            expect(app, "player-panel-\(panel)", timeout: 5)
        }
        expect(app, "player-lock", timeout: 5)
        XCTAssertFalse(element(app, "player-panel-quality").exists, "a fixture film has no home-server copy")
        snap("player-panel-buttons")
        close(app)
    }

    /// Audio: the track list and sync; a pick plays at once and the sheet stays; the HUD button reads it.
    func testAudioPanel() {
        let app = launch()
        pickFirst(app)
        expectFixture(app, "audio 1")
        wakeHUD(app)
        expectValue(app, "player-panel-audio", "English")
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
        expectValue(app, "player-panel-audio", "Japanese")
        close(app)
    }

    /// Subtitles: a track plays, the delay moves, the look lane's size changes; the HUD button reads the track.
    func testSubtitlesPanel() {
        let app = launch()
        pickFirst(app)
        wakeHUD(app)
        expectValue(app, "player-panel-subtitles", "Off")
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
        // The list is the viewer's languages (Spanish is not in it): pick English again and the button reads it.
        tap(app, "panel-subs-track-3")
        expectFixture(app, "sub 3")
        dismiss(app, "subtitles")
        expectValue(app, "player-panel-subtitles", "English")
        close(app)
    }

    /// Speed: a pick sets the rate and closes the sheet, and the button's face shows it; the sleep timer
    /// arms from the same sheet and its countdown is on the button; it cancels.
    func testSpeedAndSleepPanel() {
        let app = launch()
        pickFirst(app)
        open(app, "speed")
        snap("player-speed-sheet")
        tap(app, "panel-speed-1.5")
        expectGone(app, "player-sheet-speed", timeout: 10)
        expectFixture(app, "rate 1.5")
        wakeHUD(app)
        XCTAssertEqual(element(app, "player-panel-speed-face").label, "1.5×")

        open(app, "speed")
        tap(app, "panel-sleep-0")
        expect(app, "panel-sleep-cancel", timeout: 5)
        expect(app, "player-sheet-speed", timeout: 2)
        dismiss(app, "speed")
        // The countdown replaces the rate on the face: "29:5x" / "30:00".
        let face = expect(app, "player-panel-speed-face", timeout: 5)
        XCTAssertNotNil(face.label.range(of: #"^\d+:\d\d$"#, options: .regularExpression), "the face reads \(face.label)")
        snap("player-sleep-armed")

        open(app, "speed")
        tap(app, "panel-sleep-cancel")
        expectGone(app, "panel-sleep-cancel", timeout: 5)
        tap(app, "panel-speed-1")
        expectGone(app, "player-sheet-speed", timeout: 10)
        expectFixture(app, "rate 1 ")
        wakeHUD(app)
        expectGone(app, "player-panel-speed-face", timeout: 5)
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
