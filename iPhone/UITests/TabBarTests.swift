import XCTest

/// The tab bar on the shell fixtures (`--fixtures shell`): every tab has its button, and `tapTab`
/// (UITestSupport.swift) opens the tab's screen. The iOS 26 bar's buttons carry no identifier, only
/// their label (run 39164586324), so this checks labels. Nothing here touches the network.
final class TabBarTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func screen(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func isSelected(_ app: XCUIApplication, _ title: String) -> XCTWaiter.Result {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"),
                                                 object: app.tabBars.firstMatch.buttons[title].firstMatch)
        return XCTWaiter().wait(for: [selected], timeout: 10)
    }

    func testEveryTabHasItsButtonAndOpensItsScreen() throws {
        let app = launchHarbor(["--fixtures", "shell"])
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 30), "no tab bar")
        for title in ["Home", "Discover", "Live", "Library", "Search"] {
            XCTAssertTrue(bar.buttons[title].firstMatch.waitForExistence(timeout: 10), "no tab-bar button \(title)")
        }
        XCTAssertEqual(isSelected(app, "Home"), .completed, "Home is not the selected tab at launch")

        tapTab(app, "Discover")
        XCTAssertTrue(screen(app, "discover").waitForExistence(timeout: 30), "Discover did not open")
        XCTAssertEqual(isSelected(app, "Discover"), .completed, "the Discover tab is not selected")
        tapTab(app, "Home")
        XCTAssertTrue(screen(app, "rail-Continue Watching").waitForExistence(timeout: 30), "Home did not open")
        XCTAssertEqual(isSelected(app, "Home"), .completed, "the Home tab is not selected")
        // Last: with Search selected the iOS 26 bar folds the other tabs away.
        tapTab(app, "Search")
        XCTAssertTrue(screen(app, "search-screen").waitForExistence(timeout: 30), "Search did not open")
    }
}
