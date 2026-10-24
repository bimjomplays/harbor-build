import XCTest
@testable import HarborPhone

/// The phone Library's pure parts (PhoneLibraryQuery) and its fixture model: the History split,
/// type and title filters, the three sorts, what a swipe removes, and the offline model's state.
@MainActor
final class PhoneLibraryTests: XCTestCase {
    private func make(_ id: String, _ type: String = "movie", name: String, year: String? = nil, date: Double? = nil,
                       group: String? = nil, progress: Double? = nil, watched: Bool? = nil) -> LibraryModel.Entry {
        let meta = Meta(id: id, type: type, name: name, poster: nil, background: nil, logo: nil, description: nil,
                        releaseInfo: year, releaseDate: nil, inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil,
                        genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil)
        return LibraryModel.Entry(key: group.map { "\($0):\(id)" } ?? id, meta: meta, date: date, group: group,
                                  progress: progress, season: nil, episode: nil, watched: watched)
    }

    private func names(_ sections: [LibraryModel.Section]) -> [String] {
        sections.flatMap { $0.items.map(\.meta.name) }
    }

    private func names(_ feed: LibraryModel.Feed) -> [String] { names(feed.sections) }

    private func fixtureFeed(_ tab: String, type: String = "all", sort: String = "recent", query: String = "") -> LibraryModel.Feed {
        PhoneLibraryQuery.feed(tab: tab, entries: PhoneLibraryFixtures.entries(tab: tab), type: type, sort: sort, query: query)
    }

    // MARK: Filters

    func testSegmentsMapToEngineTabs() {
        XCTAssertEqual(PhoneLibraryFilter.segments.map(\.engineTab), ["library", "watchlist", "history", "history"])
        XCTAssertEqual(PhoneLibraryFilter(engineTab: nil), .saved)
        XCTAssertEqual(PhoneLibraryFilter(engineTab: "history"), .inProgress, "a kept History opens on In progress")
        XCTAssertEqual(PhoneLibraryFilter(engineTab: "favorites"), .tab("favorites"))
        XCTAssertFalse(PhoneLibraryFilter.tab("lists").isSegment)
        XCTAssertTrue(PhoneLibraryFilter.watched.splitsHistory)
        XCTAssertFalse(PhoneLibraryFilter.saved.splitsHistory)
    }

    func testInProgressIsStartedNotFinishedNotWatched() {
        XCTAssertTrue(PhoneLibraryQuery.isInProgress(make("a", name: "A", progress: 0.4)))
        XCTAssertFalse(PhoneLibraryQuery.isInProgress(make("b", name: "B", progress: 0)))
        XCTAssertFalse(PhoneLibraryQuery.isInProgress(make("c", name: "C", progress: 1)))
        XCTAssertFalse(PhoneLibraryQuery.isInProgress(make("d", name: "D")))
        XCTAssertFalse(PhoneLibraryQuery.isInProgress(make("e", name: "E", progress: 0.5, watched: true)))
        XCTAssertFalse(PhoneLibraryQuery.isInProgress(make("f", name: "F", progress: 0.5), watchedOverride: true),
                       "marked watched here moves it to Watched")
        XCTAssertTrue(PhoneLibraryQuery.isInProgress(make("g", name: "G", progress: 0.5, watched: true), watchedOverride: false))
    }

    func testHistorySplitsIntoInProgressAndWatched() {
        let history = fixtureFeed("history").sections
        XCTAssertEqual(names(PhoneLibraryQuery.sections(history, filter: .inProgress, removed: [])), ["The Holdovers", "Ripley"])
        XCTAssertEqual(names(PhoneLibraryQuery.sections(history, filter: .watched, removed: [])),
                       ["Anatomy of a Fall", "Civil War", "Severance"])
        // Dismissed from Continue Watching leaves In progress; a watched override crosses over.
        XCTAssertEqual(names(PhoneLibraryQuery.sections(history, filter: .inProgress, removed: [], dismissed: ["lib-ripley"])),
                       ["The Holdovers"])
        XCTAssertEqual(names(PhoneLibraryQuery.sections(history, filter: .watched, removed: [],
                                                        watchedOverrides: ["lib-holdovers": true])).first, "The Holdovers")
    }

    func testRemovedEntriesAndEmptySectionsDrop() {
        let feed = fixtureFeed("library")
        let less = PhoneLibraryQuery.sections(feed.sections, filter: .saved, removed: ["lib-past-lives"])
        XCTAssertEqual(names(less), ["The Bear", "Dune: Part Two", "Poor Things"])
        XCTAssertEqual(less.first?.total, 3, "the section's total drops with what was taken out")
        let all: Set<String> = Set(feed.sections.flatMap { $0.items.map(\.key) })
        XCTAssertTrue(PhoneLibraryQuery.sections(feed.sections, filter: .saved, removed: all).isEmpty)
        XCTAssertTrue(PhoneLibraryQuery.sections(fixtureFeed("watchlist").sections, filter: .inProgress, removed: []).isEmpty)
    }

