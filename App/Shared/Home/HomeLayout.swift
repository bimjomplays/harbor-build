import Foundation

// The customizable Home. A layout is an ordered list of
// rows, each naming where its titles come from, plus where the hero's titles come from. Everything here
// is plain data: the loader (HomeLayoutLoader, iPhone) or HomeLayoutBrowseSource (Apple TV) turns it into
// rows on screen, the store (HomeLayoutStore) keeps one per profile. Shared by both apps (App/Shared/Home),
// so nothing here may name a tvOS-only or iOS-only type.

/// The browse rooms whose engine pages a Home row can come from.
enum HomeRoom: String, Codable, CaseIterable, Identifiable {
    case home, movies, shows, anime
    var id: String { rawValue }

    var room: Room {
        switch self {
        case .home: return .home
        case .movies: return .movies
        case .shows: return .shows
        case .anime: return .anime
        }
    }

    init?(_ room: Room) {
        switch room {
        case .home: self = .home
        case .movies: self = .movies
        case .shows: self = .shows
        case .anime: self = .anime
        default: return nil
        }
    }
}

/// Where one Home row gets its titles. Saved as `{"kind": ..., ...}`; a kind this build does not know
/// (a newer build wrote it, or it was retired) decodes as `.unknown` with its JSON kept, so it survives
/// a save and is skipped on screen, never a crash.
enum HomeRowSource: Equatable {
    /// Every row the room's engine page builds, in engine order (today's Home is `.engineRoom(.home)`).
    /// Rows the layout also places on their own (`.engineRow` of the same room) are left out of it.
    case engineRoom(HomeRoom)
    /// One row of a room page, by its engine key (`bp-top10`, `services`, `addons`, `collections`,
    /// `trending`, a catalog or pinned key, the Trakt / Simkl / Letterboxd / anime extras on Home…).
    case engineRow(room: HomeRoom, key: String)
    /// Continue Watching as that room reads it (Home: everything, Shows: series, Anime: anime).
    case continueWatching(HomeRoom)
    /// One of the viewer's AniList list rails (engine/trackers.ts ANILIST_RAILS keys).
    case anilistList(railKey: String)
    /// One of the viewer's MyAnimeList rails (engine/trackers.ts MAL_RAILS keys).
    case malList(railKey: String)
    /// One catalog of an installed addon: the addon's transport URL and the engine's catalog key
    /// (`addonsRoom.catalogs`), first page only.
    case addonCatalog(base: String, catalog: String)
    case unknown(AnyJSON)

    /// A stable string for de-duping and lookups ("same source twice").
    var identity: String {
        switch self {
        case .engineRoom(let room): return "room:\(room.rawValue)"
        case .engineRow(let room, let key): return "row:\(room.rawValue):\(key)"
        case .continueWatching(let room): return "cw:\(room.rawValue)"
        case .anilistList(let key): return "anilist:\(key)"
        case .malList(let key): return "mal:\(key)"
        case .addonCatalog(let base, let catalog): return "addon:\(base)|\(catalog)"
        case .unknown(let raw):
            if case .object(let o) = raw, case .string(let kind)? = o["kind"] { return "unknown:\(kind)" }
            return "unknown"
        }
    }

    /// The engine room page this source reads, if any.
    var room: HomeRoom? {
        switch self {
        case .engineRoom(let room), .engineRow(let room, _), .continueWatching(let room): return room
        default: return nil
        }
    }

    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

extension HomeRowSource: Codable {
    private enum Keys: String, CodingKey { case kind, room, key, railKey, base, catalog }

