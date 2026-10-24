import SwiftUI

/// Library room (bp-library.tsx): tabs (Saved / Watchlist / History / My Lists / Favorites, plus
/// Trakt / AniList / MyAnimeList / Simkl / Letterboxd when connected), filter rows (group, Media
/// Servers' Library and Genre, type, sort, grouping), search, the library repair panel, and a
/// vertical poster grid in date/title/year sections fed by the engine's use-bp-library port.
@MainActor
final class LibraryModel: ObservableObject {
    struct Tab: Decodable, Identifiable { var id: String; var label: String }
    struct Entry: Decodable, Identifiable {
        var key: String; var meta: Meta; var date: Double?; var group: String?
        var progress: Double?; var season: Int?; var episode: Int?; var watched: Bool?
        var id: String { key }
    }
    struct Section: Decodable, Identifiable { var label: String; @LossyArray var items: [Entry]; var total: Int; var id: String { label } }   // lossy: synced library
    /// A filter option (a list, server, library or genre); `count` is bp-library's option count.
    struct Group: Decodable, Identifiable { var id: String; var label: String; var count: Int? }
    struct Counts: Decodable { var all: Int; var movie: Int; var series: Int }
    struct Feed: Decodable {
        var tab: String; var sections: [Section]; var shown: Int; var matched: Int; var total: Int; var hasMore: Bool
        var groups: [Group]; var status: String; var hidden: Int; var signedIn: Bool; var sort: String; var counts: Counts
        /// bp-library `dated` / `years` over the filtered set: the View row and the Year sort.
        var dated: Bool?; var years: Bool?
        /// Media Servers only: the type, server ("" for all), library, genres, owned sort and direction
        /// the engine used (restored from the saved filter preferences when the tab opens).
        var owned: Owned?
        /// bp-library feed.entries.length: the "All" count of the group and Library rows.
        var entries: Int?
        /// Media Servers: bp-library's Library and Genre rows (feed.libraries, genreOptions).
        var libraries: [Group]?
        var genres: [Group]?
        /// Media Servers: title lookups still out (harbor:media-server-details reports each batch).
        var pending: Int?
    }
    struct Owned: Decodable {
        var type: String; var group: String; var sort: String; var dir: String
        var library: String?; var genres: [String]?
    }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var feed: Feed?
    /// The feed of the tab on screen. A tab pick keeps the last tab's feed
    /// until the new one lands (Trakt, Simkl and Letterboxd go to the network): its titles and count
    /// stood under the new tab's chip and could be opened. bp-library's feed is per tab; nil here
    /// shows the spinner instead.
    var shownFeed: Feed? { feed.flatMap { $0.tab == tab ? $0 : nil } }
    /// Starts true: the page's first frame (before `.task` starts the first
    /// read) shows the spinner, so a first read that fails can say so instead of leaving a blank page.
    @Published private(set) var loading = true
    /// (open-items sweep 2) The read running is a Refresh (force), which bp-library's reload shows
    /// as loading again (first = status "loading" with no entries). Other re-reads (a cover closing
    /// runs `.task` again, a filter pick) keep the tab's empty copy: it flashed "Loading…" each time.
    @Published private(set) var refreshing = false
    @Published var tab = "library"
    @Published var type = "all"
    @Published var sort = "recent"
    /// bp-library reads settings.librarySort. Until the first feed says which sort it used (or the
    /// viewer picks one) the engine is asked with none, so it applies the saved one: every visit
    /// used to open on Recent, with that chip lit, whatever the viewer had chosen last time.
    private var sortKnown = false
    @Published var flat = false
    /// bp-library ownedSort / sortDir: Media Servers sorts by its own key (Date added, Title, Year,
    /// Rating, Duration) in a direction, saved per profile with its type and server.
    @Published var ownedSort = "added"
    @Published var sortDir = "desc"
    /// Set when Media Servers is picked: the next feed takes type, server, sort and direction from
    /// the saved preferences (bp-library's [tab] effect) instead of the fresh-tab defaults.
    private var restoreOwned = false
    /// Restore reads still out, and the filter picks made meanwhile: each shows at once
    /// and goes again on top of the restored filters when the read lands (see `pick`).
    private var restoreReads = 0
    private var restorePicks: [@MainActor (LibraryModel) -> Void] = []
    /// bp-library "Episodes / Posters" for History (harbor.history.view).
    @Published var episodes = Prefs.get(String.self, for: "harbor.history.view") == "episodes"
    @Published var group: String?
    /// bp-library library / genres (Media Servers): the server library and the picked genres.
    @Published var library: String?
    @Published var genres: [String] = []
    /// Bumped when a feed read because of harbor:media-server-details lands, so the grid can hand
    /// the ring on if the re-sort took its tile off the page.
    @Published private(set) var detailsLanded = 0
    private var unsubscribe: (() -> Void)?
    @Published var query = ""
    @Published var showFilters = false
    @Published var showSearch = false
    @Published var showRepair = false
    private var limit = 60

