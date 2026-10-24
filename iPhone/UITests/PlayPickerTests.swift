import XCTest

/// The play picker on its own (`--fixtures detail --fixture-streams --phone-picker`): the shell opens
/// PhonePlayPicker on a fixture film and StreamsModel answers from App/Shared/Streams/StreamsFixtures.swift
/// (seven streams from three addons: two 4K, three 1080p, two 720p, four cached; the 720p MediaFusion
/// row fails to resolve). Nothing here touches the network. A pick closes the picker and opens the
/// player cover on its fixture engine (PlayerTests covers the player itself). The English UI is assumed.
final class PlayPickerTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch(_ extra: [String] = [], streams: [String] = []) -> XCUIApplication {
        launchHarbor(["--fixtures", "detail", "--fixture-streams"] + streams + ["--phone-picker"] + extra)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        // The screen, not the app: a busy app cannot time it out. A screenshot the runner cannot
        // deliver in time is evidence lost, not a failed test.
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

    private func expectGone(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let gone = NSPredicate(format: "exists == false")
        let wait = XCTNSPredicateExpectation(predicate: gone, object: element(app, id))
        if XCTWaiter.wait(for: [wait], timeout: timeout) != .completed {
            snap(app, "still-\(id)")
            XCTFail("\(id) is still on screen", file: file, line: line)
        }
    }

    /// The player cover a pick opened, closed again from its HUD (Close, then Leave when asked).
    private func closePlayer(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        expect(app, "player-screen", timeout: 30, file: file, line: line)
        if !element(app, "player-hud").exists { element(app, "player-stage").tap() }
        tap(app, "player-close", timeout: 5, file: file, line: line)
        if element(app, "player-leave").waitForExistence(timeout: 3) { tap(app, "player-leave", file: file, line: line) }
        expectGone(app, "player-screen", timeout: 25, file: file, line: line)
    }

    /// The counts line under the chips ("2 of 7 sources") reads `text` within the timeout.
    private func expectSources(_ app: XCUIApplication, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let counts = expect(app, "picker-sources", file: file, line: line)
        let reads = NSPredicate(format: "label CONTAINS %@", text)
        let wait = XCTNSPredicateExpectation(predicate: reads, object: counts)
        if XCTWaiter.wait(for: [wait], timeout: 15) != .completed {
            snap(app, "sources-\(text)")
            XCTFail("the sources line reads \"\(counts.label)\", not \"\(text)\"", file: file, line: line)
        }
    }

    /// The picker is up with the fixture list in.
    private func openPicker(_ app: XCUIApplication) {
        expect(app, "phone-picker", timeout: 40)
        expect(app, "stream-0", timeout: 30)
        expectSources(app, "7 of 7 sources")
    }

    // MARK: Tests

