import Foundation

/// The Apple TV's Home through the active profile's HomeLayout. RoomView and BrowseModel
/// draw Home exactly as before (the spotlight, Continue Watching as the lead row, the Live TV row, the
/// rail and its bands); only where the rows and the hero come from changes. Home's page is the layout
/// assembled by HomeLayoutLoader.assemble from the same reads the iPhone makes (HomeLayoutLoader.read);
/// every other room goes straight to `base`.
///
/// On the TV, Home's own Continue Watching (`.continueWatching(.home)`) is always the lead row above the
/// rail (BrowseModel reads it through `continueWatching(for: .home)`, which answers nothing when the
/// layout dropped it); every other source is a row of the rail, in layout order. Shared code (no tvOS
/// type) so BrowseModel can see it; the iPhone does not use it.
@MainActor
final class HomeLayoutBrowseSource: BrowseSource {
    /// Where a row of the layout Home came from, for its See all.
    enum RowOrigin: Equatable {
        /// A room page's row: See all pages that room's catalog under the row's own key.
        case room(Room, key: String)
        /// An addon catalog: See all opens the addon's page.
        case addon(base: String, name: String)
        /// No paged list behind it (tracker rails, another room's Continue Watching).
        case unpaged
    }

    enum Failure: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    let base: BrowseSource
    private let extras: HomeExtraSource
    let store: HomeLayoutStore
    /// The last Home page's rows, by the key they were drawn under.
    private(set) var origins: [String: RowOrigin] = [:]
    /// The last Home read and what it covered, so an edit that needs nothing new re-assembles from it.
    private var last: (plan: HomeFetchPlan, snapshot: HomeSourceSnapshot)?
    private var reuseNext = false

    init(base: BrowseSource, extras: HomeExtraSource? = nil, store: HomeLayoutStore? = nil) {
        self.base = base
        self.extras = extras ?? ((Fixtures.active && !Fixtures.liveRooms) ? FixtureHomeExtras() : EngineHomeExtras())
        self.store = store ?? HomeLayoutStore.shared
    }

    var profileId: String { ProfilesStore.shared.active?.id ?? "default" }

    var layout: HomeLayout { store.layout(for: profileId) }

    /// Rooms the profile's PIN locks: their sources are unavailable (as on the iPhone).
    var hiddenRooms: Set<HomeRoom> { Set(HomeRoom.allCases.filter { ParentalGate.shared.hides($0.room) }) }

    // MARK: BrowseSource

    func rows(for room: Room) async throws -> [BrowseRow] {
        try await page(for: room).rows
    }

    func page(for room: Room) async throws -> BrowsePage {
        guard room == .home else { return try await base.page(for: room) }
        let layout = self.layout
        let hidden = hiddenRooms
        var plan = HomeFetchPlan(layout: layout, hiddenRooms: hidden)
        // BrowseModel reads Home's Continue Watching itself, for the lead row (unless it feeds the hero).
        if layout.hero != .source(.continueWatching(.home)) { plan.resuming.remove(.home) }
        let read: HomeSourceSnapshot
        if reuseNext, let last, last.plan.covers(plan) {
            read = last.snapshot
        } else {
            var fresh = await HomeLayoutLoader.read(plan, source: base, extras: extras)
            fresh.hiddenRooms = hidden
            last = (plan, fresh)
            read = fresh
        }
        reuseNext = false
        let content = HomeLayoutLoader.assemble(layout, snapshot: read, classicHome: false)
        let drawn = Self.rows(of: content, snapshot: read)
        origins = drawn.origins
        if drawn.rows.isEmpty, let message = Self.failure(in: content) { throw Failure.failed(message) }
        switch layout.hero {
        case .auto:
            // Today's hero: the first row's titles (BrowseModel's own rule).
            return BrowsePage(rows: drawn.rows, hero: [])
        case .off:
            return BrowsePage(rows: drawn.rows, hero: [], heroCycles: false)
        case .source(let source):
            return BrowsePage(rows: drawn.rows, hero: HomeLayoutLoader.heroTitles(source, snapshot: read))
        }
    }

