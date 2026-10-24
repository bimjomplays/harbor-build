import SwiftUI

/// What the poster-grid page pages through, for every route that opens it: a row's "See all"
/// (CatalogPageView on the TV), a streaming service's category rows (bp-service) and an installed
/// addon's catalogs (bp-addon). Each is a set of shelves (chips) over one grid that loads on scroll.
/// The engine calls are the TV pages' own (`rooms.page`, `animeRoom.specPage`, `services.page`,
/// `discoverRoom.genrePage`, `addonsRoom.catalogs` / `feed`); the filters work on what has loaded.
@MainActor
final class PhoneCatalogModel: ObservableObject {
    enum Origin {
        case row(PhoneCatalogTarget)
        case service(id: String)
        case addon(base: String)
    }

    /// One chip's worth of titles: a service category or an addon catalog (a row has just one).
    struct Shelf: Identifiable {
        let id: String
        let title: String
        var seed: [Meta] = []
        /// The first page the engine is asked for when the seed is empty or already page 1.
        var firstPage = 1
        var cursor: AnyJSON? = nil
    }

    enum Sort: String, CaseIterable {
        case source, rating, newest, title

        var label: String {
            switch self {
            case .source: return T("Default order")
            case .rating: return T("Top rated")
            case .newest: return T("Newest")
            case .title: return T("A to Z")
            }
        }
    }

    struct Filters: Equatable {
        var genre: String? = nil
        var year: String? = nil
        var sort: Sort = .source
        var isActive: Bool { genre != nil || year != nil }
    }

    struct AddonCatalog: Decodable { var key: String; var name: String; var type: String; var cursor: AnyJSON }

    let origin: Origin
    @Published private(set) var shelves: [Shelf] = []
    @Published private(set) var active: Shelf?
    @Published private(set) var metas: [Meta] = []
    @Published private(set) var loading = false
    @Published private(set) var exhausted = false
    /// The last page read failed (not an empty page): paging stops until Try again.
    @Published private(set) var pageFailed = false
    /// The shelves themselves could not be read (a service's rows, an addon's catalogs).
    @Published private(set) var shelvesFailed = false
    @Published private(set) var shelvesLoaded = false
    /// Why a shelf with nothing in it is empty (a genre shelf with no TMDB key, a stream-only addon).
    @Published private(set) var emptyNote: String?
    /// A filter that shortens the list with the footer already in view moves no new row into view:
    /// it asks for the next page itself.
    @Published var filters = Filters() {
        didSet { if endInView && filters != oldValue { requestMore() } }
    }

    private var started = false
    private var nextPage = 1
    /// Bumped whenever the shelf changes, so a read that was in flight for the old one is dropped.
    private var generation = 0
    private var failNext: Bool

    init(origin: Origin) {
        self.origin = origin
        failNext = ProcessInfo.processInfo.arguments.contains("--phone-catalog-fail")
    }

    /// Fixture launches never touch the engine or the network.
    private var offline: Bool { Fixtures.active && !Fixtures.liveRooms }

    // MARK: Shelves

    /// Reads the shelves once. The reads belong to the model, not to the view's task, so a page pushed
    /// away and back (which cancels the task) does not leave the grid half loaded.
    func start() {
        guard !started else { return }
        started = true
        Task { await loadShelves() }
    }

    func reloadShelves() {
        shelvesFailed = false
        Task { await loadShelves() }
    }

    private func loadShelves() async {
        switch origin {
        case .row(let target):
            var shelf = Shelf(id: target.key, title: target.title, seed: target.metas.uniquedById())
            shelf.firstPage = shelf.seed.isEmpty ? 1 : 2
            shelves = [shelf]
            shelvesLoaded = true
            await select(shelf)
        case .service(let id):
            await loadServiceShelves(id)
        case .addon(let base):
            await loadAddonShelves(base)
        }
    }

