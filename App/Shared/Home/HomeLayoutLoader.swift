import Combine
import Foundation

/// One resolved Home: the hero's titles and the rows top to bottom, Continue Watching where the layout
/// put it. Rows that showed nothing this pass are listed in `skipped` (kept in the layout, not drawn).
struct HomeContent: Equatable {
    struct Item: Identifiable, Equatable {
        enum Kind: Equatable {
            case row(BrowseRow)
            case resuming([ContinueItem])
        }

        /// Unique on the page: the spec's id, or `<spec id>/<row key>` for a row of a whole-room spec.
        let id: String
        let specId: String
        /// The source this item shows (a whole-room spec's rows come as their `.engineRow`s).
        let source: HomeRowSource
        let title: String
        let kind: Kind

        /// The page a row's "See all" opens (PhoneCatalogTarget's room).
        var room: HomeRoom? { source.room }
    }

    enum SkipReason: Equatable {
        /// Its source returned nothing this time.
        case empty
        /// Nothing serves it now (gone, signed out, hidden, unknown to this build).
        case unavailable
        case failed(String)
        /// The same source is already on the page above it.
        case duplicate
    }

    struct Skipped: Equatable {
        let specId: String
        let source: HomeRowSource
        let title: String
        let reason: SkipReason
    }

    var hero: [Meta] = []
    var items: [Item] = []
    var skipped: [Skipped] = []

    /// The rows in order, Continue Watching left out.
    var rows: [BrowseRow] {
        items.compactMap { item in
            if case .row(let row) = item.kind { return row }
            return nil
        }
    }

    /// The first Continue Watching on the page.
    var resuming: [ContinueItem] {
        for item in items {
            if case .resuming(let list) = item.kind { return list }
        }
        return []
    }

    var isEmpty: Bool { hero.isEmpty && items.isEmpty }
}

/// What one pass has to read for a layout. Each room page is read once however many rows use it.
struct HomeFetchPlan: Equatable {
    var rooms: Set<HomeRoom> = []
    var resuming: Set<HomeRoom> = []
    var anilist = false
    var mal = false
    /// Addon base → the catalog keys whose first page is read.
    var addonCatalogs: [String: Set<String>] = [:]

    init(layout: HomeLayout, hiddenRooms: Set<HomeRoom> = []) {
        var sources: [HomeRowSource] = layout.rows.map(\.source)
        if case .source(let s) = layout.hero { sources.append(s) }
        for source in sources { add(source, hiddenRooms: hiddenRooms) }
    }

    private mutating func add(_ source: HomeRowSource, hiddenRooms: Set<HomeRoom>) {
        switch source {
        case .engineRoom(let room), .engineRow(let room, _):
            if !hiddenRooms.contains(room) { rooms.insert(room) }
        case .continueWatching(let room):
            if !hiddenRooms.contains(room) && room != .movies { resuming.insert(room) }
        case .anilistList:
            if !hiddenRooms.contains(.anime) { anilist = true }
        case .malList:
            if !hiddenRooms.contains(.anime) { mal = true }
        case .addonCatalog(let base, let catalog):
            addonCatalogs[base, default: []].insert(catalog)
        case .unknown:
            break
        }
    }

    /// Everything `other` needs was read by this plan.
    func covers(_ other: HomeFetchPlan) -> Bool {
        other.rooms.isSubset(of: rooms) && other.resuming.isSubset(of: resuming)
            && (!other.anilist || anilist) && (!other.mal || mal)
            && other.addonCatalogs.allSatisfy { base, keys in keys.isSubset(of: addonCatalogs[base] ?? []) }
    }
}