    func continueWatching(for room: Room) async throws -> [ContinueItem] {
        if room == .home, !layout.rows.contains(where: { $0.source == .continueWatching(.home) }) { return [] }
        return try await base.continueWatching(for: room)
    }

    // MARK: Layout

    /// The next Home read may re-assemble from the last one when it covers the layout (an edit).
    func layoutEdited() { reuseNext = true }

    /// HomeLayoutLoader.reloads for what the last Home read covered. Home's own Continue Watching is
    /// read by BrowseModel (so the plan leaves it out), and it re-reads on harbor:home-updated as it
    /// always did, even when it is the only row left.
    func reloads(on event: String) -> Bool {
        if event == "harbor:home-updated", layout.rows.contains(where: { $0.source == .continueWatching(.home) }) { return true }
        return HomeLayoutLoader.reloads(on: event, plan: last?.plan ?? HomeFetchPlan(layout: layout, hiddenRooms: hiddenRooms))
    }

    /// Names the layout in BrowseModel's cache key: nil for the standard layout (today's slot), else a
    /// stable FNV-1a hash of the layout, so a page cached under one layout never opens another.
    var cacheTag: String? {
        let layout = self.layout
        guard !layout.isDefault else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(layout) else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Everything a row or the hero can come from (all four room pages, both trackers, every addon's
    /// catalogs), for Edit Home's source picker.
    func allSources() async -> HomeSourceSnapshot {
        let hidden = hiddenRooms
        var plan = HomeFetchPlan(layout: HomeLayout(rows: []))
        plan.rooms = Set(HomeRoom.allCases).subtracting(hidden)
        plan.anilist = !hidden.contains(.anime)
        plan.mal = !hidden.contains(.anime)
        var read = await HomeLayoutLoader.read(plan, source: base, extras: extras, allCatalogs: true)
        read.hiddenRooms = hidden
        return read
    }

    func origin(of rowKey: String) -> RowOrigin? { origins[rowKey] }

    // MARK: Assembly

    /// The rail's rows for a resolved Home. Home's own rows keep their engine keys (RoomView's bands,
    /// row tabs and leads key off them, and so do the UI tests); another room's row is keyed
    /// `<room>.<key>` so two rooms' `trending` never collide; Continue Watching of another room is a
    /// wide row of its cards.
    static func rows(of content: HomeContent, snapshot: HomeSourceSnapshot) -> (rows: [BrowseRow], origins: [String: RowOrigin]) {
        var rows: [BrowseRow] = []
        var origins: [String: RowOrigin] = [:]
        for item in content.items {
            switch item.kind {
            case .row(let row):
                let placed = place(item.source, row: row, snapshot: snapshot)
                guard origins[placed.key] == nil else { continue }
                origins[placed.key] = placed.origin
                rows.append(BrowseRow(key: placed.key, title: item.title, metas: row.metas, shape: row.shape))
            case .resuming(let list):
                guard item.source != .continueWatching(.home), let room = item.source.room else { continue }
                let key = "cw-\(room.rawValue)"
                guard origins[key] == nil, !list.isEmpty else { continue }
                origins[key] = RowOrigin.unpaged
                let title: String = item.title == T("Continue Watching") ? "\(T("Continue Watching")) · \(T(room.room.label))" : item.title
                rows.append(BrowseRow(key: key, title: title, metas: list.map { Meta(continue: $0) }, shape: .wide))
            }
        }
        return (rows, origins)
    }

    private static func place(_ source: HomeRowSource, row: BrowseRow, snapshot: HomeSourceSnapshot) -> (key: String, origin: RowOrigin) {
        switch source {
        case .engineRow(let room, let key):
            if room == .home { return (key, .room(.home, key: key)) }
            return ("\(room.rawValue).\(key)", .room(room.room, key: key))
        case .addonCatalog(let base, _):
            let name: String = snapshot.addons.first { $0.base == base }?.name ?? row.title
            return (row.key, .addon(base: base, name: name))
        default:
            return (row.key, .unpaged)
        }
    }

    private static func failure(in content: HomeContent) -> String? {
        for skipped in content.skipped {
            if case .failed(let message) = skipped.reason { return message }
        }
        return nil
    }
}