    func testTypeAndTitleFilter() {
        XCTAssertEqual(names(fixtureFeed("library", type: "movie")), ["Past Lives", "Dune: Part Two", "Poor Things"])
        XCTAssertEqual(names(fixtureFeed("library", type: "series")), ["The Bear"])
        XCTAssertEqual(names(fixtureFeed("library", query: "  dune ")), ["Dune: Part Two"])
        XCTAssertEqual(names(fixtureFeed("library", query: "THINGS")), ["Poor Things"])
        let none = fixtureFeed("library", type: "series", query: "dune")
        XCTAssertTrue(none.sections.isEmpty)
        XCTAssertEqual(none.matched, 0)
        XCTAssertEqual(none.total, 4, "total counts the tab before the filters")
        XCTAssertEqual(none.counts.movie, 3)
        XCTAssertEqual(none.counts.series, 1)
    }

    func testGroupScopesTheFeed() {
        let entries = PhoneLibraryFixtures.entries(tab: "lists") + [make("x", name: "Elsewhere", group: "other")]
        let feed = PhoneLibraryQuery.feed(tab: "lists", entries: entries, type: "all", sort: "recent", query: "",
                                          groups: PhoneLibraryFixtures.listGroups, group: "weekend")
        XCTAssertEqual(Set(names(feed)), ["Dune: Part Two", "Shōgun"])
        XCTAssertEqual(feed.groups.first?.count, 2)
    }

    // MARK: Sorts

    func testRecentIsNewestFirst() {
        XCTAssertEqual(names(fixtureFeed("library")), ["Past Lives", "The Bear", "Dune: Part Two", "Poor Things"])
        XCTAssertEqual(fixtureFeed("library").sections.first?.label, "")
        let undated = PhoneLibraryQuery.feed(tab: "library", entries: [make("a", name: "A"), make("b", name: "B", date: 5)],
                                             type: "all", sort: "recent", query: "")
        XCTAssertEqual(names(undated), ["B", "A"], "an entry with no date goes last")
    }

    func testTitleSortIgnoresCaseAndDiacritics() {
        XCTAssertEqual(names(fixtureFeed("library", sort: "title")), ["Dune: Part Two", "Past Lives", "Poor Things", "The Bear"])
        let mixed = [make("1", name: "éclair"), make("2", name: "Zebra"), make("3", name: "apple"), make("4", name: "Echo")]
        let feed = PhoneLibraryQuery.feed(tab: "library", entries: mixed, type: "all", sort: "title", query: "")
        XCTAssertEqual(names(feed), ["apple", "Echo", "éclair", "Zebra"])
        XCTAssertEqual(feed.sections.first?.label, "A to Z")
    }

    func testYearSortIsNewestFirst() {
        let feed = fixtureFeed("library", sort: "year")
        XCTAssertEqual(feed.sections.first?.label, "By year")
        let years = feed.sections.flatMap { $0.items.map { PhoneLibraryQuery.releaseYear($0.meta) } }
        XCTAssertEqual(years, years.sorted(by: >))
        XCTAssertEqual(names(feed).first, "Dune: Part Two")
        XCTAssertEqual(names(feed).last, "The Bear")
        XCTAssertEqual(feed.years, true)
    }

    func testReleaseYear() {
        XCTAssertEqual(PhoneLibraryQuery.releaseYear(make("a", name: "A", year: "2019–2023").meta), 2019)
        XCTAssertEqual(PhoneLibraryQuery.releaseYear(make("b", name: "B", year: "19").meta), 0)
        XCTAssertEqual(PhoneLibraryQuery.releaseYear(make("c", name: "C").meta), 0)
    }

    func testFailedFeedIsAnError() {
        let feed = PhoneLibraryQuery.feed(tab: "library", entries: PhoneLibraryFixtures.entries(tab: "library"),
                                          type: "all", sort: "recent", query: "", failed: true)
        XCTAssertEqual(feed.status, "error")
        XCTAssertTrue(feed.sections.isEmpty)
    }

    /// A history page with no title in progress, more pages to come: In progress keeps paging
    /// instead of saying "Nothing here yet."; on the last page it is empty; an error stays an error.
    func testSplitPageWithNoMatchKeepsPaging() {
        let entries = (0..<60).map { make("w\($0)", name: "Watched \($0)", progress: 1) }
        var feed = PhoneLibraryQuery.feed(tab: "history", entries: entries, type: "all", sort: "title", query: "")
        feed.hasMore = true
        XCTAssertTrue(PhoneLibraryQuery.sections(feed.sections, filter: .inProgress, removed: []).isEmpty)
        XCTAssertEqual(PhoneLibraryQuery.nothingShown(status: feed.status, hasMore: feed.hasMore), .paging)
        XCTAssertEqual(PhoneLibraryQuery.nothingShown(status: feed.status, hasMore: false), .empty)
        XCTAssertEqual(PhoneLibraryQuery.nothingShown(status: "error", hasMore: true), .error)
        XCTAssertEqual(PhoneLibraryQuery.nothingShown(status: "error", hasMore: false), .error)
    }