/// The reads that are not room pages: the tracker rails and the addon catalogs. The engine behind
/// them live; a fixed set under `--fixtures` (no network, nothing signed in but a fixture AniList).
@MainActor
protocol HomeExtraSource: AnyObject {
    func anilist() async -> HomeTrackerState
    func mal() async -> HomeTrackerState
    /// The installed addons that have catalogs, in install order.
    func addons() async -> [(base: String, name: String)]
    /// nil when the list could not be read.
    func catalogs(base: String, addon: String) async -> [HomeAddonCatalog]?
    /// A catalog's first page (pages count from 1, as PhoneCatalogModel reads them).
    func feed(_ catalog: HomeAddonCatalog) async -> [Meta]
}

@MainActor
final class EngineHomeExtras: HomeExtraSource {
    private struct Status: Decodable { var authenticated: Bool? }
    private struct Rail: Decodable { var key: String; var title: String?; @LossyArray var metas: [Meta] }
    private struct Rails: Decodable { @LossyArray var rails: [Rail]; var loading: Bool? }
    private struct Card: Decodable { var name: String; var base: String; var hasCatalogs: Bool? }
    private struct Catalog: Decodable { var key: String; var name: String; var type: String; var cursor: AnyJSON }

    func anilist() async -> HomeTrackerState { await tracker("anilist") }
    func mal() async -> HomeTrackerState { await tracker("mal") }

    /// engine/trackers.ts: `status()` says whether the account is connected, `rails()` returns the
    /// cached rails at once and refreshes them behind (Home's late update brings the rest).
    private func tracker(_ name: String) async -> HomeTrackerState {
        let status: Status? = try? await HarborEngine.shared.call("\(name).status")
        guard status?.authenticated == true else { return HomeTrackerState(signedIn: false) }
        let got: Rails? = try? await HarborEngine.shared.call("\(name).rails", [false])
        let rails: [BrowseRow] = (got?.rails ?? []).map { BrowseRow(key: $0.key, title: $0.title ?? $0.key, metas: $0.metas) }
        return HomeTrackerState(signedIn: true, loading: got?.loading ?? false, rails: rails)
    }

    func addons() async -> [(base: String, name: String)] {
        let p = ProfilesStore.shared.active
        let authKey: String? = p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
        let cards: LossyArray<Card>? = try? await HarborEngine.shared.call("addonsRoom.cards", [authKey, false])
        return (cards?.wrappedValue ?? []).filter { $0.hasCatalogs != false }.map { (base: $0.base, name: $0.name) }
    }

    func catalogs(base: String, addon: String) async -> [HomeAddonCatalog]? {
        let got: LossyArray<Catalog>? = try? await HarborEngine.shared.call("addonsRoom.catalogs", [base])
        guard let got else { return nil }
        return got.wrappedValue.map { HomeAddonCatalog(base: base, addon: addon, key: $0.key, name: $0.name, type: $0.type, cursor: $0.cursor) }
    }

    func feed(_ catalog: HomeAddonCatalog) async -> [Meta] {
        let got: LossyArray<Meta>? = try? await HarborEngine.shared.call("addonsRoom.feed", [catalog.cursor, 1, 0])
        return got?.wrappedValue ?? []
    }
}

/// `--fixtures`: AniList signed in with two rails, MyAnimeList signed out, one addon with two catalogs.
@MainActor
final class FixtureHomeExtras: HomeExtraSource {
    static let addonBase = "https://addon.invalid/fixture"

    static func metas(_ prefix: String, count: Int = 12) -> [Meta] {
        (0..<count).map { n in Meta(id: "fx-\(prefix)-\(n)", type: n % 2 == 0 ? "movie" : "series", name: "\(prefix.capitalized) \(n + 1)") }
    }

    func anilist() async -> HomeTrackerState {
        HomeTrackerState(signedIn: true, rails: [
            BrowseRow(key: "watching", title: "Watching", metas: Self.metas("anilist-watching", count: 6)),
            BrowseRow(key: "planning", title: "Plan to Watch", metas: Self.metas("anilist-planning", count: 8)),
        ])
    }

    func mal() async -> HomeTrackerState { HomeTrackerState(signedIn: false) }

