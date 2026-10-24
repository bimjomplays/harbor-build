import XCTest
@testable import HarborPhone

/// The pure parts of Settings' playback and services pages: the stream order the engine will rank by,
/// and the words the Settings list shows for a page.
@MainActor
final class PhoneSettingsPanelsTests: XCTestCase {
    private typealias Entry = PhoneStreamPriorityPanel.Entry

    private func addons(_ keys: String...) -> [Entry] {
        keys.map { Entry(key: $0, name: $0.uppercased(), first: false) }
    }

    func testNoSavedOrderKeepsTheInstalledOrder() {
        let installed = addons("a", "b", "c")
        XCTAssertEqual(PhoneStreamPriorityPanel.arranged(installed, saved: []).map(\.key), ["a", "b", "c"])
    }

    func testSavedAddonsLeadInTheirOrderAndTheRestFollow() {
        let installed = addons("a", "b", "c", "d")
        XCTAssertEqual(PhoneStreamPriorityPanel.arranged(installed, saved: ["c", "a"]).map(\.key), ["c", "a", "b", "d"])
        XCTAssertEqual(PhoneStreamPriorityPanel.arranged(installed, saved: ["d"]).map(\.key), ["d", "a", "b", "c"])
    }

    func testSavedKeysOfRemovedAddonsAreIgnoredAndRepeatsCountOnce() {
        let installed = addons("a", "b")
        XCTAssertEqual(PhoneStreamPriorityPanel.arranged(installed, saved: ["gone", "b", "b"]).map(\.key), ["b", "a"])
    }

    func testSubtitleSummary() {
        XCTAssertEqual(PhoneSubtitlesPanel.summary([]), "Off")
        XCTAssertEqual(PhoneSubtitlesPanel.summary(["English"]), "English")
        XCTAssertEqual(PhoneSubtitlesPanel.summary(["Japanese", "English", "French"]), "Japanese +2")
    }

    func testTmdbSummary() {
        XCTAssertEqual(PhoneTmdbPanel.summary(key: "", rejected: false), "Cinemeta")
        XCTAssertEqual(PhoneTmdbPanel.summary(key: "abc", rejected: false), "Saved")
        XCTAssertEqual(PhoneTmdbPanel.summary(key: "abc", rejected: true), "Refused")
    }

    func testStremioLine() {
        XCTAssertEqual(PhoneStremioPanel.line("Sam Doe", "sam@example.com"), "Signed in as Sam Doe")
        XCTAssertEqual(PhoneStremioPanel.line(nil, "sam@example.com"), "Signed in as sam@example.com")
        XCTAssertEqual(PhoneStremioPanel.line("  ", " "), "Signed in")
    }
}
