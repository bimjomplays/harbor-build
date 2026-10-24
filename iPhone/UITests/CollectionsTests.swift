import XCTest

/// Library → Collections on the fixture rooms (`--fixtures shell --phone-collections`): three of the
/// viewer's own collections, made through the real engine at launch in a known order (Weekend Movies,
/// Sci-Fi Favourites, Comfort Shows). A collection is opened and its titles dragged into a new order in
/// edit mode; the collections are dragged into a new order, one is renamed, and one is deleted. The
/// room is then left and opened again, so what shows is read back from the engine. Every step attaches
/// a screenshot. TMDB and TVDB are not read offline, so nothing here touches the network.
///
/// The English UI is assumed: alert and dialog buttons are looked up by their English labels.
final class CollectionsTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch() -> XCUIApplication {
        let app = launchHarbor(["--fixtures", "shell", "--phone-collections"])
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "no tab bar")
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        // The screen, not the app (as HomeEditTests): a busy app cannot time the screenshot out.
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

    private func tree(_ app: XCUIApplication, _ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "hierarchy-\(name)"
        tree.lifetime = .keepAlways
        add(tree)
    }

    /// By identifier, inside `root` when given (a collection page's tiles share their ids with Home's).
    private func element(_ app: XCUIApplication, _ id: String, in root: XCUIElement? = nil) -> XCUIElement {
        (root ?? app).descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @discardableResult
    private func expect(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let found = element(app, id)
        if !found.waitForExistence(timeout: timeout) {
            tree(app, "missing-\(id)")
            snap(app, "missing-\(id)")
            XCTFail("no element \(id)", file: file, line: line)
        }
        return found
    }

    private func tap(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        expect(app, id, timeout: timeout, file: file, line: line).tap()
    }

    /// A button by identifier, or by its label where SwiftUI does not pass the identifier on (menu
    /// items, dialog and alert buttons).
    private func tapButton(_ app: XCUIApplication, _ id: String, label: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let byId = element(app, id)
        if byId.waitForExistence(timeout: 2) && byId.isHittable {
            byId.tap()
            return
        }
        let byLabel = app.buttons.matching(NSPredicate(format: "label == %@", label))
        let hittable = byLabel.matching(NSPredicate(format: "hittable == true")).firstMatch
        if !hittable.waitForExistence(timeout: timeout) {
            tree(app, "missing-\(id)")
            snap(app, "missing-\(id)")
            XCTFail("no button \(id) / \(label)", file: file, line: line)
            return
        }
        hittable.tap()
    }

    /// Taps `id` once it can be hit and has stopped moving: a tap that lands while a page is still
    /// popping or a dialog is still sliding away is taken by the transition, not the control (run
    /// 39588534600, where the Library chip's tap did nothing after the delete).
    private func tapSettled(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let target = expect(app, id, timeout: timeout, file: file, line: line)
        let deadline = Date().addingTimeInterval(timeout)
        var last = target.frame
        var still = 0
        while still < 2 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let now = target.frame
            still = target.isHittable && now == last ? still + 1 : 0
            last = now
        }
        XCTAssertTrue(still >= 2, "\(id) never settled", file: file, line: line)
        target.tap()
    }

    private func gone(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20) -> Bool {
        let missing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, id))
        return XCTWaiter().wait(for: [missing], timeout: timeout) == .completed
    }

    /// Whether the elements `ids` are on screen in this reading order (top to bottom, then leading to
    /// trailing: the grid is two across).
    private func inOrder(_ app: XCUIApplication, _ ids: [String], in root: XCUIElement? = nil) -> Bool {
        var last: CGRect?
        for id in ids {
            let found = element(app, id, in: root)
            guard found.exists else { return false }
            let frame = found.frame
            if let last {
                let sameRow = abs(frame.midY - last.midY) < 8
                if sameRow ? frame.minX <= last.minX : frame.midY <= last.midY { return false }
            }
            last = frame
        }
        return true
    }

    private func expectOrder(_ app: XCUIApplication, _ ids: [String], _ what: String, in root: XCUIElement? = nil, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !inOrder(app, ids, in: root) {
            if Date() > deadline {
                tree(app, "order-\(what)")
                snap(app, "order-\(what)")
                XCTFail("\(what): expected \(ids)", file: file, line: line)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
    }

    /// Waits until the row `id` stops moving (edit mode animates the list in; a press on a row still
    /// sliding lands on its neighbour).
    private func settle(_ app: XCUIApplication, _ id: String) {
        let row = element(app, id)
        var last = row.frame
        for _ in 0..<10 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let now = row.frame
            if abs(now.minY - last.minY) < 1 { return }
            last = now
        }
    }

    /// Drags the edit-mode list row `id` (`name` names it in the screenshots) by its reorder handle onto the
    /// upper third of the row `target`, until the list reads `order` (three tries: a drag that starts before
    /// the list has settled can do nothing). The drop is not on the target's top edge: that scrolls the
    /// list mid-drag (run 39253000154, where the drop moved The Matrix to the end instead). A try that
    /// leaves the list in another order fails at once: a further drag cannot undo it. The handle is the
    /// "Reorder …" button in the row's cell; where it cannot be found, the trailing edge of the row's
    /// line, where the handle is drawn.
    private func drag(_ app: XCUIApplication, _ id: String, named name: String, before target: String, order: [String], file: StaticString = #filePath, line: UInt = #line) {
        let others = order.filter { $0 != id }
        for attempt in 1...3 {
            let row = expect(app, id, file: file, line: line)
            let goal = expect(app, target, file: file, line: line)
            settle(app, id)
            // The handle is a "Reorder …" button in the row's cell (run 39187156648: "Reorder Remove" when the
            // row's label took the delete button's).
            let cell = app.cells.containing(.any, identifier: id).firstMatch
            let handle = cell.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Reorder'")).firstMatch
            let from: XCUICoordinate
            if handle.exists {
                from = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            } else {
                let origin = app.coordinate(withNormalizedOffset: .zero)
                from = origin.withOffset(CGVector(dx: app.frame.width - 44, dy: row.frame.midY))
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let to = origin.withOffset(CGVector(dx: app.frame.width - 44, dy: goal.frame.minY + goal.frame.height / 3))
            from.press(forDuration: 0.8, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.6)
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            if inOrder(app, order) { return }
            snap(app, "drag-\(name)-try\(attempt)")
            if !inOrder(app, others) {
                tree(app, "drag-\(name)")
                XCTFail("\(name): the drag moved another row; expected \(order)", file: file, line: line)
                return
            }
        }
        tree(app, "drag-\(name)")
        XCTFail("\(name) did not move before \(target)", file: file, line: line)
    }

    private func openCollections(_ app: XCUIApplication) {
        tapTab(app, "Library")
        tap(app, "chip-Collections", timeout: 30)
        expect(app, "collections-room", timeout: 30)
    }

    // MARK: Test

    func testOpenReorderRenameDelete() {
        let app = launch()
        openCollections(app)
        expect(app, "collection-Weekend Movies", timeout: 30)
        expectOrder(app, ["collection-Weekend Movies", "collection-Sci-Fi Favourites", "collection-Comfort Shows"], "fixture order")
        XCTAssertEqual(element(app, "collection-Weekend Movies").value as? String, "4 items")
        snap(app, "01-collections")

        // Open a collection: its poster grid, in the order the titles were added.
        tap(app, "collection-Weekend Movies")
        let page = expect(app, "collection-page")
        XCTAssertEqual(expect(app, "collection-title").label, "Weekend Movies")
        XCTAssertTrue(element(app, "tile-tt0133093", in: page).waitForExistence(timeout: 10), "no poster grid")
        expectOrder(app, ["tile-tt0133093", "tile-tt0816692", "tile-tt1375666", "tile-tt0468569"], "titles", in: page)
        snap(app, "02-collection-page")

        // Edit mode: drag The Dark Knight to the front.
        // (The List takes the page's identifier, collection-page: its rows are what to wait for.)
        tap(app, "collection-edit")
        expect(app, "collection-item-tt0468569")
        snap(app, "03-collection-edit")
        let titles = ["collection-item-tt0468569", "collection-item-tt0133093", "collection-item-tt0816692", "collection-item-tt1375666"]
        drag(app, "collection-item-tt0468569", named: "The Dark Knight", before: "collection-item-tt0133093", order: titles)
        expectOrder(app, titles, "titles after drag")
        snap(app, "04-collection-reordered")
        tap(app, "collection-edit")
        XCTAssertTrue(element(app, "tile-tt0468569", in: page).waitForExistence(timeout: 10), "no poster grid after edit")
        expectOrder(app, ["tile-tt0468569", "tile-tt0133093", "tile-tt0816692", "tile-tt1375666"], "poster grid after drag", in: page)
        snap(app, "05-collection-done")
        app.navigationBars.buttons.firstMatch.tap()
        expect(app, "collection-Weekend Movies")

        // Edit mode on the grid: drag Comfort Shows to the front.
        tap(app, "collections-edit")
        expect(app, "collection-row-Comfort Shows")
        snap(app, "06-collections-edit")
        let rows = ["collection-row-Comfort Shows", "collection-row-Weekend Movies", "collection-row-Sci-Fi Favourites"]
        drag(app, "collection-row-Comfort Shows", named: "Comfort Shows", before: "collection-row-Weekend Movies", order: rows)
        expectOrder(app, rows, "collections after drag")
        snap(app, "07-collections-reordered")

        // Rename: a row's tap asks for the new name.
        tap(app, "collection-row-Sci-Fi Favourites")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "no rename alert")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no name field")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30))
        field.typeText("Sci-Fi Classics")
        snap(app, "08-rename")
        alert.buttons["Save"].tap()
        expect(app, "collection-row-Sci-Fi Classics")
        XCTAssertTrue(gone(app, "collection-row-Sci-Fi Favourites", timeout: 5), "the old name is still shown")
        tap(app, "collections-edit")
        expect(app, "collection-Sci-Fi Classics")
        expectOrder(app, ["collection-Comfort Shows", "collection-Weekend Movies", "collection-Sci-Fi Classics"], "grid after edit")
        snap(app, "09-collections-done")

        // Delete from the collection's own menu; the page closes and the grid loses it.
        tap(app, "collection-Comfort Shows")
        expect(app, "collection-page")
        tapButton(app, "collection-menu", label: "Edit collection")
        tapButton(app, "collection-delete", label: "Delete")
        snap(app, "10-delete-confirm")
        tapButton(app, "collection-delete-confirm", label: "Delete")
        expect(app, "collections-room")
        XCTAssertTrue(gone(app, "collection-page"), "the deleted collection's page stayed open")
        XCTAssertTrue(gone(app, "collection-Comfort Shows"), "the deleted collection is still shown")
        snap(app, "11-deleted")

        // Leave the room and come back: the engine kept the order, the name and the deletion.
        tapSettled(app, "chip-Library")
        XCTAssertTrue(gone(app, "collections-room", timeout: 10), "the Collections room did not close")
        openCollections(app)
        expect(app, "collection-Weekend Movies", timeout: 30)
        expectOrder(app, ["collection-Weekend Movies", "collection-Sci-Fi Classics"], "grid read back")
        XCTAssertFalse(element(app, "collection-Comfort Shows").exists, "the deleted collection came back")
        tap(app, "collection-Weekend Movies")
        let reread = expect(app, "collection-page")
        XCTAssertTrue(element(app, "tile-tt0468569", in: reread).waitForExistence(timeout: 10), "no poster grid read back")
        expectOrder(app, ["tile-tt0468569", "tile-tt0133093", "tile-tt0816692", "tile-tt1375666"], "titles read back", in: reread)
        snap(app, "12-read-back")
    }
}