    init(from decoder: Decoder) throws {
        // Anything that is not one of ours (wrong kind, a room this build lacks, a missing field)
        // is kept verbatim as `.unknown`.
        let raw: AnyJSON = (try? AnyJSON(from: decoder)) ?? .null
        guard let c = try? decoder.container(keyedBy: Keys.self),
              let kind = try? c.decode(String.self, forKey: .kind) else {
            self = .unknown(raw)
            return
        }
        func room() -> HomeRoom? { (try? c.decode(String.self, forKey: .room)).flatMap(HomeRoom.init(rawValue:)) }
        func text(_ key: Keys) -> String? {
            guard let s = try? c.decode(String.self, forKey: key), !s.isEmpty else { return nil }
            return s
        }
        switch kind {
        case "engineRoom":
            if let r = room() { self = .engineRoom(r); return }
        case "engineRow":
            if let r = room(), let key = text(.key) { self = .engineRow(room: r, key: key); return }
        case "continueWatching":
            // Without a room it means Home's.
            if !c.contains(.room) { self = .continueWatching(.home); return }
            if let r = room() { self = .continueWatching(r); return }
        case "anilistList":
            if let key = text(.railKey) { self = .anilistList(railKey: key); return }
        case "malList":
            if let key = text(.railKey) { self = .malList(railKey: key); return }
        case "addonCatalog":
            if let base = text(.base), let catalog = text(.catalog) { self = .addonCatalog(base: base, catalog: catalog); return }
        default:
            break
        }
        self = .unknown(raw)
    }

    func encode(to encoder: Encoder) throws {
        if case .unknown(let raw) = self {
            try raw.encode(to: encoder)
            return
        }
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .engineRoom(let room):
            try c.encode("engineRoom", forKey: .kind)
            try c.encode(room.rawValue, forKey: .room)
        case .engineRow(let room, let key):
            try c.encode("engineRow", forKey: .kind)
            try c.encode(room.rawValue, forKey: .room)
            try c.encode(key, forKey: .key)
        case .continueWatching(let room):
            try c.encode("continueWatching", forKey: .kind)
            try c.encode(room.rawValue, forKey: .room)
        case .anilistList(let key):
            try c.encode("anilistList", forKey: .kind)
            try c.encode(key, forKey: .railKey)
        case .malList(let key):
            try c.encode("malList", forKey: .kind)
            try c.encode(key, forKey: .railKey)
        case .addonCatalog(let base, let catalog):
            try c.encode("addonCatalog", forKey: .kind)
            try c.encode(base, forKey: .base)
            try c.encode(catalog, forKey: .catalog)
        case .unknown:
            break
        }
    }
}

/// How a row draws, over what its source says. Every field is optional: nil keeps the source's own.
struct HomeRowOptions: Codable, Equatable {
    /// `.rank` gives a row Top-10 numerals, `.poster` / `.wide` take them away. Band rows (brand,
    /// collection) keep their own tiles whatever is set here.
    var shape: TileShape?
    /// At most this many titles (nil: all the source returns).
    var limit: Int?

    init(shape: TileShape? = nil, limit: Int? = nil) {
        self.shape = shape
        self.limit = limit
    }

    private enum Keys: String, CodingKey { case shape, limit }

    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: Keys.self)
        let rawShape: String? = c.flatMap { try? $0.decodeIfPresent(String.self, forKey: .shape) }
        shape = rawShape.flatMap { TileShape(rawValue: $0) }
        let n: Int? = c.flatMap { try? $0.decodeIfPresent(Int.self, forKey: .limit) }
        limit = n.flatMap { $0 > 0 ? $0 : nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(shape?.rawValue, forKey: .shape)
        try c.encodeIfPresent(limit, forKey: .limit)
    }

    var isEmpty: Bool { shape == nil && limit == nil }
}

/// One row of a layout.
struct HomeRowSpec: Codable, Equatable, Identifiable {
    /// Stable for the row's life (a UUID string), so a move or a rename keeps it.
    var id: String
    var source: HomeRowSource
    /// The owner's own name for the row (nil: the source's title).
    var title: String?
    /// The source's title when the row was added, so a row whose source has gone can still be named.
    var savedTitle: String?
    var options: HomeRowOptions

