import Foundation

/// A tracker's list rails as the engine reads them (`anilist.rails` / `mal.rails`): one `BrowseRow` per
/// rail that has titles, keyed by the rail key.
struct HomeTrackerState: Equatable {
    var signedIn: Bool
    var loading: Bool = false
    var rails: [BrowseRow] = []
}

/// One catalog of an installed addon (`addonsRoom.catalogs`), with the cursor its feed pages from.
struct HomeAddonCatalog: Equatable {
    var base: String
    var addon: String
    var key: String
    var name: String
    var type: String
    var cursor: AnyJSON
}

/// Everything the loader read for one pass: the room pages, Continue Watching, the tracker rails and
/// the addon catalogs. The registry lists and resolves sources against it, so it never calls the
/// engine itself (and the unit tests build one by hand).
struct HomeSourceSnapshot {
    var pages: [HomeRoom: BrowsePage] = [:]
    /// A room page that was asked for and failed, with the error's text.
    var pageErrors: [HomeRoom: String] = [:]
    var resuming: [HomeRoom: [ContinueItem]] = [:]
    /// nil: not read this pass.
    var anilist: HomeTrackerState?
    var mal: HomeTrackerState?
    /// The installed addons whose catalog lists were read, by base, in install order.
    var addons: [(base: String, name: String)] = []
    var addonCatalogs: [String: [HomeAddonCatalog]] = [:]
    /// First pages of addon catalogs, by `HomeRowSource.identity`.
    var addonFeeds: [String: [Meta]] = [:]
    /// Rooms the parental gate hides for this profile: their sources are unavailable.
    var hiddenRooms: Set<HomeRoom> = []
}

/// One source the phone can offer for a row (or the hero).
struct HomeSourceEntry: Identifiable, Equatable {
    enum Group: String, CaseIterable {
        case home, movies, shows, anime, anilist, mal, addons

        var title: String {
            switch self {
            case .home: return T("Home")
            case .movies: return T("Movies")
            case .shows: return T("Shows")
            case .anime: return T("Anime")
            case .anilist: return "AniList"
            case .mal: return "MyAnimeList"
            case .addons: return T("Addons")
            }
        }
    }

    enum Availability: Equatable {
        case available
        /// The account behind it is not connected (AniList, MyAnimeList).
        case needsSignIn
        /// Nothing serves it now: the row left its page, the addon was removed, a room is hidden.
        case unavailable
    }

    var source: HomeRowSource
    var title: String
    var subtitle: String?
    var systemImage: String
    var group: Group
    var availability: Availability
    var id: String { source.identity }
}

/// What a source gives a row on one pass.
enum HomeResolution: Equatable {
    case row(BrowseRow)
    /// A whole room page: its rows in engine order.
    case rows([BrowseRow])
    case resuming([ContinueItem])
    /// Its data was asked for and failed (a room page error): kept, shown again next pass.
    case failed(String)
    /// Nothing serves it any more (or this build does not know it): kept in the layout, skipped.
    case unavailable
}

/// One kind of source: which entries it offers and how it turns a source into titles. A new kind of
/// source is one case in `HomeRowSource`, one provider here, and (when it reads something new) one
/// fetch in `HomeLayoutLoader.fetch`.
struct HomeSourceProvider {
    let id: String
    let entries: (HomeSourceSnapshot) -> [HomeSourceEntry]
    /// nil when the source is not this provider's.
    let resolve: (HomeRowSource, HomeSourceSnapshot) -> HomeResolution?
}

enum HomeSourceRegistry {
    /// engine/trackers.ts ANILIST_RAILS (key, title), in its order.
    static let anilistRails: [(key: String, title: String)] = [
        ("watching", "Watching"), ("planning", "Plan to Watch"), ("completed", "Completed"), ("paused", "On Hold"), ("dropped", "Dropped"),
    ]
    /// engine/trackers.ts MAL_RAILS (key, title), in its order.
    static let malRails: [(key: String, title: String)] = [
        ("watching", "Watching"), ("planning", "Plan to Watch"), ("completed", "Completed"), ("onhold", "On Hold"), ("dropped", "Dropped"),
    ]

    static let providers: [HomeSourceProvider] = [continueWatching, engineRooms, engineRows, anilist, mal, addonCatalogs]

    /// Every source on offer for this snapshot, providers in order.
    static func entries(in snapshot: HomeSourceSnapshot) -> [HomeSourceEntry] {
        providers.flatMap { $0.entries(snapshot) }
    }