    private var profile: (id: String, linked: Bool, authKey: String?) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true, p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey })
    }

    /// bp-view-state useBpPersistedState("libraryTab"): Library opens on the tab it was left on
    /// (ShellViewState). Media Servers restores its saved filters then, as a pick of it does.
    init(tab: String? = nil) {
        if let tab, !tab.isEmpty {
            self.tab = tab
            restoreOwned = tab == "media-servers"
        }
    }

    deinit { unsubscribe?() }

    func start() async {
        // use-bp-library useMediaServerEntries: the feed is read again as media-server details
        // land, so the owned sort (Rating, Duration) and the Genre row pick them up.
        if unsubscribe == nil {
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, _ in
                guard type == "harbor:media-server-details" else { return }
                Task { @MainActor in await self?.detailsArrived() }
            }
        }
        let p = profile
        // Runs again whenever a cover (Detail, Stats) closes: a failed read keeps the tabs on screen
        // instead of emptying the chip row and dropping the viewer back on Saved.
        if let t: [Tab] = try? await HarborEngine.shared.call("libraryRoom.tabs", [p.id, p.linked]) { tabs = t }
        if !tabs.contains(where: { $0.id == tab }) { tab = tabs.first?.id ?? "library" }
        await load()
    }

    /// Only the newest feed request lands. Tabs, filters and "Show more" each start a
    /// load; a slow one (Trakt / Simkl / Letterboxd tabs go to the network) answering after a
    /// quicker, newer one put the old tab's titles under the new tab's chip, and the first to finish
    /// cleared `loading` while the other still ran.
    private var generation = 0
    /// The generation of the last read that got no feed while it was still the
    /// newest (a read a newer one superseded is not a failure: the newer one answers for it).
    private var failedGeneration = -1

    func load(force: Bool = false) async {
        generation += 1
        let mine = generation
        loading = true
        refreshing = force
        defer {
            if mine == generation {
                loading = false
                refreshing = false
            }
        }
        let p = profile
        var fields: [String: AnyJSON] = [
            "tab": .string(tab), "profileId": .string(p.id), "linked": .bool(p.linked), "authKey": p.authKey.map { .string($0) } ?? .null,
            "sort": sortKnown ? AnyJSON.string(sort) : AnyJSON.null, "flat": .bool(flat), "type": .string(type), "query": .string(query), "episodes": .bool(episodes),
            "group": group.map { .string($0) } ?? .null, "limit": .number(Double(limit)), "force": .bool(force),
        ]
        // Media Servers: its own sort and direction, and whether to restore the saved filters.
        let restore: Bool = restoreOwned && tab == "media-servers"
        if restore { restoreReads += 1 }
        defer { if restore { restoreReads -= 1 } }
        fields["ownedSort"] = AnyJSON.string(ownedSort)
        fields["sortDir"] = AnyJSON.string(sortDir)
        fields["restore"] = AnyJSON.bool(restore)
        fields["library"] = library.map { AnyJSON.string($0) } ?? AnyJSON.null
        fields["genres"] = AnyJSON.array(genres.map { AnyJSON.string($0) })
        let input: AnyJSON = .object(fields)
        if let f: Feed = try? await HarborEngine.shared.call("libraryRoom.feed", [input]), mine == generation {
            feed = f
            sort = f.sort
            sortKnown = true
            var restored = false
            if let o = f.owned, f.tab == tab {
                restoreOwned = false
                type = o.type
                group = o.group.isEmpty ? nil : o.group
                let lib: String = o.library ?? ""
                library = lib.isEmpty ? nil : lib
                genres = o.genres ?? []
                ownedSort = o.sort
                sortDir = o.dir
                restored = true
            }
            if restore { finishRestore(restored: restored) }
            await CardMarksStore.shared.refresh(f.sections.flatMap { $0.items.map(\.meta) })
        } else if mine == generation {
            failedGeneration = mine
            if restore { finishRestore(restored: false) }
        }
    }

    /// A filter pick. While the Media Servers restore read is out it shows at once and
    /// is kept for that read: a pick used to start its own read with the fresh-tab defaults for
    /// everything else, which dropped the restore's answer and saved those defaults over the
    /// viewer's server, library and genres.
    private func pick(_ change: @escaping @MainActor (LibraryModel) -> Void) {
        change(self)
        limit = 60
        if restoreOwned && restoreReads > 0 && tab == "media-servers" {
            restorePicks.append(change)
            return
        }
        restoreOwned = false
        Task { await load() }
    }

    /// The restore read landed (or failed): the picks made meanwhile go again on top of
    /// the restored filters (a genre toggles against the saved set) and the feed is read with them.
    /// After a failed read they are already on screen and go through as they are.
    private func finishRestore(restored: Bool) {
        guard !restorePicks.isEmpty else { return }
        let picks = restorePicks
        restorePicks = []
        if restored { for change in picks { change(self) } }
        restoreOwned = false
        limit = 60
        Task { await load() }
    }

    /// bp-library's [tab] effect: a new tab starts unfiltered (group, type and search cleared). The
    /// search used to carry over, filtering the next tab by a title typed for the last one, even
    /// with the search row closed and nothing on screen saying so.
    func select(tab id: String) {
        tab = id; group = nil; library = nil; genres = []; type = "all"; query = ""; limit = 60
        ownedSort = "added"; sortDir = "desc"; restoreOwned = id == "media-servers"; restorePicks = []
        // Loading from this frame on: the new tab has no feed yet (shownFeed), so the page shows
        // the spinner, not the failed-read note, until the load below starts.
        loading = true
        Task { await load() }
    }
    func set(type t: String) { pick { $0.type = t } }
    func set(sort s: String) {
        sort = s; sortKnown = true; limit = 60
        // A feed already in flight (the first one asks with no sort and answers with the saved one)
        // must not land after this pick: it set `sort` back, and the load below then asked for it.
        generation += 1
        let p = profile
        Task { _ = try? await HarborEngine.shared.callJSON("libraryRoom.setSort", [.string(s), .string(p.id), .bool(p.linked)]); await load() }
    }
    func set(ownedSort k: String) { pick { $0.ownedSort = k } }
    func set(sortDir d: String) { pick { $0.sortDir = d } }
    func toggleFlat() { flat.toggle(); Task { await load() } }
    func set(episodes on: Bool) { episodes = on; try? Prefs.set(on ? "episodes" : "posters", for: "harbor.history.view"); Task { await load() } }
    func set(group g: String?) { pick { $0.group = g } }
    func set(library l: String?) { pick { $0.library = l } }
    /// bp-library Genre group: each chip toggles its genre (a title must carry every picked one).
    func toggle(genre g: String) {
        pick { model in
            if let i = model.genres.firstIndex(of: g) { model.genres.remove(at: i) } else { model.genres.append(g) }
        }
    }
    /// A details read is running; a batch landing meanwhile asks for one more after it.
    private var detailsReading = false
    private var detailsAgain = false

    /// A details batch landed: read the Media Servers feed again with the same filters and page.
    /// One read at a time: a big library's read can outlast the gap between batches,
    /// and each batch used to start another whole-feed read on the engine behind the last one.
    private func detailsArrived() async {
        guard tab == "media-servers" else { return }
        if detailsReading {
            detailsAgain = true
            return
        }
        detailsReading = true
        defer { detailsReading = false }
        repeat {
            detailsAgain = false
            await load()
            detailsLanded += 1
        } while detailsAgain && tab == "media-servers"
    }
    func search(_ q: String) { query = q; limit = 60; Task { await load() } }
    /// A failed page read gives its 60 back: `limit` stayed up, so the next page
    /// asked for 120 more than the grid showed. Only while no filter, tab or newer page has moved
    /// it since. `pageFailed` lets the grid ask for that page again (autoPage's pagedAt).
    @Published private(set) var pageFailed = 0
    func more() {
        limit += 60
        let asked: Int = limit
        Task {
            await load()
            if failedGeneration == generation && limit == asked {
                limit -= 60
                pageFailed += 1
            }
        }
    }
}
