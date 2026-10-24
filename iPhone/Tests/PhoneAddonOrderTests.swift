import XCTest
@testable import HarborPhone

/// Reordering addons: a List drop turned into the organizer's move, the shared
/// AddonOrganizeModel's move, and the fixture list's save that the UI test's order rests on.
final class PhoneAddonOrderTests: XCTestCase {
    // MARK: onMove offsets

    func testDropOffsetBecomesTargetIndex() {
        XCTAssertEqual(PhoneAddonOrder.target(from: 0, toOffset: 3), 2, "down to the end of three")
        XCTAssertEqual(PhoneAddonOrder.target(from: 0, toOffset: 2), 1, "down one")
        XCTAssertEqual(PhoneAddonOrder.target(from: 2, toOffset: 0), 0, "up to the top")
        XCTAssertEqual(PhoneAddonOrder.target(from: 2, toOffset: 1), 1, "up one")
    }

    func testDropNextToItselfIsNoMove() {
        XCTAssertEqual(PhoneAddonOrder.target(from: 1, toOffset: 1), 1)
        XCTAssertEqual(PhoneAddonOrder.target(from: 1, toOffset: 2), 1)
    }

    // MARK: AddonOrganizeModel.move

    private func row(_ name: String) -> AddonOrganizeModel.Row {
        AddonOrganizeModel.Row(key: "https://\(name).example/manifest.json", name: name, host: "\(name).example", addonId: name, logo: nil)
    }

    @MainActor
    func testModelMoveMatchesListMove() {
        let names = ["a", "b", "c", "d"]
        for from in names.indices {
            for offset in 0...names.count {
                let organize = AddonOrganizeModel(authKey: nil, onSaved: { _ in })
                organize.device = names.map(row)
                organize.baselineDevice = organize.device
                organize.move(.device, from: from, to: PhoneAddonOrder.target(from: from, toOffset: offset))
                var expected = names
                expected.move(fromOffsets: IndexSet(integer: from), toOffset: offset)
                XCTAssertEqual(organize.device.map(\.name), expected, "from \(from) to offset \(offset)")
                XCTAssertEqual(organize.dirty, expected != names)
            }
        }
    }

    @MainActor
    func testModelMoveClampsTheTarget() {
        let organize = AddonOrganizeModel(authKey: nil, onSaved: { _ in })
        organize.device = ["a", "b", "c"].map(row)
        organize.move(.device, from: 0, to: 99)
        XCTAssertEqual(organize.device.map(\.name), ["b", "c", "a"])
        organize.move(.device, from: 2, to: -5)
        XCTAssertEqual(organize.device.map(\.name), ["a", "b", "c"])
    }

    // MARK: fixture list

    @MainActor
    func testFixtureSaveReordersTheInstalledList() throws {
        let fixtures = PhoneAddonsFixtures()
        let keys = fixtures.installed.map(\.url)
        let saved = try fixtures.answer("addonsManager.organizeSave", [.array([]), .array(keys.reversed().map(AnyJSON.string))])
        XCTAssertEqual(saved["ok"]?.bool, true)
        XCTAssertEqual(fixtures.installed.map(\.url), keys.reversed())

        let loaded = try fixtures.answer("addonsManager.load", [])
        let names = loaded["installed"]?.array?.compactMap { $0["name"]?.string }
        XCTAssertEqual(names, ["Fixture Streams", "OpenSubtitles", "Cinemeta"])
    }

    @MainActor
    func testFixtureSaveRefusesAStaleList() throws {
        let fixtures = PhoneAddonsFixtures()
        let before = fixtures.installed.map(\.url)
        let saved = try fixtures.answer("addonsManager.organizeSave", [.array([]), .array([.string(before[0])])])
        XCTAssertEqual(saved["ok"]?.bool, false)
        XCTAssertEqual(fixtures.installed.map(\.url), before)
    }

    @MainActor
    func testFixtureInstallByLinkAndRemove() throws {
        let fixtures = PhoneAddonsFixtures()
        let link = "stremio://fixture.example/community/manifest.json"
        let match = try fixtures.answer("addonsManager.resolveUrl", [.string(link), .null])
        XCTAssertEqual(match["url"]?.string, PhoneAddonsFixtures.installableUrl)
        XCTAssertEqual(match["matchKind"]?.string, "fresh")

        let installed = try fixtures.answer("addonsManager.installUrl", [.string(PhoneAddonsFixtures.installableUrl), .null])
        XCTAssertEqual(installed["ok"]?.bool, true)
        XCTAssertEqual(fixtures.installed.last?.name, "Fixture Community")

        let removed = try fixtures.answer("addonsManager.uninstall", [.string("example.fixture.community")])
        XCTAssertEqual(removed["ok"]?.bool, true)
        XCTAssertFalse(fixtures.installed.contains { $0.name == "Fixture Community" })

        let unknown = try fixtures.answer("addonsManager.resolveUrl", [.string("https://example.invalid/manifest.json"), .null])
        XCTAssertNotNil(unknown["error"]?.string)
    }
}
