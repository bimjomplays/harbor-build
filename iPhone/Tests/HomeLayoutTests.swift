import XCTest
@testable import HarborPhone

/// HomeLayout as data: the default, the saved format, unknown sources and the editing helpers.
final class HomeLayoutTests: XCTestCase {
    private func roundTrip(_ layout: HomeLayout) throws -> HomeLayout {
        let data = try JSONEncoder().encode(layout)
        return try JSONDecoder().decode(HomeLayout.self, from: data)
    }

    private func decode(_ json: String) throws -> HomeLayout {
        try JSONDecoder().decode(HomeLayout.self, from: Data(json.utf8))
    }

    // MARK: Defaults

    func testStandardLayoutIsTodaysHome() {
        let layout = HomeLayout.standard
        XCTAssertEqual(layout.hero, .auto)
        XCTAssertEqual(layout.rows.map(\.source), [.continueWatching(.home), .engineRoom(.home)])
        XCTAssertTrue(layout.isDefault)
        XCTAssertEqual(HomeLayout.standard, HomeLayout.standard, "two fresh defaults compare equal (fixed ids)")
    }

    func testAnEditedLayoutIsNotDefault() {
        var layout = HomeLayout.standard
        layout.insert(.engineRow(room: .movies, key: "bp-top10"))
        XCTAssertFalse(layout.isDefault)
        layout.remove(id: layout.rows[2].id)
        XCTAssertTrue(layout.isDefault)
    }

    // MARK: Codable

    func testRoundTripKeepsEverySourceKind() throws {
        var layout = HomeLayout(hero: .source(.anilistList(railKey: "watching")), rows: [])
        layout.insert(.continueWatching(.anime), title: "Anime in progress")
        layout.insert(.engineRoom(.home))
        layout.insert(.engineRow(room: .movies, key: "bp-top10"), savedTitle: "Top 10 Movies", options: HomeRowOptions(shape: .rank, limit: 10))
        layout.insert(.anilistList(railKey: "planning"))
        layout.insert(.malList(railKey: "onhold"))
        layout.insert(.addonCatalog(base: "https://addon.example/manifest.json", catalog: "movie/top"))
        XCTAssertEqual(try roundTrip(layout), layout)
    }

    func testHeroSourcesRoundTrip() throws {
        for hero: HomeHeroSource in [.auto, .off, .source(.engineRow(room: .anime, key: "airing")), .source(.continueWatching(.home))] {
            XCTAssertEqual(try roundTrip(HomeLayout(hero: hero, rows: [])).hero, hero)
        }
    }

    func testOptionsAreLeftOutWhenEmpty() throws {
        let spec = HomeRowSpec(id: "a", source: .engineRoom(.home))
        let json = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        XCTAssertFalse(json.contains("options"))
    }

    // MARK: Unknown and broken input

    func testUnknownSourceKindIsKeptAndSurvivesASave() throws {
        let json = """
        {"hero":{"kind":"auto"},"rows":[
          {"id":"a","source":{"kind":"continueWatching","room":"home"}},
          {"id":"b","source":{"kind":"spotifyPodcasts","show":"x","n":3}},
          {"id":"c","source":{"kind":"engineRoom","room":"home"}}
        ]}
        """
        let layout = try decode(json)
        XCTAssertEqual(layout.rows.map(\.id), ["a", "b", "c"])
        guard case .unknown(let raw) = layout.rows[1].source else { return XCTFail("expected .unknown") }
        XCTAssertFalse(layout.rows[1].source.isKnown)
        XCTAssertEqual(layout.rows[1].source.identity, "unknown:spotifyPodcasts")
        // Written back verbatim, so a newer build reading it again still has it.
        let again = try roundTrip(layout)
        XCTAssertEqual(again.rows[1].source, .unknown(raw))
    }

