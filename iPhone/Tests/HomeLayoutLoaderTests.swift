import XCTest
@testable import HarborPhone

// MARK: Fakes

/// A BrowseSource that counts its reads. Room pages are read side by side, hence the lock.
final class CountingBrowseSource: BrowseSource, @unchecked Sendable {
    struct Failure: LocalizedError { var errorDescription: String? { "The page could not be read." } }

    var pages: [Room: BrowsePage] = [:]
    var resuming: [Room: [ContinueItem]] = [:]
    var failing: Set<Room> = []

    private let lock = NSLock()
    private var pageReads: [Room: Int] = [:]
    private var resumingReads: [Room: Int] = [:]

    func pageCount(_ room: Room) -> Int { lock.withLock { pageReads[room] ?? 0 } }
    func resumingCount(_ room: Room) -> Int { lock.withLock { resumingReads[room] ?? 0 } }

    func page(for room: Room) async throws -> BrowsePage {
        lock.withLock { pageReads[room, default: 0] += 1 }
        if failing.contains(room) { throw Failure() }
        return pages[room] ?? BrowsePage(rows: [], hero: [])
    }

    func rows(for room: Room) async throws -> [BrowseRow] { try await page(for: room).rows }

    func continueWatching(for room: Room) async throws -> [ContinueItem] {
        lock.withLock { resumingReads[room, default: 0] += 1 }
        return resuming[room] ?? []
    }
}

/// The fixture extras, counting the feeds they serve.
@MainActor
final class CountingExtras: HomeExtraSource {
    private let fixtures = FixtureHomeExtras()
    var anilistSignedIn = true
    private(set) var feeds: [String] = []
    private(set) var trackerReads = 0

    func anilist() async -> HomeTrackerState {
        trackerReads += 1
        guard anilistSignedIn else { return HomeTrackerState(signedIn: false) }
        return await fixtures.anilist()
    }
    func mal() async -> HomeTrackerState {
        trackerReads += 1
        return await fixtures.mal()
    }
    func addons() async -> [(base: String, name: String)] { await fixtures.addons() }
    func catalogs(base: String, addon: String) async -> [HomeAddonCatalog]? { await fixtures.catalogs(base: base, addon: addon) }
    func feed(_ catalog: HomeAddonCatalog) async -> [Meta] {
        feeds.append(catalog.key)
        return await fixtures.feed(catalog)
    }
}

private func meta(_ id: String, type: String = "movie") -> Meta { Meta(id: id, type: type, name: id.uppercased()) }

private func row(_ key: String, _ ids: [String], shape: TileShape = .poster, type: String = "movie") -> BrowseRow {
    BrowseRow(key: key, title: "Row \(key)", metas: ids.map { meta($0, type: type) }, shape: shape)
}

private func resume(_ id: String) -> ContinueItem {
    ContinueItem(id: id, type: "movie", name: id, poster: nil, background: nil, logo: nil, season: nil, episode: nil, progress: 0.5, lastWatched: nil)
}

// MARK: Tests

@MainActor
final class HomeLayoutLoaderTests: XCTestCase {
    private var homeRows: [BrowseRow] {
        [
            row("bp-top10", ["t1", "t2", "t3", "t4", "t5", "t6"], shape: .rank),
            row("trending", ["a", "b", "a", "c"]),
            row("services", ["service:one", "service:two"], shape: .brand, type: "service"),
            row("empty", []),
        ]
    }

    private func source() -> CountingBrowseSource {
        let s = CountingBrowseSource()
        s.pages[.home] = BrowsePage(rows: homeRows, hero: [])
        s.pages[.movies] = BrowsePage(rows: [row("bp-top10", ["m1", "m2"], shape: .rank), row("theaters", ["m3"])], hero: [])
        s.pages[.anime] = BrowsePage(rows: [row("airing", ["k1", "k2"])], hero: [meta("slide1"), meta("slide2")])
        s.resuming[.home] = [resume("cw1"), resume("cw2")]
        return s
    }

    private func loader(_ source: CountingBrowseSource, extras: HomeExtraSource? = nil, store: HomeLayoutStore,
                        classic: Bool = false, hidden: Set<HomeRoom> = [], marked: MarkBox? = nil) -> HomeLayoutLoader {
        HomeLayoutLoader(HomeLayoutLoader.Dependencies(
            source: source, extras: extras ?? CountingExtras(), store: store, profileId: "p1",
            classicHome: { classic }, hiddenRooms: { hidden },
            refreshMarks: { metas in
                if let marked { marked.metas = metas }
            },
            listensToEngine: false))
    }

