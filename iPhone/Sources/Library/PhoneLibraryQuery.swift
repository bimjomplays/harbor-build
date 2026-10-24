import Foundation

/// One view of the phone Library. The four segments sit over the engine's
/// library tabs: Saved is `library`, Watchlist is `watchlist`, and In progress and Watched are the two
/// halves of `history` (its Posters view, one card per title). Every other tab the engine offers
/// (My Lists, Favorites, Media Servers, Trakt, AniList, MyAnimeList, Simkl, Letterboxd) is reached
/// from the Library's menu as `.tab`, with no segment lit.
enum PhoneLibraryFilter: Hashable, Identifiable {
    case saved, watchlist, inProgress, watched
    case tab(String)

    static let segments: [PhoneLibraryFilter] = [.saved, .watchlist, .inProgress, .watched]

    /// The engine tabs the segments stand for: the menu lists the others.
    static let segmentTabs: Set<String> = ["library", "watchlist", "history"]

    /// The view a kept engine tab (ShellViewState.libraryTab) opens on; History opens on In progress.
    init(engineTab: String?) {
        switch engineTab ?? "" {
        case "", "library": self = .saved
        case "watchlist": self = .watchlist
        case "history": self = .inProgress
        case let other: self = .tab(other)
        }
    }

    var engineTab: String {
        switch self {
        case .saved: return "library"
        case .watchlist: return "watchlist"
        case .inProgress, .watched: return "history"
        case .tab(let id): return id
        }
    }

    var id: String {
        switch self {
        case .saved: return "saved"
        case .watchlist: return "watchlist"
        case .inProgress: return "in-progress"
        case .watched: return "watched"
        case .tab(let id): return id
        }
    }

    /// The segment's label; a menu tab is named by the engine's tab list.
    var label: String {
        switch self {
        case .saved: return T("Saved")
        case .watchlist: return T("Watchlist")
        case .inProgress: return T("In progress")
        case .watched: return T("Watched")
        case .tab: return ""
        }
    }

    var isSegment: Bool {
        if case .tab = self { return false }
        return true
    }

    /// In progress and Watched split the history feed between them.
    var splitsHistory: Bool { self == .inProgress || self == .watched }
}

/// What a swipe's Remove does to an entry of the view on screen.
enum PhoneLibraryRemoval: Equatable {
    /// Saved and Watchlist: actions.setWatchlist off (the detail page's and long press's Remove from Watchlist).
    case watchlist
    /// In progress: rooms.dismissContinueWatching, as Home's Remove from Continue Watching.
    case continueWatching
    /// My Lists: actions.toggleList on the entry's list.
    case list(String)
    /// Favorites: actions.toggleFavorite.
    case favorite
}

/// What the Library shows while no title of the view is on screen.
enum PhoneLibraryNothingShown: Equatable {
    /// The read failed: the error plate with Try again.
    case error
    /// The engine has more pages: the pager, so the next page is read. In progress and Watched
    /// split a history the engine sorts and pages whole, so a page can hold no title of the half
    /// on screen while later pages do (A-Z with few titles in progress, say).
    case paging
    /// The view is really empty: the empty copy.
    case empty
}

/// The Library's pure parts: the history split, what a swipe removes, and the offline (fixture)
/// query that stands in for the engine's libraryRoom.feed. Unit-tested (PhoneLibraryTests).
enum PhoneLibraryQuery {
    /// history-merge.ts: an entry is watched when flagged, played through, or 90 % in. In progress
    /// is what Continue Watching would resume: started, not finished, not marked watched here. The
    /// rest of the history (finished titles, Trakt plays with no progress, cleared resumes) is Watched.
    static func isInProgress(_ entry: LibraryModel.Entry, watchedOverride: Bool? = nil) -> Bool {
        let progress = entry.progress ?? 0
        guard progress > 0, progress < 1 else { return false }
        return !(watchedOverride ?? (entry.watched == true))
    }