    static func entry(for source: HomeRowSource, in snapshot: HomeSourceSnapshot) -> HomeSourceEntry? {
        entries(in: snapshot).first { $0.source.identity == source.identity }
    }

    static func resolve(_ source: HomeRowSource, in snapshot: HomeSourceSnapshot) -> HomeResolution {
        guard source.isKnown else { return .unavailable }
        for provider in providers {
            if let resolution = provider.resolve(source, snapshot) { return resolution }
        }
        return .unavailable
    }

    /// The title a row shows: the owner's own, else the source's current one, else the one it had
    /// when it was added.
    static func title(for spec: HomeRowSpec, resolved: BrowseRow?) -> String {
        if let own = spec.title, !own.isEmpty { return own }
        if let row = resolved, !row.title.isEmpty { return row.title }
        return spec.savedTitle ?? ""
    }

    // MARK: Providers

    static let continueWatching = HomeSourceProvider(
        id: "continueWatching",
        entries: { snapshot in
            // bp-movies has no Continue Watching row (EngineBrowseSource returns none for it).
            [HomeRoom.home, .shows, .anime].map { room -> HomeSourceEntry in
                let title: String = room == .home ? T("Continue Watching") : "\(T("Continue Watching")) · \(T(room.room.label))"
                return HomeSourceEntry(source: .continueWatching(room), title: title, subtitle: nil, systemImage: "play.circle",
                                       group: HomeSourceRegistry.group(for: room), availability: snapshot.hiddenRooms.contains(room) ? .unavailable : .available)
            }
        },
        resolve: { source, snapshot in
            guard case .continueWatching(let room) = source else { return nil }
            if snapshot.hiddenRooms.contains(room) || room == .movies { return .unavailable }
            return .resuming(snapshot.resuming[room] ?? [])
        }
    )

    static let engineRooms = HomeSourceProvider(
        id: "engineRoom",
        entries: { snapshot in
            HomeRoom.allCases.map { room in
                HomeSourceEntry(source: .engineRoom(room), title: room == .home ? T("Home rows") : "\(T("All rows")) · \(T(room.room.label))",
                                subtitle: T("Every row this page builds, in its order"), systemImage: room.room.icon,
                                group: HomeSourceRegistry.group(for: room), availability: snapshot.hiddenRooms.contains(room) ? .unavailable : .available)
            }
        },
        resolve: { source, snapshot in
            guard case .engineRoom(let room) = source else { return nil }
            if snapshot.hiddenRooms.contains(room) { return .unavailable }
            if let page = snapshot.pages[room] { return .rows(page.rows) }
            if let error = snapshot.pageErrors[room] { return .failed(error) }
            return .rows([])
        }
    )

    /// Every row the room pages built this pass. A row a page did not build this time (a late row,
    /// one whose account was disconnected) is not listed; a saved one resolves as unavailable.
    static let engineRows = HomeSourceProvider(
        id: "engineRow",
        entries: { snapshot in
            HomeRoom.allCases.flatMap { room -> [HomeSourceEntry] in
                guard let page = snapshot.pages[room] else { return [] }
                let hidden = snapshot.hiddenRooms.contains(room)
                return page.rows.map { row in
                    HomeSourceEntry(source: .engineRow(room: room, key: row.key), title: row.title, subtitle: nil,
                                    systemImage: HomeSourceRegistry.rowIcon(row), group: HomeSourceRegistry.group(for: room), availability: hidden ? .unavailable : .available)
                }
            }
        },
        resolve: { source, snapshot in
            guard case .engineRow(let room, let key) = source else { return nil }
            if snapshot.hiddenRooms.contains(room) { return .unavailable }
            if let page = snapshot.pages[room] {
                guard let row = page.rows.first(where: { $0.key == key }) else { return .unavailable }
                return .row(row)
            }
            if let error = snapshot.pageErrors[room] { return .failed(error) }
            return .unavailable
        }
    )

    static let anilist = HomeSourceProvider(
        id: "anilist",
        entries: { snapshot in HomeSourceRegistry.trackerEntries(HomeSourceRegistry.anilistRails, state: snapshot.anilist, snapshot: snapshot, group: .anilist) { .anilistList(railKey: $0) } },
        resolve: { source, snapshot in
            guard case .anilistList(let key) = source else { return nil }
            return HomeSourceRegistry.trackerResolve(key, known: HomeSourceRegistry.anilistRails, state: snapshot.anilist, snapshot: snapshot, prefix: "anilist")
        }
    )

