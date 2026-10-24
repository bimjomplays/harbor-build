import SwiftUI

/// Collections room (bp-collections.tsx): source chips (bp-collection-steps BP_COLLECTION_SOURCES:
/// All / Mine / TMDB / TVDB), a 16:9 card grid, and an in-place overlay:
/// bp-collection-items for owned collections, bp-collection-detail for TMDB and
/// bp-collection.tsx for TVDB lists. The viewer's own collections are editable from the TV
/// (community-hub.tsx / community-editor.tsx: new, rename, add and remove titles, delete).
@MainActor
final class CollectionsModel: ObservableObject {
    struct Item: Decodable, Identifiable {
        var id: String; var type: String; var name: String; var poster: String?
        var meta: Meta {
            Meta(id: id, type: type, name: name, poster: poster, background: nil, logo: nil, description: nil, releaseInfo: nil, releaseDate: nil, inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil)
        }
    }
    struct Card: Decodable, Identifiable {
        var key: String; var source: String
        /// The collection's own id (uuid for mine, TMDB/TVDB id otherwise).
        var ref: String
        var name: String; var image: String?; var count: Int?; var byline: String?; var description: String?; @LossyArray var items: [Item]   // lossy
        var hidden: Int?
        var id: String { key }
        /// SH-1: the card's own cover as the ambient backdrop while it holds focus (bp-ambient.tsx
        /// TITLE_ART_ROUTES has "collection" and "tmdb-collection" alongside "home").
        var meta: Meta {
            Meta(id: "collection:" + key, type: "collection", name: name, poster: nil, background: image, logo: nil, description: description, releaseInfo: nil, releaseDate: nil, inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil)
        }
    }
    struct Limits: Decodable { var collections: Int; var items: Int }

    @Published private(set) var mine: [Card] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var failed: String?
    @Published private(set) var source = "all"
    @Published private(set) var limits = Limits(collections: 24, items: 100)
    /// bp-collection-steps "curated": TMDB's franchise catalog, a page at a time, by category.
    @Published private(set) var tmdb: [Card] = []
    @Published private(set) var tmdbDone = false
    @Published private(set) var tmdbLoading = false
    @Published var category = "All"
    @Published private(set) var categories: [String] = ["All"]
    private var tmdbPage = 0
    /// bp-collection-steps stepTvdb: TVDB lists through Harbor's proxy (no key). "all" stops at
    /// ten seed names (tvdbCapped → "See every TVDB list"); the TVDB source walks them all.
    @Published private(set) var tvdb: [Card] = []
    @Published private(set) var tvdbDone = false
    @Published private(set) var tvdbLoading = false
    @Published private(set) var tvdbFailed = false
    @Published private(set) var tvdbCapped = false
    private var tvdbNext = 0
    private(set) var tvdbScope = "all"
    private var tvdbRun = 0
    var hasKey: Bool { !SettingsBridge.shared.slice.tmdbKey.isEmpty }

    /// use-bp-collection-feed AUTO_PULLS: how many times a pull that added nothing is followed by
    /// another one (the sentinel is still in view).
    private static let autoPulls = 4
    /// bp-collection-steps STEPS_PER_PULL (3) steps of TMDB_PAGE (24) franchises. The engine's
    /// curated page is 12 (collectionsRoom.tmdb), so one pull walks up to six of them.
    private static let tmdbPagesPerPull = 6

    func load() async {
        loading = true; defer { loading = false; loaded = true }
        do {
            let m: LossyArray<Card> = try await HarborEngine.shared.call("collectionsRoom.mine", [])
            mine = m.wrappedValue
        } catch { failed = error.localizedDescription }
        categories = (try? await HarborEngine.shared.call("collectionsRoom.categories", [])) ?? ["All"]
        if let l: Limits = try? await HarborEngine.shared.call("collectionsRoom.limits", []) { limits = l }
        let before = cards.count
        if hasKey { await loadTmdb(reset: true) } else { await loadTvdb(reset: true) }
        // Offline every curated franchise fails to resolve, so the first
        // page added no card and nothing on screen could ask for the next one: the grid sat empty
        // with no spinner and no end line. Keep pulling, as the feed does.
        if cards.count == before { await pull() }
    }