    final class MarkBox { var metas: [Meta] = [] }

    private func content(_ loader: HomeLayoutLoader, file: StaticString = #filePath, line: UInt = #line) -> HomeContent {
        guard case .loaded(let content) = loader.phase else {
            XCTFail("not loaded: \(loader.phase)", file: file, line: line)
            return HomeContent()
        }
        return content
    }

    /// Waits for the store's change to reach the loader (it hops through a Task).
    private func settle(_ until: () -> Bool) async {
        for _ in 0..<200 where !until() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: The default layout

    func testTheDefaultLayoutIsWhatTheFeedShows() async {
        let s = source()
        let marks = MarkBox()
        let l = loader(s, store: HomeLayoutStore(storage: MemoryHomeLayoutStorage()), marked: marks)
        await l.load(quiet: false)
        let c = content(l)
        XCTAssertEqual(c.resuming.map(\.id), ["cw1", "cw2"])
        XCTAssertEqual(c.items.first?.id, HomeLayout.defaultContinueWatchingId)
        // Engine order, empty rows left out, duplicates within a row removed (PhoneFeedView's uniquedById).
        XCTAssertEqual(c.rows.map(\.key), ["bp-top10", "trending", "services"])
        XCTAssertEqual(c.rows[1].metas.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(c.rows[0].shape, .rank)
        XCTAssertEqual(c.rows[0].title, "Row bp-top10")
        // No page hero on Home: the first row's first five.
        XCTAssertEqual(c.hero.map(\.id), ["t1", "t2", "t3", "t4", "t5"])
        XCTAssertEqual(c.skipped.map(\.reason), [], "the room's empty row is not a skipped spec")
        // Only Home was read, once each.
        XCTAssertEqual(s.pageCount(.home), 1)
        XCTAssertEqual(s.pageCount(.movies) + s.pageCount(.shows) + s.pageCount(.anime), 0)
        XCTAssertEqual(s.resumingCount(.home), 1)
        // Marks for the titles, never the band tiles.
        XCTAssertFalse(marks.metas.contains { $0.type == "service" })
        XCTAssertTrue(marks.metas.contains { $0.id == "t1" })
    }

    func testClassicHomeHasNoAutoHero() async {
        let l = loader(source(), store: HomeLayoutStore(storage: MemoryHomeLayoutStorage()), classic: true)
        await l.load(quiet: false)
        XCTAssertEqual(content(l).hero, [])
    }

    // MARK: Reads

    func testEachRoomPageIsReadOncePerPass() async {
        let s = source()
        let store = HomeLayoutStore(storage: MemoryHomeLayoutStorage())
        store.save(HomeLayout(hero: .source(.engineRow(room: .movies, key: "theaters")), rows: [
            HomeRowSpec(id: "1", source: .engineRow(room: .movies, key: "bp-top10")),
            HomeRowSpec(id: "2", source: .engineRoom(.home)),
            HomeRowSpec(id: "3", source: .engineRow(room: .home, key: "trending")),
            HomeRowSpec(id: "4", source: .engineRoom(.movies)),
            HomeRowSpec(id: "5", source: .continueWatching(.home)),
        ]), for: "p1")
        let l = loader(s, store: store)
        await l.load(quiet: false)
        XCTAssertEqual(s.pageCount(.home), 1)
        XCTAssertEqual(s.pageCount(.movies), 1)
        XCTAssertEqual(s.pageCount(.shows), 0)
        XCTAssertEqual(s.pageCount(.anime), 0)
        XCTAssertEqual(l.passes, 1)
        await l.load(quiet: true)
        XCTAssertEqual(s.pageCount(.home), 2, "one more read per pass, not per row")
        let c = content(l)
        XCTAssertEqual(c.hero.map(\.id), ["m3"])
        // Movies' top 10 placed alone, Home's trending placed alone below its room (not twice),
        // then the rest of Movies.
        XCTAssertEqual(c.items.map(\.id), ["1", "2/bp-top10", "2/services", "3", "4/theaters", "5"])
    }

    func testTheSameSourceTwiceShowsOnce() {
        let layout = HomeLayout(rows: [
            HomeRowSpec(id: "a", source: .engineRow(room: .home, key: "trending")),
            HomeRowSpec(id: "b", source: .engineRow(room: .home, key: "trending")),
            HomeRowSpec(id: "c", source: .continueWatching(.home)),
            HomeRowSpec(id: "d", source: .continueWatching(.home)),
        ])
        var snapshot = HomeSourceSnapshot()
        snapshot.pages[.home] = BrowsePage(rows: homeRows, hero: [])
        snapshot.resuming[.home] = [resume("cw1")]
        let c = HomeLayoutLoader.assemble(layout, snapshot: snapshot)
        XCTAssertEqual(c.items.map(\.id), ["a", "c"])
        XCTAssertEqual(c.skipped.map(\.specId), ["b", "d"])
        XCTAssertEqual(c.skipped.map(\.reason), [.duplicate, .duplicate])
    }

    // MARK: Gone sources

    func testRowsWhoseSourceIsGoneAreKeptAndSkipped() async {
        let raw = """
        {"version":1,"layout":{"hero":{"kind":"auto"},"rows":[
          {"id":"gone","source":{"kind":"engineRow","room":"home","key":"trakt-recommended"},"savedTitle":"Trakt picks"},
          {"id":"new","source":{"kind":"spotify"}},
          {"id":"addon","source":{"kind":"addonCatalog","base":"https://removed.invalid","catalog":"top"}},
          {"id":"cw","source":{"kind":"continueWatching","room":"movies"}},
          {"id":"home","source":{"kind":"engineRoom","room":"home"}}
        ]}}
        """
        let storage = MemoryHomeLayoutStorage()
        try? storage.set(raw, for: HomeLayoutStore.key(for: "p1"))
        let savedStore = HomeLayoutStore(storage: storage)
        let l = loader(source(), store: savedStore)
        await l.load(quiet: false)
        let c = content(l)
        XCTAssertEqual(c.rows.map(\.key), ["bp-top10", "trending", "services"])
        XCTAssertEqual(c.skipped.map(\.specId), ["gone", "new", "addon", "cw"])
        XCTAssertTrue(c.skipped.allSatisfy { $0.reason == .unavailable })
        XCTAssertEqual(c.skipped.first?.title, "Trakt picks")
        // The layout itself is untouched: every row is still in it.
        XCTAssertEqual(savedStore.layout(for: "p1").rows.count, 5)
        XCTAssertEqual(l.layout.rows.count, 5)
    }

    func testAFailedPageSkipsItsRowsAndKeepsTheRest() async {
        let s = source()
        s.failing = [.movies]
        let store = HomeLayoutStore(storage: MemoryHomeLayoutStorage())
        store.update(for: "p1") { $0.insert(.engineRow(room: .movies, key: "bp-top10"), at: 0) }
        let l = loader(s, store: store)
        await l.load(quiet: false)
        let c = content(l)
        XCTAssertEqual(c.rows.map(\.key), ["bp-top10", "trending", "services"])
        XCTAssertEqual(c.items.first?.source, .continueWatching(.home))
        XCTAssertEqual(c.skipped.count, 1)
        guard case .failed = c.skipped.first?.reason else { return XCTFail("expected a failed row") }
    }

    func testEverythingFailingIsAFailedPhaseButAQuietPassKeepsThePage() async {
        let s = source()
        let l = loader(s, store: HomeLayoutStore(storage: MemoryHomeLayoutStorage()))
        await l.load(quiet: false)
        s.failing = [.home]
        s.resuming = [:]
        await l.load(quiet: true)
        guard case .loaded = l.phase else { return XCTFail("a quiet failure keeps what is on screen") }
        await l.load(quiet: false)
        guard case .failed = l.phase else { return XCTFail("expected the failed phase") }
    }

    func testHiddenRoomsAreNotReadAndTheirRowsAreSkipped() async {
        let s = source()
        let store = HomeLayoutStore(storage: MemoryHomeLayoutStorage())
        store.update(for: "p1") {
            $0.insert(.engineRoom(.anime))
            $0.insert(.anilistList(railKey: "watching"))
        }
        let l = loader(s, store: store, hidden: [.anime])
        await l.load(quiet: false)
        XCTAssertEqual(s.pageCount(.anime), 0)
        XCTAssertEqual(content(l).skipped.map(\.reason), [.unavailable, .unavailable])
    }

    // MARK: Trackers and addons

    func testTrackerAndAddonRows() async {
        let extras = CountingExtras()
        let store = HomeLayoutStore(storage: MemoryHomeLayoutStorage())
        store.save(HomeLayout(rows: [
            HomeRowSpec(id: "al", source: .anilistList(railKey: "watching")),
            HomeRowSpec(id: "al-empty", source: .anilistList(railKey: "dropped")),
            HomeRowSpec(id: "mal", source: .malList(railKey: "watching")),
            HomeRowSpec(id: "pop", source: .addonCatalog(base: FixtureHomeExtras.addonBase, catalog: "popular"), title: "Addon picks"),
        ]), for: "p1")
        let l = loader(source(), extras: extras, store: store)
        await l.load(quiet: false)
        let c = content(l)
        XCTAssertEqual(c.items.map(\.id), ["al", "pop"])
        XCTAssertEqual(c.rows.last?.title, "Addon picks")
        XCTAssertEqual(c.rows.first?.metas.count, 6)
        XCTAssertEqual(c.skipped.map(\.specId), ["al-empty", "mal"])
        XCTAssertEqual(c.skipped.map(\.reason), [.empty, .unavailable])
        XCTAssertEqual(extras.feeds, ["popular"], "only the catalogs on the layout are read")
    }

    func testTheSourcePickerListsEverything() async {
        let l = loader(source(), store: HomeLayoutStore(storage: MemoryHomeLayoutStorage()))
        await l.loadAllSources()
        let entries = l.entries
        let ids = Set(entries.map(\.id))
        XCTAssertTrue(ids.contains(HomeRowSource.engineRow(room: .movies, key: "theaters").identity))
        XCTAssertTrue(ids.contains(HomeRowSource.engineRow(room: .anime, key: "airing").identity))
        XCTAssertTrue(ids.contains(HomeRowSource.addonCatalog(base: FixtureHomeExtras.addonBase, catalog: "featured").identity))
        XCTAssertFalse(ids.contains(HomeRowSource.continueWatching(.movies).identity), "Movies has no Continue Watching")
        XCTAssertEqual(entries.first { $0.source == .anilistList(railKey: "watching") }?.availability, .available)
        XCTAssertEqual(entries.first { $0.source == .malList(railKey: "watching") }?.availability, .needsSignIn)
        XCTAssertEqual(Set(entries.filter { $0.group == .anilist }.map(\.id)).count, HomeSourceRegistry.anilistRails.count)
    }

    // MARK: Options

    func testOptionsLimitAndNumerals() {
        let rows = HomeLayout(rows: [
            HomeRowSpec(id: "t", source: .engineRow(room: .home, key: "trending"), options: HomeRowOptions(shape: .rank, limit: 2)),
            HomeRowSpec(id: "s", source: .engineRow(room: .home, key: "services"), options: HomeRowOptions(shape: .rank)),
            HomeRowSpec(id: "n", source: .engineRow(room: .home, key: "bp-top10"), title: "Best", options: HomeRowOptions(shape: .poster)),
        ])
        var snapshot = HomeSourceSnapshot()
        snapshot.pages[.home] = BrowsePage(rows: homeRows, hero: [])
        let c = HomeLayoutLoader.assemble(rows, snapshot: snapshot)
        XCTAssertEqual(c.rows.map(\.shape), [.rank, .brand, .poster], "a band row keeps its tiles")
        XCTAssertEqual(c.rows[0].metas.map(\.id), ["a", "b"])
        XCTAssertEqual(c.rows[2].title, "Best")
    }

    // MARK: Hero

    private func heroSnapshot() -> HomeSourceSnapshot {
        var snapshot = HomeSourceSnapshot()
        snapshot.pages[.home] = BrowsePage(rows: homeRows, hero: [])
        snapshot.pages[.anime] = BrowsePage(rows: [row("airing", ["k1"])], hero: [meta("slide1"), meta("slide2")])
        snapshot.resuming[.home] = [resume("cw1")]
        snapshot.anilist = HomeTrackerState(signedIn: true, rails: [row("watching", ["al1", "al2"])])
        return snapshot
    }

    private func hero(_ hero: HomeHeroSource, rows: [HomeRowSource] = [.continueWatching(.home), .engineRoom(.home)], classic: Bool = false) -> [String] {
        let layout = HomeLayout(hero: hero, rows: rows.map { HomeRowSpec(source: $0) })
        return HomeLayoutLoader.assemble(layout, snapshot: heroSnapshot(), classicHome: classic).hero.map(\.id)
    }

    func testHeroSourceChoice() {
        XCTAssertEqual(hero(.off), [])
        XCTAssertEqual(hero(.auto), ["t1", "t2", "t3", "t4", "t5"])
        XCTAssertEqual(hero(.auto, classic: true), [])
        // A page with hero slides leads with them.
        XCTAssertEqual(hero(.auto, rows: [.engineRoom(.anime), .engineRoom(.home)]), ["slide1", "slide2"])
        XCTAssertEqual(hero(.source(.engineRoom(.anime))), ["slide1", "slide2"])
        XCTAssertEqual(hero(.source(.engineRow(room: .home, key: "trending"))), ["a", "b", "c"])
        XCTAssertEqual(hero(.source(.continueWatching(.home))), ["cw1"])
        XCTAssertEqual(hero(.source(.anilistList(railKey: "watching"))), ["al1", "al2"])
        // A chosen source with no titles (or none at all any more) falls back to Auto; a chosen one
        // shows even on Classic Home.
        XCTAssertEqual(hero(.source(.engineRow(room: .home, key: "gone"))), ["t1", "t2", "t3", "t4", "t5"])
        XCTAssertEqual(hero(.source(.continueWatching(.home)), classic: true), ["cw1"])
        // Band tiles never lead.
        XCTAssertEqual(hero(.source(.engineRow(room: .home, key: "services"))), ["t1", "t2", "t3", "t4", "t5"])
    }

    // MARK: Layout edits and engine events

    func testAnEditThatNeedsNothingNewIsReassembledWithoutARead() async {
        let s = source()
        let store = HomeLayoutStore(storage: MemoryHomeLayoutStorage())
        let l = loader(s, store: store)
        await l.load(quiet: false)
        store.update(for: "p1") { $0.remove(id: HomeLayout.defaultContinueWatchingId) }
        await settle { l.layout.rows.count == 1 }
        XCTAssertEqual(content(l).resuming, [])
        XCTAssertEqual(l.passes, 1)
        // A row from a page not read yet loads quietly.
        store.update(for: "p1") { $0.insert(.engineRow(room: .movies, key: "theaters")) }
        await settle { l.passes == 2 }
        XCTAssertEqual(l.passes, 2)
        XCTAssertEqual(content(l).rows.last?.key, "theaters")
        XCTAssertEqual(s.pageCount(.movies), 1)
    }

    func testAnotherProfilesEditIsIgnored() async {
        let store = HomeLayoutStore(storage: MemoryHomeLayoutStorage())
        let l = loader(source(), store: store)
        await l.load(quiet: false)
        store.update(for: "p2") { $0.rows.removeAll() }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(l.layout, .standard)
        XCTAssertEqual(l.passes, 1)
    }

    func testEngineEventsReloadWhatTheLayoutReads() {
        let home = HomeFetchPlan(layout: .standard)
        XCTAssertTrue(HomeLayoutLoader.reloads(on: "harbor:home-updated", plan: home))
        XCTAssertTrue(HomeLayoutLoader.reloads(on: "harbor:addons-changed", plan: home))
        XCTAssertFalse(HomeLayoutLoader.reloads(on: "harbor:anime-updated", plan: home), "as PhoneFeedView(room: .home)")
        XCTAssertTrue(HomeLayoutLoader.reloads(on: "harbor:cw-dismissed", plan: home))
        let anime = HomeFetchPlan(layout: HomeLayout(rows: [HomeRowSpec(source: .engineRoom(.anime))]))
        XCTAssertTrue(HomeLayoutLoader.reloads(on: "harbor:anime-updated", plan: anime))
        XCTAssertFalse(HomeLayoutLoader.reloads(on: "harbor:home-updated", plan: anime))
    }

    func testFetchPlans() {
        let layout = HomeLayout(hero: .source(.engineRow(room: .shows, key: "x")), rows: [
            HomeRowSpec(source: .continueWatching(.movies)),
            HomeRowSpec(source: .continueWatching(.anime)),
            HomeRowSpec(source: .malList(railKey: "watching")),
            HomeRowSpec(source: .addonCatalog(base: "b", catalog: "c")),
            HomeRowSpec(source: .unknown(.null)),
        ])
        let plan = HomeFetchPlan(layout: layout)
        XCTAssertEqual(plan.rooms, [.shows])
        XCTAssertEqual(plan.resuming, [.anime])
        XCTAssertTrue(plan.mal)
        XCTAssertFalse(plan.anilist)
        XCTAssertEqual(plan.addonCatalogs, ["b": ["c"]])
        XCTAssertTrue(plan.covers(HomeFetchPlan(layout: HomeLayout(rows: [HomeRowSpec(source: .engineRow(room: .shows, key: "y"))]))))
        XCTAssertFalse(plan.covers(HomeFetchPlan(layout: .standard)))
        XCTAssertEqual(HomeFetchPlan(layout: layout, hiddenRooms: [.anime, .shows]).rooms, [])
    }
}