    static let mal = HomeSourceProvider(
        id: "mal",
        entries: { snapshot in HomeSourceRegistry.trackerEntries(HomeSourceRegistry.malRails, state: snapshot.mal, snapshot: snapshot, group: .mal) { .malList(railKey: $0) } },
        resolve: { source, snapshot in
            guard case .malList(let key) = source else { return nil }
            return HomeSourceRegistry.trackerResolve(key, known: HomeSourceRegistry.malRails, state: snapshot.mal, snapshot: snapshot, prefix: "mal")
        }
    )

    static let addonCatalogs = HomeSourceProvider(
        id: "addonCatalog",
        entries: { snapshot in
            snapshot.addons.flatMap { addon -> [HomeSourceEntry] in
                (snapshot.addonCatalogs[addon.base] ?? []).map { catalog in
                    HomeSourceEntry(source: .addonCatalog(base: catalog.base, catalog: catalog.key), title: catalog.name,
                                    subtitle: "\(addon.name) · \(catalog.type)", systemImage: "puzzlepiece.extension",
                                    group: .addons, availability: .available)
                }
            }
        },
        resolve: { source, snapshot in
            guard case .addonCatalog(let base, let key) = source else { return nil }
            // The addon's catalog list was read and this catalog is not in it (or the addon is gone).
            guard let catalogs = snapshot.addonCatalogs[base], let catalog = catalogs.first(where: { $0.key == key }) else { return .unavailable }
            let metas: [Meta] = snapshot.addonFeeds[source.identity] ?? []
            return .row(BrowseRow(key: "addon:\(base)|\(key)", title: catalog.name, metas: metas, shape: .poster))
        }
    )

    // MARK: Helpers

    static func group(for room: HomeRoom) -> HomeSourceEntry.Group {
        switch room {
        case .home: return .home
        case .movies: return .movies
        case .shows: return .shows
        case .anime: return .anime
        }
    }

    /// An icon from what the row is: the bands, a Top 10, an account's rails on Home, else a catalog.
    static func rowIcon(_ row: BrowseRow) -> String {
        let key = row.key.lowercased()
        switch key {
        case "services": return "play.tv"
        case "addons": return "puzzlepiece.extension"
        case "collections": return "square.stack"
        default: break
        }
        if row.shape == .rank { return "list.number" }
        if key.hasPrefix("trakt") || key.hasPrefix("simkl") || key.hasPrefix("letterboxd") || key.hasPrefix("lb-") { return "person.crop.circle" }
        if key.hasPrefix("harbor-favorites") { return "heart" }
        if key.hasPrefix("harbor-watchlist") { return "bookmark" }
        if key.hasPrefix("list-") || key.hasPrefix("collection-") { return "list.bullet" }
        return "rectangle.stack"
    }

    static func trackerEntries(_ known: [(key: String, title: String)], state: HomeTrackerState?, snapshot: HomeSourceSnapshot,
                                       group: HomeSourceEntry.Group, make: (String) -> HomeRowSource) -> [HomeSourceEntry] {
        let availability: HomeSourceEntry.Availability
        if snapshot.hiddenRooms.contains(.anime) { availability = .unavailable }
        else if state?.signedIn == true { availability = .available }
        else { availability = .needsSignIn }
        return known.map { rail in
            HomeSourceEntry(source: make(rail.key), title: "\(group.title) · \(T(rail.title))", subtitle: nil,
                            systemImage: "list.star", group: group, availability: availability)
        }
    }

    static func trackerResolve(_ key: String, known: [(key: String, title: String)], state: HomeTrackerState?,
                                       snapshot: HomeSourceSnapshot, prefix: String) -> HomeResolution {
        guard let rail = known.first(where: { $0.key == key }), !snapshot.hiddenRooms.contains(.anime),
              let state, state.signedIn else { return .unavailable }
        // The engine leaves out a rail with no titles: an empty row, not a missing one.
        let metas: [Meta] = state.rails.first(where: { $0.key == key })?.metas ?? []
        let name: String = prefix == "anilist" ? "AniList" : "MyAnimeList"
        return .row(BrowseRow(key: "\(prefix):\(key)", title: "\(name) · \(T(rail.title))", metas: metas, shape: .poster))
    }
}