    func addons() async -> [(base: String, name: String)] { [(base: Self.addonBase, name: "Fixture Addon")] }

    func catalogs(base: String, addon: String) async -> [HomeAddonCatalog]? {
        guard base == Self.addonBase else { return [] }
        return [
            HomeAddonCatalog(base: base, addon: addon, key: "popular", name: "Popular", type: "movie", cursor: .null),
            HomeAddonCatalog(base: base, addon: addon, key: "featured", name: "Featured", type: "series", cursor: .null),
        ]
    }

    func feed(_ catalog: HomeAddonCatalog) async -> [Meta] { Self.metas("addon-\(catalog.key)") }
}

/// Turns the active profile's HomeLayout into what Home shows (HomeContent), reading each room page
/// the layout needs once per pass through `app.browseSource`, the same source the room feeds read.
/// Reloads on the engine events the room feed listened to, and re-assembles without a read when an
/// edit to the layout needs nothing new.
@MainActor
final class HomeLayoutLoader: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded(HomeContent)
        case failed(String)
    }

    struct Dependencies {
        var source: BrowseSource
        var extras: HomeExtraSource
        var store: HomeLayoutStore
        var profileId: String
        /// Classic Home (settings.homeMode): Auto has no hero, as the room feed drew it.
        var classicHome: @MainActor () -> Bool
        var hiddenRooms: @MainActor () -> Set<HomeRoom>
        /// Watchlist and watched marks for the titles on screen (CardMarksStore).
        var refreshMarks: @MainActor ([Meta]) async -> Void
        /// Off under fixtures, as the room feed's events were, and in the unit tests.
        var listensToEngine: Bool

        @MainActor static func live(app: AppModel) -> Dependencies {
            Dependencies(
                source: app.browseSource,
                extras: (Fixtures.active && !Fixtures.liveRooms) ? FixtureHomeExtras() : EngineHomeExtras(),
                store: HomeLayoutStore.shared,
                profileId: ProfilesStore.shared.active?.id ?? "default",
                classicHome: { SettingsBridge.shared.slice.homeMode == "classic" },
                hiddenRooms: { Set(HomeRoom.allCases.filter { ParentalGate.shared.hides($0.room) }) },
                refreshMarks: { await CardMarksStore.shared.refresh($0) },
                listensToEngine: !Fixtures.active
            )
        }
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var layout: HomeLayout
    /// What the last pass read, for the source picker (`entries`) and for re-assembling after an edit.
    @Published private(set) var snapshot = HomeSourceSnapshot()
    /// How many passes have read their sources (the tests count reads with it).
    private(set) var passes = 0

    private var deps: Dependencies
    private var fetched: HomeFetchPlan?
    private var unsubscribe: (() -> Void)?
    private var reload: Task<Void, Never>?
    private var generation = 0
    private var bag = Set<AnyCancellable>()

    static let bandTypes: Set<String> = ["service", "addon", "collection"]

    init(_ deps: Dependencies) {
        self.deps = deps
        layout = deps.store.layout(for: deps.profileId)
        follow(deps.store)
        if deps.listensToEngine { listen() }
    }

    private func follow(_ store: HomeLayoutStore) {
        bag.removeAll()
        store.$revision
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.layoutChanged() } }
            .store(in: &bag)
    }

    deinit { unsubscribe?() }

    var profileId: String { deps.profileId }

    /// Every source on offer against the last pass (the picker calls `loadAllSources` first so the
    /// other rooms' rows and every addon catalog are listed too).
    var entries: [HomeSourceEntry] { HomeSourceRegistry.entries(in: snapshot) }

    /// A new profile or source (a profile switch, a fixtures flip): reads its layout and loads.
    func use(_ deps: Dependencies) async {
        if deps.store !== self.deps.store { follow(deps.store) }
        self.deps = deps
        layout = deps.store.layout(for: deps.profileId)
        fetched = nil
        await load(quiet: false)
    }

    // MARK: Loading

    /// `quiet`: a pull-to-refresh or an engine update keeps what is on screen until the pass lands,
    /// and a failed quiet pass keeps it too.
    func load(quiet: Bool) async {
        if !quiet { phase = .loading }
        generation &+= 1
        let mine = generation
        let current = deps.store.layout(for: deps.profileId)
        let hidden = deps.hiddenRooms()
        let plan = widened(HomeFetchPlan(layout: current, hiddenRooms: hidden), hidden: hidden)
        var read = await fetch(plan, allCatalogs: allSources)
        guard mine == generation, !Task.isCancelled else { return }
        read.hiddenRooms = hidden
        passes += 1
        // An edit made while this pass was reading wins (one that needed nothing new was re-assembled
        // without bumping `generation`): draw the layout as it is now, and read again if it needs
        // something this pass did not.
        let latest = deps.store.layout(for: deps.profileId)
        layout = latest
        snapshot = read
        fetched = plan
        if latest != current, !plan.covers(HomeFetchPlan(layout: latest, hiddenRooms: hidden)) {
            reload?.cancel()
            reload = Task { [weak self] in await self?.load(quiet: true) }
        }
        let content = Self.assemble(latest, snapshot: read, classicHome: deps.classicHome())
        if content.items.isEmpty, content.hero.isEmpty, let failure = Self.failure(in: content) {
            if quiet, case .loaded = phase { return }
            phase = .failed(failure)
            return
        }
        if phase != .loaded(content) { phase = .loaded(content) }
        await deps.refreshMarks(Self.markable(content))
    }

    /// While the editor is open every pass reads every source there is (all four room pages, both
    /// trackers, every addon's catalog list), so the source picker lists them all and a row added from
    /// any of them is drawn at once. `endAllSources` goes back to reading only what the layout needs.
    private var allSources = false
    /// The editor's first all-sources pass is still reading (the source picker says it is still looking).
    @Published private(set) var readingAllSources = false

    /// Reads every source there is on top of what the layout needs, so the source picker
    /// can list them all. The snapshot stays a superset of what the layout shows, so an edit
    /// re-assembled from it loses nothing.
    func loadAllSources() async {
        allSources = true
        readingAllSources = true
        await load(quiet: true)
        readingAllSources = false
    }

    func endAllSources() {
        allSources = false
    }

    /// The plan with every room page and tracker added while the editor is open.
    private func widened(_ plan: HomeFetchPlan, hidden: Set<HomeRoom>) -> HomeFetchPlan {
        guard allSources else { return plan }
        var plan = plan
        plan.rooms.formUnion(Set(HomeRoom.allCases).subtracting(hidden))
        if !hidden.contains(.anime) {
            plan.anilist = true
            plan.mal = true
        }
        return plan
    }

    private func fetch(_ plan: HomeFetchPlan, allCatalogs: Bool = false) async -> HomeSourceSnapshot {
        await Self.read(plan, source: deps.source, extras: deps.extras, allCatalogs: allCatalogs)
    }

    /// Reads what the plan names. Room pages and Continue Watching run side by side; one room page
    /// failing leaves the rest. Static so the Apple TV's Home (HomeLayoutBrowseSource) reads the same way.
    static func read(_ plan: HomeFetchPlan, source: BrowseSource, extras: HomeExtraSource, allCatalogs: Bool = false) async -> HomeSourceSnapshot {
        async let home = Self.readPage(source, .home, plan.rooms.contains(.home))
        async let movies = Self.readPage(source, .movies, plan.rooms.contains(.movies))
        async let shows = Self.readPage(source, .shows, plan.rooms.contains(.shows))
        async let anime = Self.readPage(source, .anime, plan.rooms.contains(.anime))
        async let cwHome = Self.readResuming(source, .home, plan.resuming.contains(.home))
        async let cwShows = Self.readResuming(source, .shows, plan.resuming.contains(.shows))
        async let cwAnime = Self.readResuming(source, .anime, plan.resuming.contains(.anime))

        var read = HomeSourceSnapshot()
        if plan.anilist { read.anilist = await extras.anilist() }
        if plan.mal { read.mal = await extras.mal() }
        if allCatalogs || !plan.addonCatalogs.isEmpty {
            let installed = await extras.addons()
            read.addons = installed
            for addon in installed where allCatalogs || plan.addonCatalogs[addon.base] != nil {
                guard let catalogs = await extras.catalogs(base: addon.base, addon: addon.name) else { continue }
                read.addonCatalogs[addon.base] = catalogs
                let wanted: Set<String> = plan.addonCatalogs[addon.base] ?? []
                for catalog in catalogs where wanted.contains(catalog.key) {
                    let identity = HomeRowSource.addonCatalog(base: catalog.base, catalog: catalog.key).identity
                    read.addonFeeds[identity] = await extras.feed(catalog)
                }
            }
        }

        let pages: [(HomeRoom, PageRead)] = await [(.home, home), (.movies, movies), (.shows, shows), (.anime, anime)]
        for (room, page) in pages {
            switch page {
            case .skipped: break
            case .page(let p): read.pages[room] = p
            case .failed(let message): read.pageErrors[room] = message
            }
        }
        let resuming: [(HomeRoom, [ContinueItem]?)] = await [(.home, cwHome), (.shows, cwShows), (.anime, cwAnime)]
        for (room, items) in resuming {
            if let items { read.resuming[room] = items }
        }
        return read
    }

    enum PageRead {
        case skipped
        case page(BrowsePage)
        case failed(String)
    }

    nonisolated private static func readPage(_ source: BrowseSource, _ room: HomeRoom, _ wanted: Bool) async -> PageRead {
        guard wanted else { return .skipped }
        do {
            return .page(try await source.page(for: room.room))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A source that cannot say what is in progress still has rows to show (the room feed read it the same way).
    nonisolated private static func readResuming(_ source: BrowseSource, _ room: HomeRoom, _ wanted: Bool) async -> [ContinueItem]? {
        guard wanted else { return nil }
        return (try? await source.continueWatching(for: room.room)) ?? []
    }

    // MARK: Layout edits

    /// The store saved or reset a layout: one that needs nothing new is re-assembled from the last
    /// pass at once; one that needs a page or a feed not read yet loads quietly.
    private func layoutChanged() {
        let current = deps.store.layout(for: deps.profileId)
        guard current != layout else { return }
        // The editor's list follows the layout at once, even while the rows it needs are still read.
        layout = current
        let plan = HomeFetchPlan(layout: current, hiddenRooms: snapshot.hiddenRooms)
        if let fetched, fetched.covers(plan), case .loaded = phase {
            phase = .loaded(Self.assemble(current, snapshot: snapshot, classicHome: deps.classicHome()))
        } else {
            reload?.cancel()
            reload = Task { [weak self] in await self?.load(quiet: true) }
        }
    }

    /// Changes the active profile's layout and saves it. Home and the editor follow at once (the store's
    /// revision would bring the change a run-loop turn later, which a List's drag-to-reorder cannot wait for).
    func edit(_ change: (inout HomeLayout) -> Void) {
        deps.store.update(for: deps.profileId, change)
        layoutChanged()
    }

    /// Back to the standard layout for this profile.
    func resetLayout() {
        deps.store.reset(for: deps.profileId)
        layoutChanged()
    }

    /// Classic / Harbor was picked: the hero follows without a read.
    func reassemble() {
        guard case .loaded = phase else { return }
        phase = .loaded(Self.assemble(layout, snapshot: snapshot, classicHome: deps.classicHome()))
    }

    // MARK: Engine events

    private func listen() {
        let wanted: Set<String> = ["harbor:home-updated", "harbor:addons-changed", "harbor:anime-updated", "harbor:cw-dismissed"]
        unsubscribe = HarborEngine.shared.onEvent { [weak self] type, _ in
            guard wanted.contains(type) else { return }
            let seen = type
            Task { @MainActor in self?.engineEvent(seen) }
        }
    }

    /// The events the room feed reloaded Home on, plus the anime room's when the layout reads it.
    /// Bursts are folded into one pass 400 ms after the last.
    func engineEvent(_ type: String) {
        guard Self.reloads(on: type, plan: fetched ?? HomeFetchPlan(layout: layout)) else { return }
        reload?.cancel()
        reload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.load(quiet: true)
        }
    }

    static func reloads(on type: String, plan: HomeFetchPlan) -> Bool {
        switch type {
        case "harbor:home-updated":
            // Home's late rows carry the tracker rails (homeExtras) too.
            return plan.rooms.contains(.home) || plan.resuming.contains(.home) || plan.anilist || plan.mal
        case "harbor:addons-changed":
            return plan.rooms.contains(.home) || !plan.addonCatalogs.isEmpty
        case "harbor:anime-updated":
            return plan.rooms.contains(.anime) || plan.resuming.contains(.anime) || plan.anilist || plan.mal
        default:
            return true
        }
    }

    // MARK: Assembly

    /// The page for a layout against what was read. Pure: the tests drive it with hand-made snapshots.
    static func assemble(_ layout: HomeLayout, snapshot: HomeSourceSnapshot, classicHome: Bool = false) -> HomeContent {
        var content = HomeContent()
        // Rows a spec places on their own are left out of their room's whole-room spec.
        var placedAlone: [HomeRoom: Set<String>] = [:]
        for spec in layout.rows {
            if case .engineRow(let room, let key) = spec.source { placedAlone[room, default: []].insert(key) }
        }
        var shown = Set<String>()

        for spec in layout.rows {
            let source = spec.source
            let resolution = HomeSourceRegistry.resolve(source, in: snapshot)
            func skip(_ reason: HomeContent.SkipReason, title: String? = nil) {
                let name = title ?? HomeSourceRegistry.title(for: spec, resolved: nil)
                content.skipped.append(HomeContent.Skipped(specId: spec.id, source: source, title: name, reason: reason))
            }
            guard source.isKnown else { skip(.unavailable); continue }
            guard shown.insert(source.identity).inserted else { skip(.duplicate); continue }
            switch resolution {
            case .unavailable:
                skip(.unavailable)
            case .failed(let message):
                skip(.failed(message))
            case .resuming(let list):
                // The name the row was added under tells Continue Watching · Shows from Home's.
                let title = spec.title.flatMap { $0.isEmpty ? nil : $0 } ?? spec.savedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? T("Continue Watching")
                if list.isEmpty { skip(.empty, title: title); continue }
                content.items.append(HomeContent.Item(id: spec.id, specId: spec.id, source: source, title: title, kind: .resuming(list)))
            case .row(let row):
                let title = HomeSourceRegistry.title(for: spec, resolved: row)
                guard let drawn = apply(spec.options, to: row, title: title) else { skip(.empty, title: title); continue }
                content.items.append(HomeContent.Item(id: spec.id, specId: spec.id, source: source, title: title, kind: .row(drawn)))
            case .rows(let rows):
                guard case .engineRoom(let room) = source else { skip(.unavailable); continue }
                let alone: Set<String> = placedAlone[room] ?? []
                var any = false
                for row in rows where !alone.contains(row.key) {
                    let rowSource = HomeRowSource.engineRow(room: room, key: row.key)
                    guard shown.insert(rowSource.identity).inserted else { continue }
                    guard let drawn = apply(spec.options, to: row, title: row.title) else { continue }
                    any = true
                    content.items.append(HomeContent.Item(id: "\(spec.id)/\(row.key)", specId: spec.id, source: rowSource, title: row.title, kind: .row(drawn)))
                }
                if !any { skip(.empty) }
            }
        }
        content.hero = hero(layout, content: content, snapshot: snapshot, classicHome: classicHome)
        return content
    }

    /// A row as drawn: de-duped, cut to the limit, numerals on or off. nil when nothing is left.
    static func apply(_ options: HomeRowOptions, to row: BrowseRow, title: String) -> BrowseRow? {
        var metas: [Meta] = row.metas.uniquedById()
        if let limit = options.limit { metas = Array(metas.prefix(limit)) }
        guard !metas.isEmpty else { return nil }
        var shape = row.shape
        // The band rows (brand, collection) keep their own tiles.
        let titleShapes: Set<TileShape> = [.poster, .wide, .rank]
        if let wanted = options.shape, titleShapes.contains(wanted), titleShapes.contains(row.shape) { shape = wanted }
        return BrowseRow(key: row.key, title: title, metas: metas, shape: shape)
    }

    /// The hero: Off is none; a chosen source shows its titles (falling back to Auto when it has
    /// none); Auto is the room feed's rule: the page's hero slides (none on Classic Home), else the
    /// first row's titles.
    static func hero(_ layout: HomeLayout, content: HomeContent, snapshot: HomeSourceSnapshot, classicHome: Bool) -> [Meta] {
        switch layout.hero {
        case .off:
            return []
        case .source(let source):
            let picked: [Meta] = heroTitles(source, snapshot: snapshot)
            if !picked.isEmpty { return picked }
            return autoHero(layout, content: content, snapshot: snapshot, classicHome: classicHome)
        case .auto:
            return autoHero(layout, content: content, snapshot: snapshot, classicHome: classicHome)
        }
    }

    /// A chosen hero source's titles (at most 8, no band tiles); empty when it has none this pass.
    static func heroTitles(_ source: HomeRowSource, snapshot: HomeSourceSnapshot) -> [Meta] {
        let metas: [Meta]
        switch HomeSourceRegistry.resolve(source, in: snapshot) {
        case .row(let row):
            metas = row.metas
        case .rows(let rows):
            if let room = source.room, let slides = snapshot.pages[room]?.hero, !slides.isEmpty {
                metas = slides
            } else {
                metas = rows.first { row in row.metas.contains { !bandTypes.contains($0.type) } }?.metas ?? []
            }
        case .resuming(let list):
            metas = list.map { Meta(continue: $0) }
        case .failed, .unavailable:
            metas = []
        }
        return Array(metas.filter { !bandTypes.contains($0.type) }.uniquedById().prefix(8))
    }

    private static func autoHero(_ layout: HomeLayout, content: HomeContent, snapshot: HomeSourceSnapshot, classicHome: Bool) -> [Meta] {
        if classicHome { return [] }
        var seen = Set<HomeRoom>()
        for spec in layout.rows {
            // Continue Watching reads no page, so it has no slides.
            if case .continueWatching = spec.source { continue }
            guard let room = spec.source.room, seen.insert(room).inserted else { continue }
            if let slides = snapshot.pages[room]?.hero, !slides.isEmpty {
                return Array(slides.filter { !bandTypes.contains($0.type) }.uniquedById().prefix(8))
            }
        }
        for row in content.rows {
            let metas: [Meta] = row.metas.filter { !bandTypes.contains($0.type) }
            if !metas.isEmpty { return Array(metas.uniquedById().prefix(5)) }
        }
        return []
    }

    /// Why nothing showed, when a read failed.
    private static func failure(in content: HomeContent) -> String? {
        for skipped in content.skipped {
            if case .failed(let message) = skipped.reason { return message }
        }
        return nil
    }

    /// The titles whose marks the long-press menu reads (no band tiles), as the room feed capped them.
    static func markable(_ content: HomeContent) -> [Meta] {
        let everything: [Meta] = content.hero + content.rows.flatMap { $0.metas }
        return Array(everything.filter { !bandTypes.contains($0.type) }.uniquedById().prefix(80))
    }
}