    // MARK: Remove

    func testRemovalPerView() {
        let plain = make("a", name: "A")
        XCTAssertEqual(PhoneLibraryQuery.removal(for: .saved, entry: plain), .watchlist)
        XCTAssertEqual(PhoneLibraryQuery.removal(for: .watchlist, entry: plain), .watchlist)
        XCTAssertEqual(PhoneLibraryQuery.removal(for: .inProgress, entry: plain), .continueWatching)
        XCTAssertNil(PhoneLibraryQuery.removal(for: .watched, entry: plain))
        XCTAssertEqual(PhoneLibraryQuery.removal(for: .tab("lists"), entry: make("a", name: "A", group: "weekend")), .list("weekend"))
        XCTAssertNil(PhoneLibraryQuery.removal(for: .tab("lists"), entry: plain))
        XCTAssertEqual(PhoneLibraryQuery.removal(for: .tab("favorites"), entry: plain), .favorite)
        XCTAssertNil(PhoneLibraryQuery.removal(for: .tab("trakt"), entry: plain))
        XCTAssertNil(PhoneLibraryQuery.removal(for: .tab("media-servers"), entry: plain))
    }

    // MARK: Offline model

    func testOfflineModelSelectsSortsAndFilters() {
        let model = PhoneLibraryModel(tab: nil, offline: true)
        XCTAssertEqual(model.filter, .saved)
        XCTAssertEqual(names(model.sections(watchedOverrides: [:], dismissed: [])), ["Past Lives", "The Bear", "Dune: Part Two", "Poor Things"])

        model.set(sort: "title")
        XCTAssertEqual(names(model.sections(watchedOverrides: [:], dismissed: [])), ["Dune: Part Two", "Past Lives", "Poor Things", "The Bear"])

        model.set(type: "series")
        XCTAssertTrue(model.narrowed)
        XCTAssertEqual(names(model.sections(watchedOverrides: [:], dismissed: [])), ["The Bear"])
        model.clearFilters()
        XCTAssertFalse(model.narrowed)
        XCTAssertEqual(names(model.sections(watchedOverrides: [:], dismissed: [])).count, 4)
        XCTAssertEqual(model.sort, "title", "Clear filters keeps the sort")

        model.set(sort: "recent")
        model.select(.watched)
        XCTAssertEqual(model.filter.engineTab, "history")
        XCTAssertEqual(names(model.sections(watchedOverrides: [:], dismissed: [])), ["Anatomy of a Fall", "Civil War", "Severance"])
        model.select(.inProgress)
        XCTAssertEqual(names(model.sections(watchedOverrides: [:], dismissed: [])), ["The Holdovers", "Ripley"])

        XCTAssertEqual(model.menuTabs.map(\.id), ["lists", "favorites"])
        model.select(.tab("lists"))
        XCTAssertEqual(model.label(of: model.filter), "My Lists")
        XCTAssertEqual(model.feed?.groups.map(\.id), ["weekend"])
    }

    func testOfflineFailingModelShowsError() {
        let model = PhoneLibraryModel(tab: "library", offline: true, failing: true)
        XCTAssertEqual(model.feed?.status, "error")
        XCTAssertTrue(model.sections(watchedOverrides: [:], dismissed: []).isEmpty)
    }

    func testOfflineRemoveTakesTheRowAway() async {
        let model = PhoneLibraryModel(tab: "favorites", offline: true)
        let rows = model.sections(watchedOverrides: [:], dismissed: []).flatMap(\.items)
        XCTAssertEqual(rows.map(\.meta.name), ["Poor Things"])
        guard let first = rows.first else { return }
        await model.remove(first)
        XCTAssertTrue(model.sections(watchedOverrides: [:], dismissed: []).isEmpty)
        await model.reload(force: true)
        XCTAssertEqual(model.sections(watchedOverrides: [:], dismissed: []).flatMap(\.items).count, 1,
                       "a reload reads the fixtures again")
    }

    func testWatchedHasNoRemove() async {
        let model = PhoneLibraryModel(tab: "history", offline: true)
        model.select(.watched)
        let rows = model.sections(watchedOverrides: [:], dismissed: []).flatMap(\.items)
        guard let first = rows.first else { return XCTFail("no watched rows") }
        await model.remove(first)
        XCTAssertEqual(model.sections(watchedOverrides: [:], dismissed: []).flatMap(\.items).count, rows.count)
    }

    // MARK: Stats fixture

    func testFixtureStatsFillEveryCard() {
        let s = PhoneLibraryFixtures.stats
        XCTAssertNotEqual(s.source, "empty")
        XCTAssertFalse(s.topTitles.isEmpty)
        XCTAssertFalse(s.topActors.isEmpty)
        XCTAssertFalse(s.topGenres.isEmpty)
        XCTAssertEqual(s.heatWeeks.count, 53)
        XCTAssertTrue(s.heatWeeks.allSatisfy { $0.count == 7 })
        XCTAssertTrue(s.heatWeeks.joined().allSatisfy { (0...4).contains($0.level) })
    }
}