    private func loadServiceShelves(_ service: String) async {
        if offline {
            shelves = ["Popular", "Top Rated"].map { name in
                let id = "svc:\(service):\(name.lowercased().replacingOccurrences(of: " ", with: ""))"
                return Shelf(id: id, title: name, seed: Self.fixtureMetas(prefix: id, start: 0, count: 12), firstPage: 2)
            }
            shelvesLoaded = true
            if let first = shelves.first { await select(first) }
            return
        }
        let p = ProfilesStore.shared.active
        let built: ServiceBrowseSource.Build? = try? await HarborEngine.shared.call("services.rows", [service, p?.id ?? "default", p?.linked ?? true])
        guard let built else {
            shelvesFailed = true
            return
        }
        shelvesLoaded = true
        // bp-service.tsx: no TMDB key is the empty state, not a failure that Try again could never fix.
        if !built.hasKey {
            emptyNote = T("Add a TMDB key in Settings to browse this service.")
            return
        }
        shelves = built.rows.map { row in
            Shelf(id: row.key, title: row.name, seed: row.metas.uniquedById(), firstPage: row.metas.isEmpty ? 1 : 2)
        }
        if let first = shelves.first { await select(first) } else { emptyNote = T("Nothing here yet") }
    }

    private func loadAddonShelves(_ base: String) async {
        if offline {
            let named: [(String, String)] = [("Popular", "movie"), ("Featured", "series")]
            shelves = named.map { name, type in
                let id = "addon:\(name.lowercased())"
                return Shelf(id: id, title: "\(name) · \(type)")
            }
            shelvesLoaded = true
            if let first = shelves.first { await select(first) }
            return
        }
        let got: [AddonCatalog]? = try? await HarborEngine.shared.call("addonsRoom.catalogs", [base])
        guard let got else {
            shelvesFailed = true
            return
        }
        shelvesLoaded = true
        shelves = got.map { Shelf(id: $0.key, title: "\($0.name) · \($0.type)", cursor: $0.cursor) }
        if let first = shelves.first {
            await select(first)
        } else {
            emptyNote = T("This addon provides streams only. It has no catalog to browse, but it still works behind every title you open.")
        }
    }

    func select(_ shelf: Shelf) async {
        generation += 1
        active = shelf
        metas = shelf.seed
        nextPage = shelf.firstPage
        exhausted = false
        pageFailed = false
        loading = false
        emptyNote = nil
        filters = Filters()
        await CardMarksStore.shared.refresh(metas)
        if metas.isEmpty { await loadMore() }
    }

    /// A chip press: the chip already shown does nothing, unless it sits over an empty grid (a failed
    /// first page leaves the chip as the only way to read it again).
    func choose(_ shelf: Shelf) {
        let retry: Bool = metas.isEmpty && !loading
        guard active?.id != shelf.id || retry else { return }
        Task { await select(shelf) }
    }

    // MARK: Paging

    var canLoadMore: Bool { active != nil && !exhausted && !pageFailed && !metas.isEmpty }

    /// Whether the footer under the grid is in view. Not published: it only steers paging.
    private var endInView = false

    /// The footer came into view or left it; coming in asks for the next page.
    func setEndInView(_ inView: Bool) {
        endInView = inView
        if inView { requestMore() }
    }

    /// Starts a page read that outlives the view that asked for it. Nothing starts while one is in
    /// flight or once the list is complete, so the rows and the footer can ask as often as they appear.
    func requestMore(retry: Bool = false) {
        guard !loading, retry || canLoadMore else { return }
        Task { await loadMore(retry: retry) }
    }

    private struct Fetched {
        var metas: [Meta]?
        var note: String?
        var skipped = 0
    }