    func testARoomThisBuildLacksIsUnknown() throws {
        let layout = try decode(#"{"rows":[{"id":"a","source":{"kind":"engineRow","room":"sports","key":"live"}}]}"#)
        XCTAssertFalse(layout.rows[0].source.isKnown)
    }

    func testAMissingFieldIsUnknownNotACrash() throws {
        let layout = try decode(#"{"rows":[{"id":"a","source":{"kind":"engineRow","room":"home"}},{"id":"b","source":"nonsense"}]}"#)
        XCTAssertEqual(layout.rows.count, 2)
        XCTAssertFalse(layout.rows[0].source.isKnown)
        XCTAssertFalse(layout.rows[1].source.isKnown)
    }

    func testContinueWatchingWithoutARoomIsHome() throws {
        let layout = try decode(#"{"rows":[{"id":"a","source":{"kind":"continueWatching"}}]}"#)
        XCTAssertEqual(layout.rows[0].source, .continueWatching(.home))
    }

    func testAnUnreadableRowIsDroppedNotTheLayout() throws {
        let layout = try decode(#"{"hero":{"kind":"off"},"rows":[{"id":"a","source":{"kind":"engineRoom","room":"home"}},42,{"id":"c","source":{"kind":"malList","railKey":"watching"}}]}"#)
        XCTAssertEqual(layout.hero, .off)
        XCTAssertEqual(layout.rows.map(\.source), [.engineRoom(.home), .malList(railKey: "watching")])
    }

    func testMissingIdsAndDuplicateIdsGetFreshOnes() throws {
        let layout = try decode(#"{"rows":[{"source":{"kind":"engineRoom","room":"home"}},{"id":"x","source":{"kind":"continueWatching"}},{"id":"x","source":{"kind":"engineRoom","room":"anime"}}]}"#)
        XCTAssertFalse(layout.rows[0].id.isEmpty)
        XCTAssertEqual(Set(layout.rows.map(\.id)).count, 3)
        XCTAssertEqual(layout.rows[1].id, "x")
    }

    func testAnUnknownHeroIsAuto() throws {
        XCTAssertEqual(try decode(#"{"hero":{"kind":"spotlight"},"rows":[]}"#).hero, .auto)
        XCTAssertEqual(try decode(#"{"hero":{"kind":"source","source":{"kind":"later"}},"rows":[]}"#).hero, .auto)
        XCTAssertEqual(try decode(#"{"rows":[]}"#).hero, .auto)
    }

    func testBadOptionsAreDropped() throws {
        let layout = try decode(#"{"rows":[{"id":"a","source":{"kind":"engineRoom","room":"home"},"options":{"shape":"hexagon","limit":-3}}]}"#)
        XCTAssertEqual(layout.rows[0].options, HomeRowOptions())
    }

    // MARK: Editing

    private func threeRows() -> HomeLayout {
        HomeLayout(rows: [
            HomeRowSpec(id: "a", source: .continueWatching(.home)),
            HomeRowSpec(id: "b", source: .engineRoom(.home)),
            HomeRowSpec(id: "c", source: .anilistList(railKey: "watching")),
        ])
    }

    func testInsertAtAnIndexAndAtTheEnd() {
        var layout = threeRows()
        let first = layout.insert(.malList(railKey: "watching"), at: 0)
        let last = layout.insert(.engineRoom(.anime), at: 99)
        XCTAssertEqual(layout.rows.first?.id, first)
        XCTAssertEqual(layout.rows.last?.id, last)
        XCTAssertEqual(layout.rows.count, 5)
        layout.insert(HomeRowSpec(id: "a", source: .engineRoom(.shows)), at: -4)
        XCTAssertEqual(layout.rows.first?.source, .engineRoom(.shows))
        XCTAssertNotEqual(layout.rows.first?.id, "a", "a clashing id is replaced")
    }

    func testRemove() {
        var layout = threeRows()
        XCTAssertEqual(layout.remove(id: "b")?.source, .engineRoom(.home))
        XCTAssertNil(layout.remove(id: "nope"))
        XCTAssertEqual(layout.rows.map(\.id), ["a", "c"])
        layout = threeRows()
        layout.remove(atOffsets: IndexSet([0, 2, 7]))
        XCTAssertEqual(layout.rows.map(\.id), ["b"])
    }

    func testMoveFollowsOnMove() {
        var layout = threeRows()
        layout.move(fromOffsets: IndexSet([0]), toOffset: 3)
        XCTAssertEqual(layout.rows.map(\.id), ["b", "c", "a"])
        layout.move(fromOffsets: IndexSet([2]), toOffset: 0)
        XCTAssertEqual(layout.rows.map(\.id), ["a", "b", "c"])
        layout.move(fromOffsets: IndexSet([0, 2]), toOffset: 2)
        XCTAssertEqual(layout.rows.map(\.id), ["b", "a", "c"])
    }

    func testMoveByIsClamped() {
        var layout = threeRows()
        XCTAssertTrue(layout.move(id: "a", by: 1))
        XCTAssertEqual(layout.rows.map(\.id), ["b", "a", "c"])
        XCTAssertTrue(layout.move(id: "a", by: 10))
        XCTAssertEqual(layout.rows.map(\.id), ["b", "c", "a"])
        XCTAssertFalse(layout.move(id: "a", by: 1))
        XCTAssertFalse(layout.move(id: "missing", by: -1))
    }

    func testRenameTrimsAndClears() {
        var layout = threeRows()
        layout.rename(id: "c", to: "  Weekend list ")
        XCTAssertEqual(layout.rows[2].title, "Weekend list")
        layout.rename(id: "c", to: "   ")
        XCTAssertNil(layout.rows[2].title)
    }

    func testExpandRoomSplitsItAndSkipsPlacedRows() {
        var layout = HomeLayout(rows: [
            HomeRowSpec(id: "top", source: .engineRow(room: .home, key: "trending")),
            HomeRowSpec(id: "all", source: .engineRoom(.home), options: HomeRowOptions(limit: 6)),
        ])
        let page: [BrowseRow] = ["bp-top10", "trending", "services"].map { BrowseRow(key: $0, title: $0.uppercased(), metas: []) }
        XCTAssertTrue(layout.expandRoom(id: "all", rows: page))
        XCTAssertEqual(layout.rows.map(\.source), [
            .engineRow(room: .home, key: "trending"), .engineRow(room: .home, key: "bp-top10"), .engineRow(room: .home, key: "services"),
        ])
        XCTAssertEqual(layout.rows[1].savedTitle, "BP-TOP10")
        XCTAssertEqual(layout.rows[1].options.limit, 6)
        XCTAssertFalse(layout.expandRoom(id: "top", rows: page))
    }

    func testIdentityTellsSourcesApart() {
        let sources: [HomeRowSource] = [
            .engineRoom(.home), .engineRoom(.anime), .engineRow(room: .home, key: "a"), .engineRow(room: .movies, key: "a"),
            .continueWatching(.home), .anilistList(railKey: "watching"), .malList(railKey: "watching"),
            .addonCatalog(base: "b", catalog: "c"),
        ]
        XCTAssertEqual(Set(sources.map(\.identity)).count, sources.count)
    }
}
