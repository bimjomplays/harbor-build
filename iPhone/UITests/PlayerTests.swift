import XCTest

/// The phone player on fixtures: `--fixtures detail --fixture-streams --phone-picker`
/// opens the play picker on a fixture film, and a pick opens the player cover. The fixture links point
/// nowhere, so the player draws its stand-in engine (PhoneFixturePlayer): a silent two-hour "file" whose
/// start seek lands 1.5 s after it starts playing from 0, the window in which an early save used to
/// write 0:00 over the saved spot. `--fixture-resume 1800` is the saved spot (30:00). The
/// stand-in's label (`player-fixture`) reads "fixture <position> / 2:00:00 · fit|fill · saved <first
/// save of the launch | none>". Under fixtures the HUD holds 30 s after the last touch (a CI simulator
/// can take longer than 3 s between two queries); `--fixture-hud-after 3` restores the real hold for
/// the fade check. The English UI is assumed.
final class PlayerTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        // The cover locks the app to landscape; the next test starts upright.
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: Helpers

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        launchHarbor(["--fixtures", "detail", "--fixture-streams", "--phone-picker"] + extra)
    }

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
            snap(app, "missing-\(id)")
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
            snap(app, "still-\(id)")
            XCTFail("\(id) is still on screen", file: file, line: line)
        }
    }

    /// "1:02:03" / "30:00" as seconds.
    private func seconds(_ clock: String) -> Double? {
        let parts = clock.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    /// What the stand-in engine's label says: where it is, and the launch's first progress save.
    private func fixture(_ app: XCUIApplication) -> (position: Double?, saved: Double?, text: String) {
        let label = element(app, "player-fixture")
        guard label.exists else { return (nil, nil, "") }
        let text = label.label
        let fields = text.components(separatedBy: " · ")
        var position: Double?
        if let head = fields.first, head.hasPrefix("fixture ") {
            position = seconds(String(head.dropFirst("fixture ".count).split(separator: " ").first ?? ""))
        }
        var saved: Double?
        if let last = fields.last, last.hasPrefix("saved ") { saved = Double(last.dropFirst("saved ".count)) }
        return (position, saved, text)
    }

    /// Waits until the stand-in reports a position that `ok` accepts, and fails with what it said.
    private func expectPosition(_ app: XCUIApplication, _ what: String, timeout: TimeInterval = 15,
                                file: StaticString = #filePath, line: UInt = #line, _ ok: @escaping (Double) -> Bool) {
        let reads = NSPredicate { _, _ in self.fixture(app).position.map(ok) ?? false }
        if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: reads, object: nil)], timeout: timeout) != .completed {
            snap(app, "position-\(what)")
            XCTFail("the player is not \(what): \"\(fixture(app).text)\"", file: file, line: line)
        }
    }

    /// No save so far, or one at the saved spot: never the file's first frames over it.
    private func expectNoEarlySave(_ app: XCUIApplication, required: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        if required {
            let saved = NSPredicate { _, _ in self.fixture(app).saved != nil }
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: nil)], timeout: 10)
        }
        let f = fixture(app)
        if let saved = f.saved {
            XCTAssertGreaterThanOrEqual(saved, 1790, "an early position was saved over the saved spot: \"\(f.text)\"", file: file, line: line)
        } else {
            XCTAssertFalse(required, "no progress was saved: \"\(f.text)\"", file: file, line: line)
        }
    }

    /// The picker's first row opens the player.
    private func pickFirst(_ app: XCUIApplication) {
        expect(app, "phone-picker", timeout: 40)
        tap(app, "stream-0", timeout: 30)
        expect(app, "player-screen", timeout: 20)
        expect(app, "player-fixture", timeout: 10)
    }

    /// The resume fork, when settings ask for it (resumePrompt), picks up where the viewer left off.
    private func pickUpIfAsked(_ app: XCUIApplication) {
        if element(app, "player-resume").waitForExistence(timeout: 2) {
            snap(app, "player-resume")
            tap(app, "player-resume")
        }
    }

    /// A tap on the bare picture between the HUD's top bar and its transport (the stage's centre is
    /// under Play / Pause while the HUD is up).
    private func tapPicture(_ app: XCUIApplication) {
        expect(app, "player-stage").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
    }

    /// The HUD up: a tap on the picture brings it back when it has faded.
    private func wakeHUD(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        if !element(app, "player-hud").exists { tapPicture(app) }
        expect(app, "player-hud", timeout: 5, file: file, line: line)
    }

    /// Close on the HUD and, when asked (playerConfirmLeave), Leave.
    private func close(_ app: XCUIApplication) {
        wakeHUD(app)
        tap(app, "player-close", timeout: 5)
        if element(app, "player-leave").waitForExistence(timeout: 3) {
            snap(app, "player-leave")
            tap(app, "player-leave")
        }
        // The cover's dismissal and the turn back to portrait took over 10 s on a loaded runner
        // (run 39253711297: Home on screen, no player in the tree, just past the wait).
        expectGone(app, "player-screen", timeout: 25)
    }

    // MARK: Tests

    /// A pick opens the cover on the HUD (title, Close, transport, scrubber); a tap on the picture
    /// hides it and the next brings it back; Close returns to the app.
    func testPickOpensThePlayer() {
        let app = launch()
        expect(app, "phone-picker", timeout: 40)
        tap(app, "stream-0", timeout: 30)
        // The cover opens with the HUD up.
        expect(app, "player-screen", timeout: 20)
        expect(app, "player-hud", timeout: 5)
        snap(app, "player-open")
        let title = expect(app, "player-title")
        XCTAssertTrue(title.label.contains("Dune"), "the HUD's title reads \(title.label)")
        expect(app, "player-close")
        expect(app, "player-back")
        expect(app, "player-playpause")
        expect(app, "player-ahead")
        expect(app, "player-scrubber")
        expect(app, "player-elapsed")
        expect(app, "player-remaining")
        snap(app, "player-hud")
        // A tap on the picture toggles the HUD.
        tapPicture(app)
        expectGone(app, "player-hud", timeout: 8)
        snap(app, "player-bare")
        tapPicture(app)
        expect(app, "player-hud", timeout: 5)
        close(app)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "no tab bar after the player closed")
    }

    /// The engine-switch offer's button: by id, or by its words when the system dialog drops the id.
    private func switchButton(_ app: XCUIApplication, _ words: String) -> XCUIElement {
        let byId = element(app, "player-switch-engine")
        if byId.waitForExistence(timeout: 8) { return byId }
        dumpTree(app, "missing-switch-engine")
        snap(app, "missing-switch-engine")
        return app.buttons[words]
    }

    /// P8c, AVPlayer engine: the HUD carries Picture in Picture and AirPlay; PiP floats the picture
    /// (the stand-in's flag; AVKit's window needs a device), the player steps aside so Harbor can be
    /// browsed, and the tab bar's accessory brings the picture back.
    func testPictureInPictureOnTheAVPlayerEngine() throws {
        guard #available(iOS 26.1, *) else { throw XCTSkip("the bottom accessory is an iOS 26.1 API") }
        let app = launch(["--fixture-engine", "native"])
        pickFirst(app)
        pickUpIfAsked(app)
        wakeHUD(app)
        expect(app, "player-pip", timeout: 5)
        expect(app, "player-airplay", timeout: 5)
        snap(app, "player-hud-pip-airplay")
        floatAndBringBack(app)
        expect(app, "player-hud", timeout: 8)
        close(app)
    }

    /// Picture in Picture on: the player is gone from sight and the shell shows the live state in the
    /// accessory; its tap exits Picture in Picture and the player is back.
    private func floatAndBringBack(_ app: XCUIApplication) {
        tap(app, "player-pip", timeout: 5)
        expect(app, "mini-accessory", timeout: 15)
        expectGone(app, "player-screen", timeout: 8)
        // Nothing covers the shell: its tab bar takes touches.
        XCTAssertTrue(app.tabBars.firstMatch.isHittable, "the player still covers the shell while the picture floats")
        snap(app, "player-pip-mini-accessory")
        tap(app, "mini-accessory", timeout: 5)
        expectGone(app, "mini-accessory", timeout: 8)
        expect(app, "player-screen", timeout: 8)
    }

    /// P8c, mpv: it cannot float, so the PiP button says so and offers the AVPlayer engine; taking
    /// the offer carries on from the same spot on AVPlayer, where the button then floats the picture.
    func testPictureInPictureOffersTheAVPlayerEngineOnMpv() throws {
        guard #available(iOS 26.1, *) else { throw XCTSkip("the bottom accessory is an iOS 26.1 API") }
        let app = launch(["--fixture-engine", "mpv"])
        pickFirst(app)
        pickUpIfAsked(app)
        wakeHUD(app)
        tap(app, "player-pip", timeout: 5)
        snap(app, "player-pip-offer")
        switchButton(app, "Switch to the AVPlayer engine").tap()
        expect(app, "player-fixture", timeout: 20)
        pickUpIfAsked(app)
        wakeHUD(app)
        floatAndBringBack(app)
        close(app)
    }

    /// P8c, mpv: AirPlay offers "Switch to AirPlay-capable engine".
    func testAirPlayOffersTheAVPlayerEngineOnMpv() {
        let app = launch(["--fixture-engine", "mpv"])
        pickFirst(app)
        pickUpIfAsked(app)
        wakeHUD(app)
        tap(app, "player-airplay", timeout: 5)
        snap(app, "player-airplay-offer")
        switchButton(app, "Switch to AirPlay-capable engine").tap()
        expect(app, "player-fixture", timeout: 20)
        close(app)
    }

    /// Nothing touched, the HUD fades after the real hold (3 s, PhonePlayerHUD.hideAfter).
    func testHUDFades() {
        let app = launch(["--fixture-hud-after", "3"])
        pickFirst(app)
        pickUpIfAsked(app)
        expectGone(app, "player-hud", timeout: 15)
        snap(app, "player-faded")
        // The stage is still there to bring it back (PlayerTests' other cases tap it on a longer hold).
        expect(app, "player-stage")
    }

    /// Play / pause and the ± steps (the player prefs' 10 s) move the stand-in engine.
    func testTransport() {
        let app = launch(["--fixture-resume", "1800"])
        pickFirst(app)
        pickUpIfAsked(app)
        expectPosition(app, "at the saved spot") { $0 >= 1795 }
        wakeHUD(app)
        tap(app, "player-playpause")
        sleep(1)
        let paused = fixture(app).position ?? 0
        sleep(2)
        XCTAssertEqual(fixture(app).position ?? -1, paused, accuracy: 1.01, "the player kept going after Pause: \"\(fixture(app).text)\"")
        // Paused, the HUD stays up.
        expect(app, "player-hud", timeout: 1)
        tap(app, "player-back")
        expectPosition(app, "10 s back") { abs($0 - (paused - 10)) <= 1.5 }
        tap(app, "player-ahead")
        tap(app, "player-ahead")
        expectPosition(app, "10 s ahead") { abs($0 - (paused + 10)) <= 1.5 }
        snap(app, "player-paused")
        close(app)
    }

    /// #656's acceptance on the phone: the player opens on the saved spot (30:00), the save never
    /// writes the file's first frames over it, and the spot holds over a trip to the background.
    func testResumeStartsAtTheSavedSpot() {
        let app = launch(["--fixture-resume", "1800"])
        pickFirst(app)
        pickUpIfAsked(app)
        // The stand-in plays from 0 for 1.5 s before its start seek lands: no save in that window.
        expectNoEarlySave(app)
        expectPosition(app, "at the saved spot", timeout: 15) { $0 >= 1795 && $0 <= 1900 }
        wakeHUD(app)
        let elapsed = expect(app, "player-elapsed", timeout: 5)
        let shown = seconds(elapsed.label) ?? 0
        XCTAssertTrue(shown >= 1795 && shown <= 1900, "the HUD reads \(elapsed.label), not about 30:00")
        snap(app, "player-resumed")
        expectNoEarlySave(app)

        // Home and back: the background flushes a save, which must be the spot reached, and the
        // player comes back on it.
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "the app did not come back")
        expect(app, "player-screen", timeout: 10)
        expectPosition(app, "back on the saved spot") { $0 >= 1795 }
        expectNoEarlySave(app, required: true)
        snap(app, "player-foreground")
        close(app)
    }

    /// A pinch out fills the screen with the picture, a pinch in fits it again.
    func testPinchFillsAndFits() {
        let app = launch()
        pickFirst(app)
        pickUpIfAsked(app)
        // On the bare picture: the HUD's transport sits where the pinch lands. A tap hides it.
        let stage = expect(app, "player-stage")
        if element(app, "player-hud").exists { tapPicture(app) }
        expectGone(app, "player-hud", timeout: 8)
        stage.pinch(withScale: 2, velocity: 2)
        let filled = NSPredicate { _, _ in self.fixture(app).text.contains(" · fill") }
        if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: filled, object: nil)], timeout: 5) != .completed {
            XCTFail("a pinch out did not fill the screen: \"\(fixture(app).text)\"")
        }
        stage.pinch(withScale: 0.5, velocity: -2)
        let fitted = NSPredicate { _, _ in self.fixture(app).text.contains(" · fit") }
        if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: fitted, object: nil)], timeout: 5) != .completed {
            XCTFail("a pinch in did not fit the picture again: \"\(fixture(app).text)\"")
        }
        close(app)
    }
}