    func loadMore(retry: Bool = false) async {
        guard let shelf = active, !loading, !exhausted, retry || !pageFailed else { return }
        let mine = generation
        loading = true
        pageFailed = false
        let fetched: Fetched = await fetch(shelf, page: nextPage)
        guard mine == generation else { return }
        loading = false
        guard let next = fetched.metas else {
            pageFailed = true
            return
        }
        if next.isEmpty {
            exhausted = true
            if metas.isEmpty { emptyNote = fetched.note ?? emptyCopy }
            return
        }
        let before = metas.count
        let merged: [Meta] = (metas + next).uniquedById()
        // A feed that answers the same page again would load for ever: no new title ends it.
        guard merged.count > before else {
            exhausted = true
            return
        }
        nextPage += 1 + fetched.skipped
        emptyNote = nil
        metas = merged
        await CardMarksStore.shared.refresh(Array(merged.suffix(merged.count - before)))
        // A short page, or one the filters hide, adds no row that comes into view and asks again: once
        // the new rows are laid out, a footer still in view reads on from here.
        try? await Task.sleep(for: .milliseconds(150))
        if mine == generation && endInView { requestMore() }
    }

    private var emptyCopy: String {
        switch origin {
        case .addon: return T("This catalog came back empty. Try another one, or check the addon in Settings.")
        default: return T("No titles came back for this list.")
        }
    }

    private func fetch(_ shelf: Shelf, page: Int) async -> Fetched {
        if offline { return await fixturePage(shelf, page: page) }
        switch origin {
        case .addon:
            guard let cursor = shelf.cursor else { return Fetched(metas: []) }
            let got: LossyArray<Meta>? = try? await HarborEngine.shared.call("addonsRoom.feed", [cursor, page, metas.count])
            return Fetched(metas: got?.wrappedValue)
        case .service:
            let p = ProfilesStore.shared.active
            let got: LossyArray<Meta>? = try? await HarborEngine.shared.call("services.page", [shelf.id, page, p?.id ?? "default", p?.linked ?? true])
            return Fetched(metas: got?.wrappedValue)
        case .row(let target):
            return await fetchRow(target, page: page)
        }
    }

    private func fetchRow(_ target: PhoneCatalogTarget, page: Int) async -> Fetched {
        let key = target.key
        let p = ProfilesStore.shared.active
        if key.hasPrefix("genre:") {
            // bp-genre-grid: TMDB discover pages for one genre shelf (use-bp-genre-grid).
            struct GenrePage: Decodable { @LossyArray var metas: [Meta]; var status: String }
            let genre = String(key.dropFirst("genre:".count))
            let failed = GenrePage(metas: [], status: "failed")
            var at = page
            var got: GenrePage = (try? await HarborEngine.shared.call("discoverRoom.genrePage", [p?.id ?? "default", p?.linked ?? true, genre, at])) ?? failed
            // A page the anime filter emptied is not the end; skip past it (bounded).
            var skipped = 0
            while got.status == "filtered", skipped < 3 {
                at += 1
                skipped += 1
                got = (try? await HarborEngine.shared.call("discoverRoom.genrePage", [p?.id ?? "default", p?.linked ?? true, genre, at])) ?? failed
            }
            if got.status == "failed" { return Fetched(metas: nil) }
            var note: String?
            if got.metas.isEmpty {
                switch got.status {
                case "no-key": note = T("Genre shelves are built from TMDB. Add a key in Setup to fill this one.")
                case "filtered": note = T("Everything on this page of %@ is hidden by your anime filter.", T(genre))
                case "empty": note = T("Nothing in %@ right now.", T(genre))
                default: note = T("Couldn't reach TMDB for %@ titles.", T(genre))
                }
            }
            return Fetched(metas: got.metas, note: note, skipped: skipped)
        }
        if key.hasPrefix("svc:") {
            let got: LossyArray<Meta>? = try? await HarborEngine.shared.call("services.page", [key, page, p?.id ?? "default", p?.linked ?? true])
            return Fetched(metas: got?.wrappedValue)
        }
        if target.room == .anime {
            let got: LossyArray<Meta>? = try? await HarborEngine.shared.call("animeRoom.specPage", [key, page])
            return Fetched(metas: got?.wrappedValue)
        }
        let kind: String
        switch target.room {
        case .home: kind = "home"
        case .movies: kind = "movies"
        default: kind = "shows"
        }
        let got: LossyArray<Meta>? = try? await HarborEngine.shared.call("rooms.page", [kind, key, page])
        return Fetched(metas: got?.wrappedValue)
    }

