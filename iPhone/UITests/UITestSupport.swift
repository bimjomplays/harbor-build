import XCTest

/// What every HarborPhone UI test shares: a launch that waits until the app is really up,
/// and one tab-bar tap that copes with the iOS 26 bar; and waits on what the test needs next instead of
/// fixed sleeps. Both answer flakes seen on ios.yml:
/// - run 39157457939: "Failed to launch ... Timed out while launching application" and "Failed to get
///   background assertion for target app" (a launch over an instance still going down);
/// - run 39148508258: "Failed to get matching snapshots: Error getting main window kAXErrorServerNotFound"
///   (the first element query ran before the app's accessibility server answered);
/// - run 39153213779: "Failed to tap Search Button, Multiple matching elements" (the iOS 26 tab bar drew
///   two Search buttons for a moment).
/// ios.yml retries a failed test once on top of this and reports a test that only passed on its retry.
extension XCTestCase {
    /// Launches HarborPhone with `arguments` and returns once it is running in the foreground with a
    /// window, instead of querying it the moment `launch()` returns. The last test's instance is
    /// terminated first, and waited for, so a launch never lands on an app still going down.
    func launchHarbor(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 15)
        }
        app.launchArguments = arguments
        app.launch()
        // The state needs no element snapshot, so it can be asked before the accessibility server is up.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "the app did not come to the foreground", file: file, line: line)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "the app has no window", file: file, line: line)
        return app
    }

    /// Taps the tab-bar tab titled `title` ("Home", "Search", ...): the first button with that label
    /// inside the tab bar, once it is hittable. The iOS 26 bar can hold two buttons for a tab for a moment
    /// (run 39153213779: "Multiple matching elements"), and a tab mid-animation is not hittable yet.
    /// By label, not identifier: the iOS 26 tab-bar buttons expose none. `.accessibilityIdentifier` on a
    /// SwiftUI `Tab` never reaches them; their only identifier is the SF symbol name on the image inside
    /// (run 39164586324's UI hierarchy). TabBarTests covers this.
    func tapTab(_ app: XCUIApplication, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 30), "no tab bar", file: file, line: line)
        let button = bar.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(title) tab", file: file, line: line)
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: button)
        XCTAssertEqual(XCTWaiter().wait(for: [hittable], timeout: 10), .completed, "the \(title) tab is not hittable", file: file, line: line)
        button.tap()
    }

    /// The first of `elements` that exists within `timeout`, or nil (earlier ones win when several do).
    /// One wait for "this or that": no fixed wait on the first before trying the second,
    /// and no sleep while waiting for whichever the app shows.
    func firstToExist(_ elements: [XCUIElement], timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let found = elements.first(where: { $0.exists }) { return found }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return elements.first(where: { $0.exists })
    }

    /// Returns once `element`'s frame reads the same twice in a row, 0.2 s apart (a sheet or scroll has
    /// come to rest), or after `timeout`: what a screenshot of a settled screen waits for, instead of a
    /// fixed sleep.
    func waitForSteadyFrame(_ element: XCUIElement, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = element.frame
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let now = element.frame
            if now == last { return }
            last = now
        }
    }
}
