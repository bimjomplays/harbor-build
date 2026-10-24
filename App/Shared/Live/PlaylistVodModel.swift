import SwiftUI

/// Playlist VOD (views/playlist-vod.tsx, playlist-vod/*): the movies and series an IPTV source
/// carries besides its live channels. Source chips, Movies / Shows tabs with counts, a search,
/// a poster grid that loads 60 more as the ring reaches the end, and a series page with season
/// chips and episode rows (progress from the local resume store). Playback goes through the
/// normal player with the VOD cache profile and resumes where the viewer left off.
@MainActor
final class PlaylistVodModel: ObservableObject {
    struct Source: Decodable, Identifiable { var id: String; var name: String; var kind: String }
    struct Sources: Decodable { var sources: [Source]; var activeId: String? }
    struct Status: Decodable {
        var playlistId: String; var kind: String; var movies: Int; var series: Int
        var moviesLoading: Bool; var seriesLoading: Bool
        var movieError: String?; var seriesError: String?
        var movieTotal: Int?; var seriesTotal: Int?; var fetchedAt: Double?
    }
    struct Item: Decodable, Identifiable, Equatable {
        var id: String; var kind: String; var title: String; var year: Int?; var logo: String?; var group: String?
        var subtitle: String?; var url: String?; var playlistName: String?; var resumeSec: Double?
    }
    struct Page: Decodable { var items: [Item]; var total: Int; var libraryTotal: Int }
    struct Episode: Decodable, Identifiable, Equatable {
        var season: Int; var episode: Int; var title: String; var url: String; var logo: String?
        var durationSec: Double?; var plot: String?; var progress: Double; var leftSec: Double; var watched: Bool; var resumeSec: Double
        var id: String { "\(season)-\(episode)-\(url)" }
    }
    struct Series: Decodable, Equatable { var id: String; var title: String; var logo: String?; var group: String?; var playlistName: String?; var seasons: [Int]; var episodes: [Episode] }
    struct Playback: Decodable, Identifiable { var meta: Meta; var url: String; var title: String; var subtitle: String; var season: Int?; var episode: Int?; var id: String { url } }

    enum Tab: String { case movies, series }
    /// playlist-vod.tsx PAGE_SIZE.
    static let pageSize = 60

    @Published private(set) var sources: [Source] = []
    @Published private(set) var activeId: String?
    @Published private(set) var status: Status?
    @Published private(set) var items: [Item] = []
    @Published private(set) var total = 0
    @Published private(set) var libraryTotal = 0
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var tab: Tab = .movies
    @Published var query = ""
    /// The open series page (playlist-vod.tsx `selected`); `loadingSeries` while Xtream fetches its episodes.
    @Published private(set) var selected: Series?
    @Published private(set) var loadingSeries = false
    @Published private(set) var seriesError: String?

    private var pageGeneration = 0
    private var loadGeneration = 0
    private var pagingInFlight = false
    /// `.task` runs again whenever the player's cover closes: the whole library
    /// load started over (the loading line came back) and the grid went back to its first 60, so
    /// a title played from further down took the ring with it. Once per visit; Refresh and Try
    /// again load again, and the player's close re-reads the rows on screen (`refreshShown`).
    private var started = false

    var activeSource: Source? { sources.first { $0.id == activeId } }

    func start() async {
        guard !started else { return }
        started = true
        if let s: Sources = try? await HarborEngine.shared.call("liveVod.sources", []) {
            sources = s.sources
            activeId = s.activeId
        }
        await load(force: false)
    }

    func select(_ id: String) async {
        guard id != activeId else { return }
        activeId = id
        selected = nil
        _ = try? await HarborEngine.shared.callJSON("liveVod.setActive", [.string(id)])
        items = []; total = 0; libraryTotal = 0; status = nil
        await load(force: false)
    }