    func reloadMine() async {
        if let m: LossyArray<Card> = try? await HarborEngine.shared.call("collectionsRoom.mine", []) { mine = m.wrappedValue }
    }

    /// Upstream builds a fresh feed for every source pick
    /// (use-bp-collection-feed resets on `source`), so picking a source again is how a viewer
    /// retries a feed that failed. The TV keeps what loaded (a pick does not throw a full grid
    /// away) and re-runs only what failed: a TVDB walk that could not reach TVDB, a curated walk
    /// that ended with nothing.
    func set(source s: String) {
        source = s
        Task {
            let retryTvdb: Bool = tvdbFailed && tvdbDone
            let retryTmdb: Bool = tmdb.isEmpty && tmdbDone && hasKey
            switch s {
            case "tvdb": await loadTvdb(reset: retryTvdb)
            case "all":
                if retryTmdb && category == "All" { await loadTmdb(reset: true) }
                if curatedFinished || tvdbScope != "all" { await loadTvdb(reset: retryTvdb) }
            case "tmdb": if tmdb.isEmpty && hasKey { await loadTmdb(reset: retryTmdb) }
            default: break
            }
            guard source == s, cards.isEmpty else { return }
            await pull()
        }
    }

    func loadTmdb(reset: Bool) async {
        if reset { tmdb = []; tmdbPage = 0; tmdbDone = false }
        guard !tmdbLoading, !tmdbDone, hasKey else { return }
        tmdbLoading = true; defer { tmdbLoading = false }
        struct Page: Decodable { @LossyArray var cards: [Card]; var done: Bool }
        let p = ProfilesStore.shared.active
        let want = category
        // use-bp-collection-feed pull: steps until one adds a card
        // (STEPS_PER_PULL), so a page whose franchises all failed to resolve moves on to the next.
        var added = 0
        var pages = 0
        while added == 0 && pages < Self.tmdbPagesPerPull && !tmdbDone {
            pages += 1
            let got: Page? = try? await HarborEngine.shared.call("collectionsRoom.tmdb", [p?.id ?? "default", p?.linked ?? true, want, tmdbPage + 1])
            // A category chip pressed while this page loaded reset the list, and its own load
            // bounced off tmdbLoading: load the new category now instead of leaving the grid empty (and a
            // failed stale page must not mark the new category done).
            guard want == category else { tmdbLoading = false; await loadTmdb(reset: false); return }
            if let page = got {
                tmdbPage += 1
                let had = tmdb.count
                // repeats inside a page too
                tmdb = (tmdb + page.cards).uniquedById()
                added += tmdb.count - had
                tmdbDone = page.done
            } else { tmdbDone = true }
        }
    }

    /// use-bp-collection-feed pull: up to three steps until one adds a card (STEPS_PER_PULL).
    func loadTvdb(reset: Bool) async {
        let scope = source == "tvdb" ? "tvdb" : "all"
        if reset || scope != tvdbScope {
            tvdbRun += 1
            tvdb = []; tvdbNext = 0; tvdbDone = false; tvdbFailed = false; tvdbCapped = false; tvdbLoading = false
            tvdbScope = scope
        }
        guard !tvdbLoading, !tvdbDone else { return }
        tvdbLoading = true
        let run = tvdbRun
        struct Page: Decodable { @LossyArray var cards: [Card]; var next: Int; var done: Bool; var failed: Bool; var capped: Bool }
        var added = 0
        var steps = 0
        while added == 0 && steps < 3 && !tvdbDone {
            steps += 1
            let page: Page? = try? await HarborEngine.shared.call("collectionsRoom.tvdb", [scope, tvdbNext])
            guard run == tvdbRun else { return }
            guard let page else { tvdbDone = true; tvdbFailed = true; break }
            let known = Set(tvdb.map(\.key))
            let fresh = page.cards.filter { !known.contains($0.key) }
            tvdb += fresh
            added += fresh.count
            tvdbNext = page.next; tvdbDone = page.done; tvdbFailed = page.failed; tvdbCapped = page.capped
        }
        tvdbLoading = false
    }