    /// The sections a view shows: the feed's, with History split into the view's half, the entries
    /// removed here dropped, and sections left empty dropped.
    static func sections(_ feed: [LibraryModel.Section], filter: PhoneLibraryFilter, removed: Set<String>,
                         watchedOverrides: [String: Bool] = [:], dismissed: Set<String> = []) -> [LibraryModel.Section] {
        feed.compactMap { section in
            let items: [LibraryModel.Entry] = section.items.filter { entry in
                if removed.contains(entry.key) { return false }
                switch filter {
                case .inProgress:
                    return !dismissed.contains(entry.meta.id) && isInProgress(entry, watchedOverride: watchedOverrides[entry.meta.id])
                case .watched:
                    return !isInProgress(entry, watchedOverride: watchedOverrides[entry.meta.id])
                default:
                    return true
                }
            }
            guard !items.isEmpty else { return nil }
            let dropped = section.items.count - items.count
            return LibraryModel.Section(label: section.label, items: items, total: max(items.count, section.total - dropped))
        }
    }

    /// The view has no titles on screen: an error, a page still to read, or the empty copy.
    static func nothingShown(status: String, hasMore: Bool) -> PhoneLibraryNothingShown {
        if status == "error" { return .error }
        return hasMore ? .paging : .empty
    }

    /// What Remove does here; nil where the view has no remove (Watched is a record of plays, the
    /// services and Media Servers are read-only from Harbor).
    static func removal(for filter: PhoneLibraryFilter, entry: LibraryModel.Entry) -> PhoneLibraryRemoval? {
        switch filter {
        case .saved, .watchlist: return .watchlist
        case .inProgress: return .continueWatching
        case .watched: return nil
        case .tab("lists"): return entry.group.map { .list($0) }
        case .tab("favorites"): return .favorite
        case .tab: return nil
        }
    }

    /// shared.tsx releaseYear: the first four digits of releaseInfo, 0 without one.
    static func releaseYear(_ meta: Meta) -> Int {
        guard let info = meta.releaseInfo else { return 0 }
        let digits = info.prefix { $0.isNumber }
        return digits.count >= 4 ? Int(digits.prefix(4)) ?? 0 : 0
    }

    /// The engine's feed (library.ts feed + shared.tsx applyFilter / sortedGroups) over entries
    /// already in hand: type and title filter, then Recent (newest first), A-Z or Year (newest
    /// first). Recent is one unlabelled list here (the date groups are the engine's).
    static func feed(tab: String, entries: [LibraryModel.Entry], type: String, sort: String, query: String,
                     groups: [LibraryModel.Group] = [], group: String? = nil, failed: Bool = false) -> LibraryModel.Feed {
        let scoped: [LibraryModel.Entry] = failed ? [] : entries.filter { group == nil || $0.group == group }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = scoped.filter { e in
            if type != "all" && e.meta.type != type { return false }
            if !q.isEmpty && !e.meta.name.lowercased().contains(q) { return false }
            return true
        }
        let section: LibraryModel.Section?
        if filtered.isEmpty {
            section = nil
        } else {
            switch sort {
            case "title":
                let items = filtered.sorted { $0.meta.name.compare($1.meta.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedAscending }
                section = LibraryModel.Section(label: "A to Z", items: items, total: items.count)
            case "year":
                let items = filtered.sorted { releaseYear($0.meta) > releaseYear($1.meta) }
                section = LibraryModel.Section(label: "By year", items: items, total: items.count)
            default:
                let items = filtered.sorted { ($0.date ?? -Double.infinity) > ($1.date ?? -Double.infinity) }
                section = LibraryModel.Section(label: "", items: items, total: items.count)
            }
        }
        let counts = LibraryModel.Counts(all: scoped.count, movie: scoped.filter { $0.meta.type == "movie" }.count,
                                         series: scoped.filter { $0.meta.type == "series" }.count)
        let countedGroups = groups.map { g in
            LibraryModel.Group(id: g.id, label: g.label, count: entries.filter { $0.group == g.id }.count)
        }
        return LibraryModel.Feed(tab: tab, sections: section.map { [$0] } ?? [], shown: filtered.count, matched: filtered.count,
                                 total: scoped.count, hasMore: false, groups: countedGroups, status: failed ? "error" : "ready",
                                 hidden: 0, signedIn: true, sort: sort, counts: counts,
                                 dated: filtered.contains { $0.date != nil }, years: filtered.contains { releaseYear($0.meta) > 0 },
                                 owned: nil, entries: entries.count, libraries: nil, genres: nil, pending: nil)
    }
}