    init(id: String = UUID().uuidString, source: HomeRowSource, title: String? = nil, savedTitle: String? = nil,
         options: HomeRowOptions = HomeRowOptions()) {
        self.id = id
        self.source = source
        self.title = title
        self.savedTitle = savedTitle
        self.options = options
    }

    private enum Keys: String, CodingKey { case id, source, title, savedTitle, options }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let id = (try? c.decode(String.self, forKey: .id)) ?? ""
        self.id = id.isEmpty ? UUID().uuidString : id
        source = (try? c.decode(HomeRowSource.self, forKey: .source)) ?? .unknown(.null)
        let title: String? = try? c.decodeIfPresent(String.self, forKey: .title)
        self.title = title
        let savedTitle: String? = try? c.decodeIfPresent(String.self, forKey: .savedTitle)
        self.savedTitle = savedTitle
        let options: HomeRowOptions? = try? c.decodeIfPresent(HomeRowOptions.self, forKey: .options)
        self.options = options ?? HomeRowOptions()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(savedTitle, forKey: .savedTitle)
        if !options.isEmpty { try c.encode(options, forKey: .options) }
    }
}

/// Where the hero carousel's titles come from.
enum HomeHeroSource: Equatable {
    /// Today's behaviour: the hero slides of the first engine page the layout reads, else the first
    /// row's titles; none on Classic Home.
    case auto
    /// No hero.
    case off
    /// The titles of any one row source (it need not be a row on the screen).
    case source(HomeRowSource)
}

extension HomeHeroSource: Codable {
    private enum Keys: String, CodingKey { case kind, source }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Keys.self),
              let kind = try? c.decode(String.self, forKey: .kind) else {
            self = .auto
            return
        }
        switch kind {
        case "off": self = .off
        case "source":
            // An unreadable hero source falls back to Auto instead of an empty hero.
            if let s = try? c.decode(HomeRowSource.self, forKey: .source), s.isKnown { self = .source(s) } else { self = .auto }
        default: self = .auto
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .auto: try c.encode("auto", forKey: .kind)
        case .off: try c.encode("off", forKey: .kind)
        case .source(let s):
            try c.encode("source", forKey: .kind)
            try c.encode(s, forKey: .source)
        }
    }
}

/// A whole Home: the hero's source and the rows top to bottom.
struct HomeLayout: Codable, Equatable {
    var hero: HomeHeroSource
    var rows: [HomeRowSpec]

    init(hero: HomeHeroSource = .auto, rows: [HomeRowSpec]) {
        self.hero = hero
        self.rows = rows
    }

