import Combine
import SwiftUI

/// The phone Library's state over the shared `LibraryModel` (the TV Library's model: tabs, filters,
/// sort, paging, all through libraryRoom.feed). It adds what the phone shows differently: the four
/// segments (History split into In progress and Watched), grid or list, and the swipe's Remove,
/// which takes a row away at once and reads the feed again behind it. Under `--fixtures` (without
/// `live`) the same feed is built from PhoneLibraryFixtures by `PhoneLibraryQuery.feed`.
@MainActor
final class PhoneLibraryModel: ObservableObject {
    enum Layout: String { case grid, list }

    static let layoutKey = "harbor.phone.library.layout"

    let offline: Bool
    /// `--phone-library-fail`: the fixture read fails, for the error plate's test.
    private let failing: Bool
    let library: LibraryModel

    @Published private(set) var filter: PhoneLibraryFilter
    /// Entry keys removed here; the rows go before the engine's next feed lands.
    @Published private(set) var removed: Set<String> = []
    @Published var layout: Layout {
        didSet { try? Prefs.set(layout.rawValue, for: Self.layoutKey) }
    }

    // The fixture library's own filter state (the engine keeps it in LibraryModel).
    @Published private var fixtureFeed: LibraryModel.Feed?
    @Published private var fixtureType = "all"
    @Published private var fixtureSort = "recent"
    @Published private var fixtureQuery = ""
    @Published private var fixtureGroup: String?

    private var forward: AnyCancellable?
    private var settled: AnyCancellable?
    private var endInView = false
    /// The feed's `shown` when the last page was asked for: a page that failed is not asked again
    /// until the end leaves the screen and comes back.
    private var pagedAt: Int?

    init(tab: String?, offline: Bool, failing: Bool = false) {
        let start = PhoneLibraryFilter(engineTab: tab)
        let model = LibraryModel(tab: start.engineTab)
        // History as Posters (one card per title, its latest progress): the split needs a title once.
        model.episodes = false
        library = model
        filter = start
        self.offline = offline
        self.failing = failing
        layout = Layout(rawValue: Prefs.get(String.self, for: Self.layoutKey) ?? "") ?? .grid
        if offline {
            rebuildFixture()
        } else {
            forward = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            settled = model.$loading.sink { [weak self] busy in
                guard !busy else { return }
                Task { @MainActor in self?.pageIfNeeded() }
            }
        }
    }

    // MARK: State the view reads

    var tabs: [LibraryModel.Tab] { offline ? PhoneLibraryFixtures.tabs : library.tabs }
    var feed: LibraryModel.Feed? { offline ? fixtureFeed : library.shownFeed }
    var loading: Bool { offline ? false : library.loading }
    var refreshing: Bool { offline ? false : library.refreshing }
    var type: String { offline ? fixtureType : library.type }
    var sort: String { offline ? fixtureSort : library.sort }
    var flat: Bool { offline ? true : library.flat }
    var group: String? { offline ? fixtureGroup : library.group }
    var query: String { offline ? fixtureQuery : library.query }
    var ownedSort: String { library.ownedSort }
    var sortDir: String { library.sortDir }
    /// Media Servers sorts by its own keys and direction (bp-library ownedTab).
    var ownedTab: Bool { filter.engineTab == "media-servers" }

    /// A type, group or search narrows the view (the empty copy says "No matches").
    var narrowed: Bool {
        type != "all" || group != nil || !query.isEmpty || (!offline && (library.library != nil || !library.genres.isEmpty))
    }

    /// The sections on screen: the feed's, split and less what was removed here.
    func sections(watchedOverrides: [String: Bool], dismissed: Set<String>) -> [LibraryModel.Section] {
        guard let feed else { return [] }
        return PhoneLibraryQuery.sections(feed.sections, filter: filter, removed: removed,
                                          watchedOverrides: watchedOverrides, dismissed: dismissed)
    }

    /// The name of a menu tab (the engine's label, as the TV's chip prints it).
    func label(of filter: PhoneLibraryFilter) -> String {
        if filter.isSegment { return filter.label }
        return T(tabs.first { $0.id == filter.engineTab }?.label ?? filter.engineTab)
    }

    /// The engine tabs past the four segments: My Lists, Favorites and whatever is connected.
    var menuTabs: [LibraryModel.Tab] { tabs.filter { !PhoneLibraryFilter.segmentTabs.contains($0.id) } }

    // MARK: Loading

    func start() async {
        guard !offline else { return }
        await library.start()
        // A kept tab the engine no longer offers (a service disconnected) fell back to the first tab.
        if library.tab != filter.engineTab { filter = PhoneLibraryFilter(engineTab: library.tab) }
    }