    func set(category c: String) { category = c; Task { await loadTmdb(reset: true) } }

    /// (open-items sweep 2) bp-view-state collectionSource / collectionCategory: the chips picked
    /// on the last visit (ShellViewState), set before the first load so it walks them.
    func restore(source s: String, category c: String) {
        guard !loaded, !loading else { return }
        // A saved "community" chip (the source is gone) falls back to All.
        source = ["all", "mine", "tmdb", "tvdb"].contains(s) ? s : "all"
        category = c
    }

    /// use-bp-collection-feed's sentinel: a pull that added nothing
    /// leaves the sentinel in view, so the feed pulls again (at most AUTO_PULLS more times). The TV
    /// pulls when the last card appears, and a pull that added nothing makes no new last card, so
    /// the repeat happens here. Only the feed sources page; Mine loads at once.
    func pull() async {
        guard source == "all" || source == "tmdb" || source == "tvdb" else { return }
        let want = source
        var rounds = 0
        while !done && rounds <= Self.autoPulls && want == source && !Task.isCancelled {
            rounds += 1
            let before = cards.count
            await more()
            if cards.count > before { return }
        }
    }

    /// The last card appeared: pull the next page of whichever source is still open.
    func more() async {
        switch source {
        case "tmdb": await loadTmdb(reset: false)
        case "tvdb": await loadTvdb(reset: false)
        case "all":
            if curatedFinished { await loadTvdb(reset: false) } else { await loadTmdb(reset: false) }
        default: break
        }
    }

    var cards: [Card] {
        switch source {
        case "mine": return mine
        case "tmdb": return tmdb
        case "tvdb": return tvdb
        default:
            // bp-collection-steps PHASES.all: mine, curated, then TVDB (ten names).
            let curated = category == "All" ? tmdb : []
            let lists = curatedFinished && tvdbScope == "all" ? tvdb : []
            var seen = Set<String>()
            return (mine + curated + lists).filter { seen.insert($0.key).inserted }
        }
    }

    var busy: Bool { loading || tmdbLoading || tvdbLoading }

    /// All's curated phase is over (or not in play), so the TVDB phase may show and pull.
    private var curatedFinished: Bool { !hasKey || tmdbDone || category != "All" }

    /// "See every TVDB list" (bp-collections.tsx) after the capped TVDB run in All.
    var showAllTvdb: Bool { source == "all" && tvdbScope == "all" && tvdbCapped && !cards.filter { $0.source == "tvdb" }.isEmpty }

    var done: Bool {
        switch source {
        case "mine": return loaded
        case "tmdb": return !hasKey || tmdbDone
        case "tvdb": return tvdbDone
        default: return loaded && curatedFinished && tvdbScope == "all" && tvdbDone
        }
    }

    /// bp-collections.tsx endMessage.
    var endMessage: String {
        let empty = cards.isEmpty
        if empty {
            switch source {
            case "mine": return "You have not made a collection yet."
            case "tvdb" where tvdbFailed: return "TVDB lists are unavailable right now."
            default: return "Nothing to show here yet."
            }
        }
        switch source {
        case "tvdb": return tvdbFailed ? "That's every TVDB list we could reach. Some are unavailable right now." : "That's every TVDB list we could find."
        case "mine": return "That's all of your collections."
        case "all" where tvdbFailed: return "That's everything we could reach. Some sources are unavailable right now."
        default: return "That's every collection TMDB knows about."
        }
    }

    /// community-hub "New collection".
    func create(name: String) async -> Card? {
        let c: Card? = try? await HarborEngine.shared.call("collectionsRoom.create", [name])
        await reloadMine()
        return c
    }
}
