import XCTest

/// The Library tab's Calendar chip on fixtures (`--fixtures detail`): PhoneCalendarFixtures gives every
/// month releases on the 3rd (one), the 12th (two) and the 21st (three) and three reminders, so the
/// grid's dots, the agenda, a month swipe, a release's title page and the reminders sheet are all
/// driven offline.
///
/// The English UI is assumed.
final class CalendarTests: XCTestCase {
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
        expect(app, id, timeout: timeout, file: file, line: line).tap()
    }

    /// Waits until `predicate` holds for the element; a miss fails with the screen attached.
    private func wait(_ app: XCUIApplication, _ id: String, _ predicate: String, _ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
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

    /// "2026-10-21" for a day of the month `offset` months from this one, as the app's grid ids.
    private func iso(day: Int, monthOffset offset: Int = 0) -> String {
        let calendar = Calendar.current
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
        let month = calendar.date(byAdding: .month, value: offset, to: first)!
        let p = calendar.dateComponents([.year, .month], from: month)
        return String(format: "%04d-%02d-%02d", p.year!, p.month!, day)
    }

    /// The shell on the Library tab, with the Calendar chip open.
    private func openCalendar() -> XCUIApplication {
        let app = launchHarbor(["--fixtures", "detail"])
        tapTab(app, "Library")
        tap(app, "chip-Calendar", timeout: 30)
        expect(app, "calendar-grid", timeout: 30)
        return app
    }

    // MARK: Tests

    /// The grid has a dot per release on the fixture days and none elsewhere; a tapped day is marked
    /// and the agenda scrolls to its releases; a release pushes its title page.
    func testGridDotsAndAgenda() throws {
        let app = openCalendar()
        wait(app, "calendar-day-\(iso(day: 3))", "value == '1 release'", "the 3rd shows no single dot")
        wait(app, "calendar-day-\(iso(day: 12))", "value == '2 releases'", "the 12th shows no two dots")
        wait(app, "calendar-day-\(iso(day: 21))", "value == '3 releases'", "the 21st shows no three dots")
        let quiet = expect(app, "calendar-day-\(iso(day: 5))")
        XCTAssertTrue((quiet.value as? String ?? "").isEmpty, "the 5th has dots: \(String(describing: quiet.value))")
        snap(app, "calendar-month")

        tap(app, "calendar-day-\(iso(day: 21))")
        wait(app, "calendar-day-\(iso(day: 21))", "selected == true", "the tapped day is not marked")
        wait(app, "calendar-agenda-\(iso(day: 21))", "hittable == true", "the agenda did not scroll to the 21st")
        expect(app, "calendar-entry-m-6")
        expect(app, "calendar-entry-s-5:1:7")
        snap(app, "calendar-day-21")

        tap(app, "calendar-day-\(iso(day: 3))")
        wait(app, "calendar-agenda-\(iso(day: 3))", "hittable == true", "the agenda did not scroll back to the 3rd")
        wait(app, "calendar-entry-s-3:1:1", "hittable == true", "the 3rd's release is not on screen")

        tap(app, "calendar-entry-s-3:1:1")
        expect(app, "detail-page", timeout: 30)
        wait(app, "detail-name", "label == 'Severance'", "the release opened another title")
        snap(app, "calendar-detail")
    }

    /// A swipe on the grid moves to the next month (with its own fixture days), Today comes back.
    func testSwipeBetweenMonths() throws {
        let app = openCalendar()
        expect(app, "calendar-day-\(iso(day: 12))")
        XCTAssertFalse(element(app, "calendar-today").exists, "Today shows on this month")

        let grid = expect(app, "calendar-grid")
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)))
        wait(app, "calendar-day-\(iso(day: 12, monthOffset: 1))", "value == '2 releases'", "the swipe did not open next month")
        snap(app, "calendar-next-month")

        tap(app, "calendar-today")
        wait(app, "calendar-day-\(iso(day: 21))", "value == '3 releases'", "Today did not come back to this month")
        XCTAssertTrue(gone(app, "calendar-today"), "Today stayed on this month")

        tap(app, "calendar-prev")
        expect(app, "calendar-day-\(iso(day: 12, monthOffset: -1))")
    }

    /// The bell opens the reminders sheet with the fixture reminders; one removed leaves the list and
    /// the bell's count.
    func testRemindersSheetRemovesAReminder() throws {
        let app = openCalendar()
        wait(app, "calendar-reminders", "value == '3'", "the bell does not count three reminders")
        tap(app, "calendar-reminders")
        expect(app, "reminder-s-3")
        expect(app, "reminder-s-2")
        expect(app, "reminder-s-5")
        snap(app, "reminders-sheet")

        tap(app, "reminder-remove-s-2")
        XCTAssertTrue(gone(app, "reminder-s-2"), "the removed reminder is still listed")
        expect(app, "reminder-s-3")
        wait(app, "reminders-note", "label == 'Reminder removed'", "no Reminder removed note")
        snap(app, "reminders-removed")

        tap(app, "reminders-done")
        XCTAssertTrue(gone(app, "reminder-s-3"), "the sheet did not close")
        wait(app, "calendar-reminders", "value == '2'", "the bell still counts the removed reminder")
    }
}