    func reload(force: Bool) async {
        removed = []
        if offline {
            rebuildFixture()
        } else {
            await library.load(force: force)
        }
    }

    func select(_ next: PhoneLibraryFilter) {
        guard next != filter else { return }
        let sameTab = next.engineTab == filter.engineTab
        filter = next
        removed = []
        pagedAt = nil
        if offline {
            if !sameTab {
                fixtureType = "all"
                fixtureQuery = ""
                fixtureGroup = nil
            }
            rebuildFixture()
        } else if !sameTab {
            library.select(tab: next.engineTab)
        }
    }

    func set(type t: String) {
        if offline { fixtureType = t; rebuildFixture() } else { library.set(type: t) }
    }

    func set(sort s: String) {
        if offline { fixtureSort = s; rebuildFixture() } else { library.set(sort: s) }
    }

    func set(group g: String?) {
        if offline { fixtureGroup = g; rebuildFixture() } else { library.set(group: g) }
    }

    func search(_ q: String) {
        if offline { fixtureQuery = q; rebuildFixture() } else { library.search(q) }
    }

    /// "Clear filters" under No matches: type, group, search (and Media Servers' library and genres) in one read.
    func clearFilters() {
        if offline {
            fixtureType = "all"
            fixtureGroup = nil
            fixtureQuery = ""
            rebuildFixture()
        } else {
            library.type = "all"
            library.group = nil
            library.library = nil
            library.genres = []
            // search's read starts the feed over at its first page.
            library.search("")
        }
    }

    func toggleFlat() { if !offline { library.toggleFlat() } }
    func set(ownedSort k: String) { if !offline { library.set(ownedSort: k) } }
    func set(sortDir d: String) { if !offline { library.set(sortDir: d) } }

    private func rebuildFixture() {
        let tab = filter.engineTab
        fixtureFeed = PhoneLibraryQuery.feed(tab: tab, entries: PhoneLibraryFixtures.entries(tab: tab), type: fixtureType,
                                             sort: fixtureSort, query: fixtureQuery,
                                             groups: tab == "lists" ? PhoneLibraryFixtures.listGroups : [],
                                             group: fixtureGroup, failed: failing)
    }

    // MARK: Paging

    /// The grid's foot came into view or left it.
    func setEndInView(_ inView: Bool) {
        endInView = inView
        if !inView { pagedAt = nil }
        pageIfNeeded()
    }

    /// The next 60 while the foot is on screen, once per page (a split view can show nothing from
    /// a whole page, and the foot then stays in view while the next one is read).
    private func pageIfNeeded() {
        guard !offline, endInView, !library.loading, let f = library.shownFeed, f.hasMore, pagedAt != f.shown else { return }
        pagedAt = f.shown
        library.more()
    }

    // MARK: Remove

    /// The swipe's Remove: the row goes at once, the engine action runs, and the feed is read
    /// again; a failed action puts the row back.
    func remove(_ entry: LibraryModel.Entry) async {
        guard let kind = PhoneLibraryQuery.removal(for: filter, entry: entry), !removed.contains(entry.key) else { return }
        removed.insert(entry.key)
        let meta = entry.meta
        let actions = PhoneTitleActions.shared
        var ok = true
        switch kind {
        case .watchlist:
            await actions.toggleSaved(meta, current: true)
            ok = actions.savedOverride[meta.id] == false
        case .continueWatching:
            await actions.removeFromContinue(meta.id)
            ok = actions.dismissed.contains(meta.id)
            if ok { PhoneToaster.shared.show(T("Removed from Continue Watching")) }
        case .list(let listId):
            ok = await engineToggle("actions.toggleList", [listId, meta])
            PhoneToaster.shared.show(ok ? T("Removed from list") : T("Couldn't update that title"))
        case .favorite:
            let p = ProfilesStore.shared.active
            let noImdb: String? = nil
            ok = await engineToggle("actions.toggleFavorite", [meta, noImdb, p?.id ?? "default"])
            PhoneToaster.shared.show(ok ? T("Removed from favorites") : T("Couldn't update that title"))
        }
        guard ok else {
            removed.remove(entry.key)
            return
        }
        PhoneFeedback.shared.success()
        guard !offline else { return }
        await CardMarksStore.shared.remark()
        await library.load()
    }

    /// A toggle the engine answers with the new state: off is what a remove expects. Under fixtures nothing runs.
    private func engineToggle(_ path: String, _ args: [any Encodable]) async -> Bool {
        guard !offline else { return true }
        let on: Bool? = try? await HarborEngine.shared.call(path, args)
        return on == false
    }
}
