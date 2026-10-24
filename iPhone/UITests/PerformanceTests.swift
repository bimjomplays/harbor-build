import XCTest

/// Frame and memory measurements of the screens that scroll the most, on the fixture library,
/// and the app icon on the home screen in light and dark.
///
/// The measurements (`measure(metrics:)`) record scroll deceleration (the system's own hitch signposts), wall
/// time and the app's memory into the result bundle on every run. They carry no baseline, so a slow or
/// busy machine cannot fail them; they are there to read the numbers from. (The simulator draws on the
/// Mac's GPU without ProMotion: hitch numbers on it only show a screen that got far slower than before.)
/// The memory ceiling that does fail is PhonePerformanceTests (unit): decoded art at the wrong size.
///
/// The English UI is assumed.
final class PerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: Helpers

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

    @discardableResult
    private func expect(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let found = element(app, id)
        if !found.waitForExistence(timeout: timeout) {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "hierarchy-missing-\(id)"
            tree.lifetime = .keepAlways
            add(tree)
            snap("missing-\(id)")
            XCTFail("no element \(id)", file: file, line: line)
        }
        return found
    }

    /// A drag between two points of the screen (fractions of its size), slow enough to scroll and let go
    /// fast enough to fling, never `swipeUp()` on Home: that starts on the hero (see FeedTests.scrollFeed).
    private func drag(_ app: XCUIApplication, from: CGVector, to: CGVector) {
        let start = app.coordinate(withNormalizedOffset: from)
        let end = app.coordinate(withNormalizedOffset: to)
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func measureScrolling(_ app: XCUIApplication, _ block: @escaping () -> Void) {
        let options = XCTMeasureOptions()
        options.iterationCount = 2
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app), XCTOSSignpostMetric.scrollDecelerationMetric], options: options, block: block)
    }

    // MARK: Scrolling

    /// Home: the hero, Continue Watching and every row, flung down the feed (rails and tiles are created as
    /// they arrive). Drags start low on the screen, below the hero.
    func testHomeFeedScroll() throws {
        let app = launchHarbor(["--fixtures", "shell"])
        expect(app, "hero-carousel", timeout: 30)
        expect(app, "rail-Continue Watching")
        measureScrolling(app) {
            for _ in 0..<3 { self.drag(app, from: CGVector(dx: 0.5, dy: 0.9), to: CGVector(dx: 0.5, dy: 0.25)) }
        }
        snap("perf-home-scrolled")
    }

    /// The Library grid: poster rows flung up and back.
    func testLibraryGridScroll() throws {
        let app = launchHarbor(["--fixtures", "shell"])
        tapTab(app, "Library")
        expect(app, "library", timeout: 30)
        measureScrolling(app) {
            for _ in 0..<2 {
                self.drag(app, from: CGVector(dx: 0.5, dy: 0.85), to: CGVector(dx: 0.5, dy: 0.3))
                self.drag(app, from: CGVector(dx: 0.5, dy: 0.3), to: CGVector(dx: 0.5, dy: 0.85))
            }
        }
        snap("perf-library-scrolled")
    }

    /// The Calendar: the month grid swiped between months, the agenda flung.
    func testCalendarMonthsAndAgenda() throws {
        let app = launchHarbor(["--fixtures", "detail"])
        tapTab(app, "Library")
        expect(app, "chip-Calendar", timeout: 30).tap()
        let grid = expect(app, "calendar-grid", timeout: 30)
        measureScrolling(app) {
            grid.swipeLeft()
            grid.swipeRight()
            self.drag(app, from: CGVector(dx: 0.5, dy: 0.9), to: CGVector(dx: 0.5, dy: 0.6))
            self.drag(app, from: CGVector(dx: 0.5, dy: 0.6), to: CGVector(dx: 0.5, dy: 0.9))
        }
        snap("perf-calendar")
    }

    // MARK: App icon

    /// The icon on the home screen with the system in light and in dark (iOS 26 picks the AppIcon's matching
    /// variant); a screenshot of each goes into the run's screenshots. Tinted needs the Home Screen
    /// customisation sheet, which the simulator does not offer to a test: it is checked on a device.
    func testAppIconLightAndDark() throws {
        let app = launchHarbor(["--fixtures", "shell"])
        expect(app, "feed-home", timeout: 30)
        app.terminate()
        // .unspecified is refused by the simulator ("appearance value (0) is not valid"): restore light.
        defer { XCUIDevice.shared.appearance = .light }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for (name, style) in [("light", XCUIDevice.Appearance.light), ("dark", XCUIDevice.Appearance.dark)] {
            XCUIDevice.shared.appearance = style
            XCUIDevice.shared.press(.home)
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            // The app's icon sits on a later Home Screen page: swipe until it is on screen.
            var pages = 0
            while !springboard.icons["Harbor"].exists, pages < 5 {
                springboard.swipeLeft()
                pages += 1
                RunLoop.current.run(until: Date().addingTimeInterval(1))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            snap("app-icon-\(name)")
        }
    }
}