    /// The sheet comes up on the list: addon sections, quality chips with counts, the first row.
    func testPickerOpens() {
        let app = launch()
        openPicker(app)
        expect(app, "section-Torrentio")
        expect(app, "chip-All 7")
        expect(app, "chip-4K UHD 2")
        expect(app, "chip-1080p 3")
        expect(app, "chip-Cached 4")
        expect(app, "picker-close")
        snap(app, "picker-medium")
        // Pulled up to full height, more of the list shows. A drag on the list scrolls it (the sheet's
        // content interaction is .scrolls), so the grabber raises the sheet.
        let grabber = app.buttons["Sheet Grabber"]
        if grabber.waitForExistence(timeout: 5) {
            grabber.tap()
        } else {
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.483))
            top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
        }
        // The shot once the sheet has come to rest at full height.
        waitForSteadyFrame(expect(app, "picker-close"))
        snap(app, "picker-large")
    }

    /// A quality chip narrows the list to its streams and the counts line follows; All brings
    /// everything back; Cached keeps the cached ones.
    func testChipsNarrowTheList() {
        let app = launch()
        openPicker(app)
        tap(app, "chip-4K UHD 2")
        expectSources(app, "2 of 7 sources")
        expect(app, "stream-0")
        expect(app, "stream-1")
        expectGone(app, "stream-2")
        expect(app, "chip-Clear filters")
        snap(app, "picker-4k")
        tap(app, "chip-All 7")
        expectSources(app, "7 of 7 sources")
        tap(app, "chip-Cached 4")
        expectSources(app, "4 of 4 sources")
        snap(app, "picker-cached")
        tap(app, "chip-Clear filters")
        expectSources(app, "7 of 7 sources")
    }

    /// A row is a button VoiceOver and a tap reach; the pick closes the picker and opens the player
    /// on the title, and Close comes back.
    func testRowOpensThePlayer() {
        let app = launch()
        openPicker(app)
        let row = expect(app, "stream-0")
        XCTAssertTrue(row.isHittable, "the first row cannot be tapped")
        XCTAssertTrue(row.label.contains("Torrentio"), "the row's label does not name its addon: \(row.label)")
        row.tap()
        expect(app, "player-screen", timeout: 30)
        expectGone(app, "phone-picker")
        if !element(app, "player-hud").exists { element(app, "player-stage").tap() }
        let title = expect(app, "player-title", timeout: 5)
        XCTAssertTrue(title.label.contains("Dune"), "the player plays \(title.label)")
        snap(app, "player")
        closePlayer(app)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "no tab bar after the player closed")
    }

    /// A row whose link cannot be had says so on the row, and the list stays.
    func testUnavailableRow() {
        let app = launch()
        openPicker(app)
        tap(app, "chip-720p 2")
        expectSources(app, "2 of 7 sources")
        // At medium height the row sits half under the sheet's edge, where its accessibility label
        // can lag the screen: the sheet goes to full height first.
        let grabber = app.buttons["Sheet Grabber"]
        if grabber.waitForExistence(timeout: 5) { grabber.tap() }
        let row = expect(app, "stream-5")
        row.tap()
        // The mark is its own element, or (folded into the row's one VoiceOver element) in its label.
        let marked = NSPredicate { _, _ in
            self.element(app, "stream-failed-5").exists || row.label.contains("Unavailable")
        }
        let wait = XCTNSPredicateExpectation(predicate: marked, object: nil)
        if XCTWaiter.wait(for: [wait], timeout: 20) != .completed {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "hierarchy-unmarked-stream-5"
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("stream-5 is not marked unavailable: \(row.label)")
        }
        snap(app, "picker-unavailable")
    }

    /// With subtitle preselect on, the subtitle step stands between the pick and the player; the
    /// chosen track is handed over (the fixture engine's label names it).
    func testSubtitleStep() {
        let app = launch(["--phone-picker-subtitles"])
        openPicker(app)
        tap(app, "stream-0")
        expect(app, "subtitle-title")
        expect(app, "track-off")
        expect(app, "track-fx-sub-en")
        snap(app, "subtitle-step")
        tap(app, "chip-All languages 3")
        tap(app, "track-fx-sub-es")
        tap(app, "subtitle-start")
        expect(app, "player-screen", timeout: 30)
        let engine = expect(app, "player-fixture", timeout: 10)
        let named = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Español"), object: engine)
        if XCTWaiter.wait(for: [named], timeout: 5) != .completed {
            XCTFail("the player was not handed the chosen subtitles: \(engine.label)")
        }
        snap(app, "player-subtitles")
        closePlayer(app)
    }

    /// Instant play: the auto step tries the best cached source and plays it.
    func testAutoStepPlays() {
        let app = launch(["--phone-picker-auto"])
        // The fixture resolves quickly: the picker can be gone and the player up by the first look.
        let player = element(app, "player-screen")
        if firstToExist([element(app, "phone-picker"), player], timeout: 40) == nil {
            XCTFail("neither the picker nor the player came up")
        }
        let caption = element(app, "auto-caption")
        if firstToExist([caption, player], timeout: 30) == caption { snap(app, "auto-step") }
        closePlayer(app)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "no tab bar after the player closed")
    }

    /// No stream at all: the empty state, with the loosen ladder.
    func testEmptyList() {
        let app = launch(streams: ["empty"])
        expect(app, "phone-picker", timeout: 40)
        expect(app, "empty-state", timeout: 30)
        expectSources(app, "0 of 0 sources")
        // The search is done once the empty state shows: no row may stand next to it.
        XCTAssertFalse(element(app, "stream-0").exists, "a stream row shows with the empty state")
        snap(app, "picker-empty")
    }
}