    // MARK: Fixtures

    /// Two further pages of fifteen, then the end. `--phone-catalog-fail` makes the first further page
    /// fail once, for the Try again button.
    private func fixturePage(_ shelf: Shelf, page: Int) async -> Fetched {
        try? await Task.sleep(for: .milliseconds(250))
        if failNext {
            failNext = false
            return Fetched(metas: nil)
        }
        let index = page - shelf.firstPage
        guard index >= 0, index < 2 else { return Fetched(metas: []) }
        let start = shelf.seed.isEmpty ? index * 15 : 12 + index * 15
        return Fetched(metas: Self.fixtureMetas(prefix: shelf.id, start: start, count: 15))
    }

    /// Titles for a fixture shelf. Ids are `fx-<shelf>-<n>`; genres and years cycle so the filters have
    /// something to separate, and the first twelve carry Thriller too.
    private static func fixtureMetas(prefix: String, start: Int, count: Int) -> [Meta] {
        let cleaned = prefix.replacingOccurrences(of: ":", with: "-")
        let genres: [String] = ["Drama", "Comedy", "Action"]
        var out: [Meta] = []
        for n in start..<(start + count) {
            let genre = genres[n % 3]
            let tags: [String] = n < 12 ? [genre, "Thriller"] : [genre]
            out.append(Meta(id: "fx-\(cleaned)-\(n)", type: "movie", name: "Fixture Title \(n)", poster: nil, background: nil, logo: nil,
                            description: nil, releaseInfo: "\(2010 + n % 14)", releaseDate: nil, inTheaters: nil,
                            imdbRating: "\(5 + n % 5).\(n % 10)", tmdbScore: nil, runtime: nil, genres: tags, adult: nil,
                            isCollection: nil, providerBadge: nil, videos: nil))
        }
        return out
    }

    // MARK: Filters

    /// The four-digit year of a title ("2024", "2019–2022", "2021-05-01").
    static func year(of meta: Meta) -> String? {
        for text in [meta.releaseInfo, meta.releaseDate] {
            guard let text else { continue }
            let digits = String(text.prefix(4))
            if digits.count == 4, digits.allSatisfy({ $0.isNumber }) { return digits }
        }
        return nil
    }

    private static func rating(of meta: Meta) -> Double {
        if let text = meta.imdbRating, let value = Double(text), value.isFinite { return value }
        if let score = meta.tmdbScore, score.isFinite { return score }
        return 0
    }

    var genres: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for meta in metas {
            for genre in meta.genres ?? [] where !genre.isEmpty && seen.insert(genre).inserted { out.append(genre) }
        }
        return out.sorted()
    }

    var years: [String] {
        Array(Set(metas.compactMap { Self.year(of: $0) })).sorted(by: >)
    }

    /// What the grid shows: the loaded titles through the genre and year filters, in the chosen order.
    var visible: [Meta] {
        var list: [Meta] = metas
        if let genre = filters.genre { list = list.filter { ($0.genres ?? []).contains(genre) } }
        if let year = filters.year { list = list.filter { Self.year(of: $0) == year } }
        switch filters.sort {
        case .source:
            return list
        case .rating:
            return list.enumerated().sorted { a, b in
                let (x, y) = (Self.rating(of: a.element), Self.rating(of: b.element))
                return x != y ? x > y : a.offset < b.offset
            }.map { $0.element }
        case .newest:
            return list.enumerated().sorted { a, b in
                let (x, y) = (Self.year(of: a.element) ?? "", Self.year(of: b.element) ?? "")
                return x != y ? x > y : a.offset < b.offset
            }.map { $0.element }
        case .title:
            return list.enumerated().sorted { a, b in
                let order = a.element.name.localizedCaseInsensitiveCompare(b.element.name)
                return order != .orderedSame ? order == .orderedAscending : a.offset < b.offset
            }.map { $0.element }
        }
    }
}