    private enum Keys: String, CodingKey { case hero, rows }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let decodedHero: HomeHeroSource? = try? c.decodeIfPresent(HomeHeroSource.self, forKey: .hero)
        hero = decodedHero ?? .auto
        // One unreadable row never empties the layout.
        let lossy: LossyArray<HomeRowSpec>? = try? c.decodeIfPresent(LossyArray<HomeRowSpec>.self, forKey: .rows)
        rows = lossy?.wrappedValue ?? []
        // Two rows with one id would confuse every list on screen: later ones get a new id.
        var seen = Set<String>()
        for i in rows.indices where !seen.insert(rows[i].id).inserted {
            rows[i].id = UUID().uuidString
            seen.insert(rows[i].id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(hero, forKey: .hero)
        try c.encode(rows, forKey: .rows)
    }

    // MARK: Defaults

    /// Fixed ids for the default rows, so two fresh layouts compare equal and `isDefault` holds.
    static let defaultContinueWatchingId = "default-continue-watching"
    static let defaultHomeRowsId = "default-home-rows"

    /// What Home showed before it could be arranged: the hero (Auto), Continue Watching, then every
    /// row the Home page builds in engine order (late rows and new extras included as they come).
    /// Movies, Shows and Anime rows are not on it but stay addable (HomeSourceRegistry).
    static var standard: HomeLayout {
        HomeLayout(hero: .auto, rows: [
            HomeRowSpec(id: defaultContinueWatchingId, source: .continueWatching(.home)),
            HomeRowSpec(id: defaultHomeRowsId, source: .engineRoom(.home)),
        ])
    }

    var isDefault: Bool { self == HomeLayout.standard }

    // MARK: Editing

    func index(of id: String) -> Int? { rows.firstIndex { $0.id == id } }

    func contains(_ source: HomeRowSource) -> Bool { rows.contains { $0.source.identity == source.identity } }

    /// Adds a row (at the end when `index` is nil or past it) and returns its id.
    @discardableResult
    mutating func insert(_ source: HomeRowSource, title: String? = nil, savedTitle: String? = nil,
                         options: HomeRowOptions = HomeRowOptions(), at index: Int? = nil) -> String {
        let spec = HomeRowSpec(source: source, title: title, savedTitle: savedTitle, options: options)
        insert(spec, at: index)
        return spec.id
    }

    mutating func insert(_ spec: HomeRowSpec, at index: Int? = nil) {
        var spec = spec
        if rows.contains(where: { $0.id == spec.id }) { spec.id = UUID().uuidString }
        let at = min(max(0, index ?? rows.count), rows.count)
        rows.insert(spec, at: at)
    }

    @discardableResult
    mutating func remove(id: String) -> HomeRowSpec? {
        guard let i = index(of: id) else { return nil }
        return rows.remove(at: i)
    }

    mutating func remove(atOffsets offsets: IndexSet) {
        for i in offsets.sorted(by: >) where rows.indices.contains(i) { rows.remove(at: i) }
    }

    /// SwiftUI's `onMove` contract: `destination` is an index in the list before the move.
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let picked = source.filter { rows.indices.contains($0) }.sorted()
        guard !picked.isEmpty else { return }
        let moving = picked.map { rows[$0] }
        let before = picked.filter { $0 < destination }.count
        for i in picked.reversed() { rows.remove(at: i) }
        let at = min(max(0, destination - before), rows.count)
        rows.insert(contentsOf: moving, at: at)
    }

    /// Up (negative) or down (positive) by `delta` places, clamped to the list. False when it did not move.
    @discardableResult
    mutating func move(id: String, by delta: Int) -> Bool {
        guard let from = index(of: id) else { return false }
        let to = min(max(0, from + delta), rows.count - 1)
        guard to != from else { return false }
        let spec = rows.remove(at: from)
        rows.insert(spec, at: to)
        return true
    }

    /// A new name for a row; empty or whitespace goes back to the source's own.
    mutating func rename(id: String, to title: String?) {
        guard let i = index(of: id) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        rows[i].title = trimmed.isEmpty ? nil : trimmed
    }

    mutating func setOptions(id: String, _ options: HomeRowOptions) {
        guard let i = index(of: id) else { return }
        rows[i].options = options
    }

    /// Replaces a whole-room row with that room's rows one by one (in the order given, normally the
    /// order the page last built), so each can be moved or removed on its own. Rows the layout
    /// already places elsewhere are not added twice. False when `id` is not a whole-room row.
    @discardableResult
    mutating func expandRoom(id: String, rows pageRows: [BrowseRow]) -> Bool {
        guard let i = index(of: id), case .engineRoom(let room) = rows[i].source else { return false }
        let options = rows[i].options
        rows.remove(at: i)
        var placed = Set(rows.map { $0.source.identity })
        var specs: [HomeRowSpec] = []
        for row in pageRows {
            let source = HomeRowSource.engineRow(room: room, key: row.key)
            guard placed.insert(source.identity).inserted else { continue }
            specs.append(HomeRowSpec(source: source, savedTitle: row.title, options: options))
        }
        rows.insert(contentsOf: specs, at: i)
        return true
    }
}