    /// use-xtream-vod-library load / useIptvPlaylist: the library, with the loading line kept
    /// current while a big Xtream catalogue is still being read.
    func load(force: Bool) async {
        guard let id = activeId else { return }
        // Only the newest load drives the loading line: switching source mid-load let the
        // old source's poll overwrite the new one's progress and its end clear the new spinner.
        loadGeneration += 1
        let generation = loadGeneration
        loading = true
        error = nil
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard let self, let s: Status = try? await HarborEngine.shared.call("liveVod.status", [id]) else { continue }
                guard !Task.isCancelled, self.loadGeneration == generation, self.activeId == id else { return }
                self.status = s
                // Batches keep arriving: fill the first screen as soon as there is something to show.
                if self.items.count < Self.pageSize { await self.reloadPage() }
            }
        }
        do {
            let s: Status = try await HarborEngine.shared.call("liveVod.load", [id, force])
            if activeId == id { status = s }
        } catch {
            if activeId == id { self.error = error.localizedDescription }
        }
        poll.cancel()
        guard loadGeneration == generation else { return }
        loading = false
        if activeId == id { await reloadPage() }
    }

    /// The first page for the current tab and query (a newer ask wins).
    func reloadPage() async {
        guard let id = activeId else { return }
        pageGeneration += 1
        let mine = pageGeneration
        guard let p: Page = try? await HarborEngine.shared.call("liveVod.page", [id, tab.rawValue, query, 0, Self.pageSize]) else { return }
        guard mine == pageGeneration else { return }
        items = p.items
        total = p.total
        libraryTotal = p.libraryTotal
    }

    /// The rows on screen read again in place (a played movie's resume chip),
    /// as many as are loaded, so the grid keeps its length and the ring its card.
    func refreshShown() async {
        guard let id = activeId else { return }
        pageGeneration += 1
        let mine = pageGeneration
        let want: Int = max(Self.pageSize, items.count)
        var fresh: [Item] = []
        var seen = Set<String>()
        var offset = 0
        var newTotal = total
        var newLibraryTotal = libraryTotal
        while offset < want {
            let ask: Int = min(200, want - offset)
            guard let p: Page = try? await HarborEngine.shared.call("liveVod.page", [id, tab.rawValue, query, offset, ask]) else { return }
            guard mine == pageGeneration else { return }
            newTotal = p.total
            newLibraryTotal = p.libraryTotal
            fresh += p.items.filter { seen.insert($0.id).inserted }
            offset += ask
            if p.items.count < ask { break }
        }
        items = fresh
        total = newTotal
        libraryTotal = newLibraryTotal
    }

    /// playlist-vod.tsx loadMore: the next 60 once the ring nears the end of the grid.
    func loadMore() async {
        guard let id = activeId, !pagingInFlight, items.count < total else { return }
        pagingInFlight = true
        defer { pagingInFlight = false }
        let mine = pageGeneration
        guard let p: Page = try? await HarborEngine.shared.call("liveVod.page", [id, tab.rawValue, query, items.count, Self.pageSize]) else { return }
        guard mine == pageGeneration else { return }
        var seen = Set(items.map(\.id))
        items += p.items.filter { seen.insert($0.id).inserted }
        total = p.total
    }

    func chooseTab(_ t: Tab) async {
        tab = t
        selected = nil
        await reloadPage()
    }

    /// playlist-vod.tsx openSeries.
    func open(_ item: Item) async {
        guard let id = activeId else { return }
        seriesError = nil
        selected = Series(id: item.id, title: item.title, logo: item.logo, group: item.group, playlistName: item.playlistName, seasons: [], episodes: [])
        loadingSeries = true
        defer { loadingSeries = false }
        do {
            let s: Series = try await HarborEngine.shared.call("liveVod.series", [id, item.id])
            if selected?.id == item.id { selected = s }
        } catch {
            if selected?.id == item.id { seriesError = error.localizedDescription }
        }
    }

    /// Progress after the player closes (episode-row reads the resume store on every render).
    func refreshSelected() async {
        guard let id = activeId, let s = selected else { return }
        if let fresh: Series = try? await HarborEngine.shared.call("liveVod.series", [id, s.id]), selected?.id == s.id { selected = fresh }
    }

    func closeSeries() { selected = nil }

    func playback(movie: Item) async -> Playback? {
        guard let id = activeId else { return nil }
        return try? await HarborEngine.shared.call("liveVod.playMovie", [id, movie.id])
    }

    func playback(series: Series, episode: Episode) async -> Playback? {
        guard let id = activeId else { return nil }
        return try? await HarborEngine.shared.call("liveVod.playEpisode", [id, series.id, episode.season, episode.episode])
    }

    // MARK: copy (playlist-vod.tsx)

    var tabLoading: Bool {
        guard let s = status else { return loading }
        return tab == .movies ? s.moviesLoading : s.seriesLoading
    }

    var tabError: String? {
        if let error { return error }
        guard let s = status else { return nil }
        return tab == .movies ? s.movieError : s.seriesError
    }

    /// CatalogProgress: "Loading movies..." until the provider says how many, then "Loaded x of y movies...".
    var progressLine: String? {
        guard tabLoading else { return nil }
        let loaded = tab == .movies ? (status?.movies ?? 0) : (status?.series ?? 0)
        let providerTotal = tab == .movies ? status?.movieTotal : status?.seriesTotal
        guard let providerTotal else { return T(tab == .movies ? "Loading movies..." : "Loading shows...") }
        return T(tab == .movies ? "Loaded %@ of %@ movies..." : "Loaded %@ of %@ shows...", loaded.formatted(), max(providerTotal, loaded).formatted())
    }

    /// emptyMoviesText / emptyShowsText.
    var emptyText: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        if tab == .movies {
            if !q.isEmpty { return T("No movies match \"%@\".", q) }
            if libraryTotal == 0 { return "This playlist has no movies. It may be live channels only, or an Xtream login that exposes movies separately." }
            return "No movies here."
        }
        if !q.isEmpty { return T("No shows match \"%@\".", q) }
        if libraryTotal == 0 { return "This playlist has no shows. It may be live channels only, or an Xtream login that exposes shows separately." }
        return "No shows here."
    }

    /// CapNote.
    var capNote: String? {
        guard total > items.count else { return nil }
        return T(tab == .movies ? "Showing %@ of %@ movies. Scroll to load more." : "Showing %@ of %@ shows. Scroll to load more.",
                 items.count.formatted(), total.formatted())
    }
}
