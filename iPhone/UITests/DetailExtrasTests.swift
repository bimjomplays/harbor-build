import XCTest

/// The title page's extras on the detail fixtures (`--fixtures detail`), opened on Dune: Part Two by
/// its harbor://detail link: PhoneDetailFixtures gives every title TMDB's extras offline (cast, facts,
/// a trailer, a video), the Oscars and a gallery of numbered plates. The trailer sheet, the gallery
/// lightbox, the facts, awards, rate and tracker sheets, Play through the picker to the player, and
/// a cast member's person page. Every step attaches a screenshot.
///
/// The English UI is assumed: a menu item is looked up by its English label when its identifier
/// does not reach the accessibility tree.
final class DetailExtrasTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        launchHarbor(["--fixtures", "detail", "--fixture-streams", "--phone-open", "harbor://detail/series/s-0"] + arguments)
    }

    /// The deep link's title page, named.
    private func openDune(_ app: XCUIApplication) {
        expect(app, "detail-sheet", timeout: 40)
        expect(app, "detail-page")
        XCTAssertEqual(expect(app, "detail-name").label, "Dune: Part Two")
    }

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

    private func labelled(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
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

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        if XCTWaiter().wait(for: [match], timeout: timeout) != .completed {
            XCTFail("label is \"\(element.label)\", not \"\(label)\"", file: file, line: line)
        }
    }

    /// Drags the page up by `fraction` of the screen, from below the backdrop so no tap lands.
    private func scrollPage(_ app: XCUIApplication, by fraction: CGFloat = 0.35) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7 - fraction))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Scrolls the page until the element sits in the upper part of the screen. The extras sit under
    /// the episodes, so the page may need many drags; a lazy rail only exists once it is near.
    @discardableResult
    private func bringUp(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(app, id)
        let height = app.frame.height
        var drags = 0
        while drags < 16 {
            if target.exists, target.isHittable {
                let over = target.frame.midY - height * 0.45
                if over <= height * 0.1 { break }
                // In view but low: a slow drag held at its end lifts it by just that much. A page drag
                // flings a chip at 60% past the top (run 39267462375).
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -over)),
                            withVelocity: .slow, thenHoldForDuration: 0.3)
            } else {
                scrollPage(app)
            }
            drags += 1
        }
        expect(app, id, timeout: 10, file: file, line: line)
        XCTAssertTrue(target.isHittable, "\(id) never came into view", file: file, line: line)
        return target
    }

    // MARK: Tests

    /// The bar's Trailer opens the trailer sheet with the embedded player; Done closes it. A Videos
    /// card opens the same sheet named after its clip.
    func testTrailerSheetOpensAndCloses() throws {
        let app = launch()
        openDune(app)
        tap(app, "detail-trailer", timeout: 30)
        expect(app, "trailer-player")
        XCTAssertEqual(expect(app, "trailer-title").label, "Dune: Part Two")
        expect(app, "trailer-youtube")
        // The player page loads over the network: a moment for the frame (or its error) to draw.
        sleep(3)
        snap(app, "trailer-sheet")
        tap(app, "trailer-done")
        XCTAssertTrue(gone(app, "trailer-player"), "the trailer sheet did not close")
        expect(app, "detail-page")

        bringUp(app, "video-0").tap()
        expect(app, "trailer-player")
        XCTAssertTrue(labelled(app, "Official Trailer 3").waitForExistence(timeout: 10), "the sheet does not name the clip")
        snap(app, "trailer-sheet-video")
        tap(app, "trailer-done")
        XCTAssertTrue(gone(app, "trailer-player"), "the trailer sheet did not close")
    }

    /// A gallery tile opens the full-screen lightbox on that picture; a swipe moves to the next;
    /// Close goes back to the page.
    func testGalleryLightboxOpens() throws {
        let app = launch()
        openDune(app)
        bringUp(app, "gallery-backdrop-0")
        snap(app, "gallery-rail")
        element(app, "gallery-backdrop-0").tap()
        expect(app, "lightbox-close")
        let count = expect(app, "lightbox-count")
        waitForLabel(count, "1 / 5")
        snap(app, "gallery-lightbox")
        app.swipeLeft()
        waitForLabel(count, "2 / 5")
        snap(app, "gallery-lightbox-2")
        let close = expect(app, "lightbox-close")
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: close)
        XCTAssertEqual(XCTWaiter().wait(for: [hittable], timeout: 10), .completed, "Close is not hittable")
        close.tap()
        if !gone(app, "lightbox-close") {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "hierarchy-lightbox-still-up"
            tree.lifetime = .keepAlways
            add(tree)
            snap(app, "lightbox-still-up")
            // "closing" when Close's action ran and the viewer still stayed.
            XCTFail("the lightbox did not close (Close's value: \(String(describing: close.value)))")
        }
        expect(app, "detail-page")
        snap(app, "gallery-closed")
    }

    /// The Details chip opens the facts sheet; an awards body opens its wins and nominations.
    func testFactsAndAwardsSheets() throws {
        let app = launch()
        openDune(app)
        bringUp(app, "chip-Details").tap()
        XCTAssertEqual(expect(app, "facts-title").label, "Dune: Part Two")
        let first = expect(app, "fact-0")
        XCTAssertTrue(first.label.contains("Released"), "the first fact reads \(first.label)")
        snap(app, "facts-sheet")
        tap(app, "facts-sheet-done")
        XCTAssertTrue(gone(app, "facts-title"), "the facts sheet did not close")

        bringUp(app, "detail-award-oscar").tap()
        expect(app, "awards-won")
        expect(app, "awards-nominated")
        XCTAssertTrue(labelled(app, "The Oscars").waitForExistence(timeout: 10), "the awards sheet is not titled")
        snap(app, "awards-sheet")
        tap(app, "awards-sheet-done")
        XCTAssertTrue(gone(app, "awards-won"), "the awards sheet did not close")
    }

    /// Rate opens the 1–10 sheet; More → Trackers opens the tracker sign-ins.
    func testRateAndTrackersSheets() throws {
        let app = launch()
        openDune(app)
        tap(app, "detail-rate", timeout: 30)
        expect(app, "rate-1")
        expect(app, "rate-10")
        snap(app, "rate-sheet")
        tap(app, "rate-sheet-done")
        XCTAssertTrue(gone(app, "rate-10"), "the rate sheet did not close")

        tap(app, "detail-more")
        let byId = element(app, "more-trackers")
        let item = byId.waitForExistence(timeout: 5) ? byId : app.buttons["Trackers"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "no Trackers in the More menu")
        snap(app, "detail-more-menu")
        item.tap()
        expect(app, "tracker-trakt-primary", timeout: 30)
        expect(app, "tracker-anilist-primary")
        snap(app, "trackers-sheet")
        tap(app, "trackers-sheet-done")
        XCTAssertTrue(gone(app, "tracker-trakt-primary"), "the trackers sheet did not close")
    }

    /// Play opens the play picker and its pick opens the player: instant play's own pick (the
    /// default), or the first row when nothing is picked for the viewer. Close comes back to the page.
    func testPlayReachesThePlayer() throws {
        let app = launch()
        openDune(app)
        tap(app, "detail-play", timeout: 30)
        let player = element(app, "player-screen")
        // A quick fixture: the picker can be gone and the player up by the first look.
        let up = NSPredicate { _, _ in self.element(app, "phone-picker").exists || player.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: up, object: nil)], timeout: 40), .completed,
                       "Play opened neither the picker nor the player")
        let row = element(app, "stream-0")
        let auto = element(app, "auto-caption")
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline && !player.exists {
            // The list with no auto step over it, and no player coming: the first row plays.
            if row.exists && !auto.exists {
                sleep(2)
                if !player.exists && !auto.exists && row.exists {
                    snap(app, "play-picker-list")
                    row.tap()
                    break
                }
                continue
            }
            sleep(1)
        }
        expect(app, "player-screen", timeout: 30)
        snap(app, "play-player")
        // The HUD fades; a tap on the picture brings it back.
        if !element(app, "player-hud").exists { element(app, "player-stage").tap() }
        let name = expect(app, "player-title", timeout: 5)
        XCTAssertTrue(name.label.contains("Dune"), "the player plays \(name.label), not Dune: Part Two")
        tap(app, "player-close", timeout: 5)
        if element(app, "player-leave").waitForExistence(timeout: 3) { tap(app, "player-leave") }
        XCTAssertTrue(gone(app, "player-screen"), "the player did not close")
        expect(app, "detail-page", timeout: 10)
    }

    /// A cast card opens that person's page.
    func testCastOpensPersonPage() throws {
        let app = launch()
        openDune(app)
        bringUp(app, "cast-1190668")
        snap(app, "detail-cast")
        element(app, "cast-1190668").tap()
        expect(app, "person-page", timeout: 30)
        waitForLabel(expect(app, "person-name"), "Timothée Chalamet")
        snap(app, "person-page-from-cast")
    }
}
