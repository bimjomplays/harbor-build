import XCTest
@testable import HarborPhone

/// One layout per profile, versioned, in a store the tests own (no UserDefaults).
@MainActor
final class HomeLayoutStoreTests: XCTestCase {
    private func edited() -> HomeLayout {
        var layout = HomeLayout.standard
        layout.insert(.engineRow(room: .movies, key: "bp-top10"), at: 1)
        layout.hero = .off
        return layout
    }

    func testNothingSavedIsTheDefault() {
        let store = HomeLayoutStore(storage: MemoryHomeLayoutStorage())
        XCTAssertEqual(store.layout(for: "p1"), .standard)
        XCTAssertFalse(store.hasSavedLayout(for: "p1"))
    }

    func testProfilesAreKeptApart() {
        let storage = MemoryHomeLayoutStorage()
        let store = HomeLayoutStore(storage: storage)
        store.save(edited(), for: "p1")
        XCTAssertEqual(store.layout(for: "p1"), edited().withSameIds(as: store.layout(for: "p1")))
        XCTAssertEqual(store.layout(for: "p2"), .standard)
        XCTAssertEqual(Array(storage.values.keys), ["phone.homeLayout.p1"])
        // A second store over the same storage (the next launch) reads the same thing.
        XCTAssertEqual(HomeLayoutStore(storage: storage).layout(for: "p1"), store.layout(for: "p1"))
    }

    func testSavedLayoutRoundTripsExactly() {
        let store = HomeLayoutStore(storage: MemoryHomeLayoutStorage())
        let layout = edited()
        store.save(layout, for: "p1")
        XCTAssertEqual(store.layout(for: "p1"), layout)
    }

    func testTheSavedFormatIsVersioned() throws {
        let storage = MemoryHomeLayoutStorage()
        HomeLayoutStore(storage: storage).save(edited(), for: "p1")
        let raw = try XCTUnwrap(storage.values[HomeLayoutStore.key(for: "p1")])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, HomeLayoutStore.currentVersion)
        XCTAssertNotNil(object["layout"] as? [String: Any])
    }

    func testResetGoesBackToTheDefault() {
        let store = HomeLayoutStore(storage: MemoryHomeLayoutStorage())
        store.save(edited(), for: "p1")
        store.save(edited(), for: "p2")
        let before = store.revision
        store.reset(for: "p1")
        XCTAssertEqual(store.layout(for: "p1"), .standard)
        XCTAssertFalse(store.hasSavedLayout(for: "p1"))
        XCTAssertTrue(store.hasSavedLayout(for: "p2"), "a reset is one profile's")
        XCTAssertGreaterThan(store.revision, before)
    }

    func testSavingTheDefaultClearsTheKey() {
        let store = HomeLayoutStore(storage: MemoryHomeLayoutStorage())
        store.save(edited(), for: "p1")
        store.save(.standard, for: "p1")
        XCTAssertFalse(store.hasSavedLayout(for: "p1"))
    }

    func testUpdateReadsChangesAndSaves() {
        let store = HomeLayoutStore(storage: MemoryHomeLayoutStorage())
        store.update(for: "p1") { $0.insert(.malList(railKey: "watching")) }
        XCTAssertEqual(store.layout(for: "p1").rows.last?.source, .malList(railKey: "watching"))
        XCTAssertEqual(store.layout(for: "p2"), .standard)
    }

    func testUnreadableSavesAreTheDefault() throws {
        let storage = MemoryHomeLayoutStorage()
        let store = HomeLayoutStore(storage: storage)
        try storage.set("not json", for: HomeLayoutStore.key(for: "p1"))
        XCTAssertEqual(store.layout(for: "p1"), .standard)
        try storage.set(#"{"version":1,"layout":"oops"}"#, for: HomeLayoutStore.key(for: "p1"))
        XCTAssertEqual(store.layout(for: "p1"), .standard)
    }

    func testANewerVersionWithUnknownRowsIsReadAndKept() throws {
        let storage = MemoryHomeLayoutStorage()
        let store = HomeLayoutStore(storage: storage)
        let raw = """
        {"version":7,"extra":true,"layout":{"hero":{"kind":"auto"},"rows":[
          {"id":"a","source":{"kind":"continueWatching","room":"home"}},
          {"id":"b","source":{"kind":"liveSports","league":"x"}}
        ]}}
        """
        try storage.set(raw, for: HomeLayoutStore.key(for: "p1"))
        var layout = store.layout(for: "p1")
        XCTAssertEqual(layout.rows.map(\.id), ["a", "b"])
        XCTAssertFalse(layout.rows[1].source.isKnown)
        // An edit on this build keeps the row it cannot show.
        layout.rename(id: "a", to: "Keep going")
        store.save(layout, for: "p1")
        XCTAssertEqual(store.layout(for: "p1").rows[1].source.identity, "unknown:liveSports")
    }
}

private extension HomeLayout {
    /// The layout itself: `edited()` makes a fresh UUID each call, so compare against the saved ids.
    func withSameIds(as other: HomeLayout) -> HomeLayout {
        var copy = self
        for i in copy.rows.indices where i < other.rows.count { copy.rows[i].id = other.rows[i].id }
        return copy
    }
}
