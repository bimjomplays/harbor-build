import SwiftUI

/// Live TV (bp-live.tsx): source + category band, then the channel guide (guide-lite: one row
/// per channel with now/next from the XMLTV guide). Sources are M3U, middleware or Xtream.
@MainActor
final class LiveModel: ObservableObject {
    struct Playlist: Decodable, Identifiable { var id: String; var name: String; var url: String; var kind: String?; var epgUrl: String? }
    struct Channel: Codable, Identifiable, Equatable {
        var id: String; var name: String; var logo: String?; var url: String; var group: String?; var tvgId: String?
        var headers: [String: String]?; var favorite: Bool
        /// bp-guide-title: cleaned name, quality badge, and a group label that is not just the name again.
        var label: String?; var badge: String?; var groupLabel: String?
        var pinned: Bool?
        /// epg-map.ts: the guide channel the viewer matched by hand (nil = automatic).
        var epgMatch: String?
        var shownName: String { label ?? name }
    }
    struct Group: Decodable, Identifiable { var name: String; var count: Int; var hidden: Bool?; var id: String { name } }
    /// bp-live.tsx chip after Favorites and All: a group rail (filter by `group`) or a rail of `ids`.
    struct Category: Decodable { var key: String; var label: String; var count: Int; var group: String?; var flag: String?; var ids: [String]? }
    struct View_: Decodable { var id: String; var name: String; var kind: String; var channels: [Channel]; var groups: [Group]; var categories: [Category]?; var total: Int; var epgUrl: String? }
    /// epg-match-modal.tsx: guide channels a playlist channel can be matched to.
    struct EpgMatchEntry: Decodable, Identifiable { var id: String; var sample: String }
    struct EpgMatchList: Decodable { var channelId: String; var channelName: String; var query: String; var total: Int; var current: String?; var entries: [EpgMatchEntry] }
    struct Program: Decodable, Equatable { var title: String; var description: String?; var startMs: Double; var endMs: Double; var category: String?; var iconUrl: String? }
    struct NowNext: Decodable, Equatable { var id: String; var now: Program?; var next: Program?; var known: Bool }

    static let favKey = "fav", allKey = "all", maxCategories = 30

    /// use-bp-live.ts sources: the channel sources. A "Guide data only" entry is never the one Live
    /// TV shows; its address backs every source's guide (the engine's EPG fallback list).
    @Published private(set) var playlists: [Playlist] = []
    /// Every stored source, guide-only ones included (the Sources sheet lists and removes them).
    @Published private(set) var allSources: [Playlist] = []
    /// The sources have been read once. Before that `playlists` is
    /// empty for everyone, and Live TV drew the first-run setup form for a frame on every visit
    /// (the ring could land in it and fall to the top bar as it vanished). use-bp-live reads
    /// hasPlaylists synchronously from settings.
    @Published private(set) var sourcesRead = false
    @Published private(set) var channels: [Channel] = [] { didSet { visibleCache = nil; favoriteCountCache = nil } }
    @Published private(set) var groups: [Group] = []
    @Published private(set) var guide: [String: NowNext] = [:]
    @Published private(set) var guideNote: String?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var selectedPlaylist: String?
    @Published var category: String = LiveModel.allKey { didSet { if category != oldValue { visibleCache = nil } } }
    @Published private(set) var extraCategories: [Category] = [] { didSet { visibleCache = nil } }
    /// Settings' Live TV row opens the Sources sheet over its own model:
    /// it reads and edits the sources but never downloads a playlist nobody is looking at.
    let sourcesOnly: Bool
    /// The channel the player showed last (the player's TV Guide tunes through `played`), and a
    /// request for the guide or list to put the ring on a channel's row (returning from the player).
    private(set) var lastPlayedId: String?
    struct FocusRequest: Equatable { let channelId: String; let token = UUID() }
    @Published var focusRequest: FocusRequest?
    /// (open-items sweep) The channel whose guide cell holds the ring (nil when the ring is elsewhere):
    /// a guide note that lands late swaps the grid for the list under the ring, and the list rings it.
    var guideFocusChannel: String?
    /// (open-items sweep 3) bp-live.tsx `key` (useBpPersistedState "liveCategory"): the chip the
    /// viewer picked last, kept while a source without it shows All. `category` is the chip drawn
    /// (categories.find(key) ?? All), so A → B → A shows A's chip again; it came back on All.
    var keptCategory: String = LiveModel.allKey

    /// `category`: the chip to open on (ShellViewState.liveCategory, bp-view-state); a key the
    /// source's channels do not carry falls back to All when they load.
    init(sourcesOnly: Bool = false, category: String = LiveModel.allKey) {
        self.sourcesOnly = sourcesOnly
        self.keptCategory = category
        self.category = category
    }

    /// The chosen category's channels and ids, built once per change of
    /// channels / chip / rails instead of on every render: a group chip re-filtered the whole
    /// source (6,000 channels) for each body pass, and the guide's `.task(id:)` mapped every id
    /// on each now/next merge. The ids array is kept so that id compares by storage, not by value.
    private var visibleCache: (list: [Channel], ids: [String])?
    private var favoriteCountCache: Int?
    /// The source whose channels are on screen (a pick of another one clears them first).
    private var shownPlaylist: String?
    /// How many channels the loaded guide covers (0 = nothing to match against).
    @Published private(set) var guideChannelCount = 0
    /// Bumped after a manual EPG match changes; `lastRemapped` names the channel.
    @Published private(set) var epgMapRevision = 0
    private(set) var lastRemapped: String?
    /// Bumped whenever the guide data behind the lanes changed (the XMLTV or the Xtream short EPG
    /// landed), so the grid rebuilds the lanes it drew before the guide had loaded.
    @Published private(set) var guideRevision = 0

    private var tick: Task<Void, Never>?
    private var indexById: [String: Int] = [:]
    /// Only the newest channel load applies: a slow playlist must not land over the one picked after it.
    private var loadGeneration = 0

    deinit { tick?.cancel() }

    /// `.task` runs again whenever a cover over Live TV closes (every channel the viewer backs out
    /// of): the sources are re-read, but channels and guide reload only when they changed.
    func appear() async {
        let all: [Playlist] = (try? await HarborEngine.shared.call("live.playlists", [])) ?? []
        let key = { (list: [Playlist]) in list.map { "\($0.id)|\($0.url)|\($0.epgUrl ?? "")|\($0.kind ?? "")" } }
        if !channels.isEmpty, error == nil, key(all) == key(allSources) { return }
        await load()
    }

    func load() async {
        await loadSources()
        if sourcesOnly { return }
        await loadChannels()
    }

    /// The stored sources and the one to show; no channels.
    func loadSources() async {
        let all: [Playlist] = (try? await HarborEngine.shared.call("live.playlists", [])) ?? []
        allSources = all
        playlists = all.filter { ($0.kind ?? "m3u") != "epg" }
        if selectedPlaylist == nil || !playlists.contains(where: { $0.id == selectedPlaylist }) {
            // use-bp-live readActiveId: the source picked last time, else the first.
            let remembered: String? = try? await HarborEngine.shared.call("live.activeSource", [])
            selectedPlaylist = playlists.first(where: { $0.id == remembered })?.id ?? playlists.first?.id
        }
        sourcesRead = true
    }

    /// use-bp-live setActiveId: the picked source is remembered (next launch, the Home live row).
    func select(_ id: String) async {
        selectedPlaylist = id
        _ = try? await HarborEngine.shared.callJSON("live.setActiveSource", [.string(id)])
        if sourcesOnly { return }
        await loadChannels()
    }

    func loadChannels(force: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration
        guard let id = selectedPlaylist else {
            setChannels([]); groups = []; extraCategories = []; guide = [:]; guideNote = nil; guideChannelCount = 0; loading = false
            shownPlaylist = nil
            return
        }
        if shownPlaylist != id {
            // use-bp-live: another source starts from the loading state.
            // The old source's channels, guide note and now/next stayed up under the new source's
            // name until its playlist arrived, and could be tuned and starred meanwhile.
            setChannels([]); groups = []; extraCategories = []; guide = [:]; guideNote = nil; guideChannelCount = 0
            shownPlaylist = id
        }
        loading = true
        error = nil
        do {
            let v: View_ = try await HarborEngine.shared.call("live.channels", [id, force])
            // A slower load for a source picked earlier used to land over this one.
            guard generation == loadGeneration else { return }
            guard selectedPlaylist == id else { loading = false; return }
            setChannels(v.channels)
            groups = v.groups
            extraCategories = v.categories ?? []
            // (open-items sweep 3) bp-live `categories.find((c) => c.key === key) ?? All`: the kept
            // key when this source has it, else All (the key itself stays kept).
            let kept: String = keptCategory
            let keptShown: Bool = kept == Self.favKey || kept == Self.allKey || extraCategories.contains(where: { $0.key == kept })
            category = keptShown ? kept : Self.allKey
            loading = false
            // The guide follows on its own: a big XMLTV can take a while, and "Add source", a
            // source pick and Refresh (which wait for this) must not sit on it.
            Task { [weak self] in
                await self?.loadGuide(force: force)
                guard let self, generation == self.loadGeneration else { return }
                self.startTick()
            }
        } catch {
            guard generation == loadGeneration else { return }
            self.error = error.localizedDescription; setChannels([]); groups = []; extraCategories = []
            loading = false
        }
    }

    private func setChannels(_ list: [Channel]) {
        channels = list
        var index: [String: Int] = [:]
        for (i, ch) in list.enumerated() where index[ch.id] == nil { index[ch.id] = i }
        indexById = index
    }

    /// The guide is optional: no EPG URL means rows just say "Live".
    func loadGuide(force: Bool = false) async {
        guard let id = selectedPlaylist else { return }
        struct Out: Decodable { var channels: Int; var programs: Int; var url: String? }
        var covered = 0
        var note: String?
        do {
            let o: Out = try await HarborEngine.shared.call("live.loadEpg", [id, force])
            covered = o.channels
            note = o.url == nil ? "No guide for this source. Add an EPG URL under Sources." : (o.channels == 0 ? "The guide loaded but lists no channels." : nil)
        } catch { note = T("Guide failed: %@", error.localizedDescription) }
        // A guide that lands after another source was picked belongs to that other source.
        guard selectedPlaylist == id else { return }
        guideNote = note
        guideChannelCount = covered
        guideRevision += 1
        await refreshNowNext()
        // use-xtream-epg-fallback: an Xtream source with no usable XMLTV asks get_short_epg per channel.
        let xtream = playlists.first { $0.id == id }?.kind == "xtream"
        // Judged on the rows asked so far (the first screenfuls), not the whole category.
        let asked = visible.compactMap { guide[$0.id] }
        if xtream, covered == 0 || !asked.isEmpty && asked.allSatisfy({ $0.known != true }) {
            struct Hydrated: Decodable { var hydrated: Int }
            let ids = visible.map(\.id)
            if let h: Hydrated = try? await HarborEngine.shared.call("live.loadShortEpg", [id, ids]), h.hydrated > 0, selectedPlaylist == id {
                guideNote = nil
                guideChannelCount = covered + h.hydrated
                guideRevision += 1
                await refreshNowNext()
            }
        }
    }

    /// Now/next for the rows someone can see, not the whole category: "All" on a
    /// 6,000-channel source sent every id on each 30 s tick and got ~2.7 MB of JSON back (≈50 ms of
    /// engine time in node, far more in JavaScriptCore on an Apple TV HD, then the decode and a
    /// republish of the whole map), also under the grid, which draws its own lanes. The first
    /// `nowNextLead` rows are asked up front, rows ask for themselves as they appear (`askNowNext`),
    /// and a refresh re-asks only the rows already in `guide`.
    private static let nowNextLead = 60
    private var nowNextPending: [String] = []
    private var nowNextPendingSet: Set<String> = []
    private var nowNextFlush: Task<Void, Never>?

    func refreshNowNext() async {
        guard let id = selectedPlaylist, !visible.isEmpty else { guide = [:]; return }
        var ids: [String] = []
        for (i, ch) in visible.enumerated() where i < Self.nowNextLead || guide[ch.id] != nil { ids.append(ch.id) }
        if let list: [NowNext] = try? await HarborEngine.shared.call("live.nowNext", [id, ids]) {
            // A reply for a source switched away from would merge into the new source's map.
            guard selectedPlaylist == id else { return }
            merge(list)
        }
    }

    /// Now/next for channels outside the chosen category (the player's TV Guide, the Multiview
    /// picker), merged into `guide`; 400 ids at most per ask.
    func refreshNowNext(ids: [String]) async {
        guard let id = selectedPlaylist, !ids.isEmpty else { return }
        let ask = Array(ids.prefix(400))
        if let list: [NowNext] = try? await HarborEngine.shared.call("live.nowNext", [id, ask]) {
            guard selectedPlaylist == id else { return }
            merge(list)
        }
    }

    /// A row came on screen: its now/next is asked with the others that appear in the same moment.
    func askNowNext(_ channelId: String) {
        guard guide[channelId] == nil, nowNextPendingSet.insert(channelId).inserted else { return }
        nowNextPending.append(channelId)
        guard nowNextFlush == nil else { return }
        nowNextFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self else { return }
            let ids = self.nowNextPending
            self.nowNextPending = []
            self.nowNextPendingSet = []
            self.nowNextFlush = nil
            var start = 0
            while start < ids.count {
                await self.refreshNowNext(ids: Array(ids[start..<min(ids.count, start + 400)]))
                start += 400
            }
        }
    }

    /// Only entries that changed are written, and the map is republished only when one did (a 30 s
    /// tick where nothing rolled over redraws nothing).
    private func merge(_ list: [NowNext]) {
        var next = guide
        var changed = false
        for n in list where next[n.id] != n { next[n.id] = n; changed = true }
        if changed { guide = next }
    }

    /// bp-live-tick: recompute "now" every 30 s so progress bars and now/next roll over.
    private func startTick() {
        tick?.cancel()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.refreshNowNext()
            }
        }
    }

    /// bp-live.tsx: Favorites and All, then the engine's rails (recent, pinned groups, themes or
    /// countries, top groups); 30 chips at most.
    var categories: [(key: String, label: String, count: Int, flag: String?)] {
        var out: [(key: String, label: String, count: Int, flag: String?)] = [
            (key: Self.favKey, label: T("Favorites"), count: favoriteCount, flag: nil),
            (key: Self.allKey, label: T("All"), count: channels.count, flag: nil),
        ]
        for c in extraCategories.prefix(Self.maxCategories - 2) { out.append((key: c.key, label: c.label, count: c.count, flag: c.flag)) }
        return out
    }

    var favoriteCount: Int {
        if let n = favoriteCountCache { return n }
        var n = 0
        for ch in channels where ch.favorite { n += 1 }
        favoriteCountCache = n
        return n
    }

    /// The group behind the chosen chip, when it is a group rail.
    var currentGroup: String? { extraCategories.first(where: { $0.key == category })?.group }

    /// Channels of the chosen category, in guide order (favorites, pins, most watched, networks, rest).
    var visible: [Channel] {
        if let held = visibleCache { return held.list }
        let list = buildVisible()
        let ids: [String] = list.map(\.id)
        visibleCache = (list: list, ids: ids)
        return list
    }

    /// The ids of `visible`, in order (the guide keys its lane seeding on them).
    var visibleIds: [String] {
        if visibleCache == nil { _ = visible }
        return visibleCache?.ids ?? []
    }

    /// A loaded channel by id.
    func channel(_ id: String) -> Channel? {
        guard let i = indexById[id], i < channels.count else { return nil }
        return channels[i]
    }

    private func buildVisible() -> [Channel] {
        switch category {
        case Self.favKey: return channels.filter(\.favorite)
        case Self.allKey: return channels
        default:
            guard let c = extraCategories.first(where: { $0.key == category }) else { return [] }
            if let ids = c.ids {
                var out: [Channel] = []
                for id in ids { if let i = indexById[id], i < channels.count { out.append(channels[i]) } }
                return out
            }
            let group = c.group ?? ""
            return channels.filter { ($0.group ?? "Uncategorized") == group }
        }
    }

    /// usePinnedOrder: pinned channels sit in guide-order tier 2 (after favourites).
    func togglePin(_ ch: Channel) async {
        _ = try? await HarborEngine.shared.callJSON("live.toggleChannelPin", [.string(ch.id)])
        await load()
    }

    /// useGroupPrefs: hide (or show again) a whole channel group of this source.
    func toggleGroupHidden(_ group: String) async {
        guard let id = selectedPlaylist else { return }
        _ = try? await HarborEngine.shared.callJSON("live.toggleGroupHidden", [.string(id), .string(group)])
        if currentGroup == group { category = Self.allKey }
        await load()
    }

    /// epg-match-modal Match EPG: offered when the guide has channels and this one has no
    /// programmes, or already carries a manual match (so it can be changed or cleared).
    func canMatchEpg(_ ch: Channel) -> Bool {
        guideChannelCount > 0 && (ch.epgMatch != nil || guide[ch.id]?.known != true)
    }

    /// The modal's list: nil `query` starts from the channel's own name.
    func epgCandidates(for ch: Channel, query: String?) async -> EpgMatchList? {
        guard let id = selectedPlaylist else { return nil }
        let q: AnyJSON = query.map { AnyJSON.string($0) } ?? AnyJSON.null
        let args: [any Encodable] = [id, ch.id, q]
        do {
            let out: EpgMatchList = try await HarborEngine.shared.call("live.epgCandidates", args)
            return out
        } catch { return nil }
    }

    /// epg-map setEpgOverride: a guide channel id, or nil to clear; now/next and the guide lane follow.
    func setEpgMatch(_ ch: Channel, tvgId: String?) async {
        let args: [AnyJSON] = [.string(ch.id), tvgId.map { AnyJSON.string($0) } ?? AnyJSON.null]
        guard let result = try? await HarborEngine.shared.callJSON("live.setEpgMatch", args) else { return }
        var match: String? = nil
        if case .string(let s) = result { match = s }
        if let i = indexById[ch.id], i < channels.count { channels[i].epgMatch = match }
        lastRemapped = ch.id
        epgMapRevision += 1
        await refreshNowNext()
    }

    var hiddenGroupCount: Int { groups.filter { $0.hidden == true }.count }

    func toggleFavorite(_ ch: Channel) async {
        let on: Bool = (try? await HarborEngine.shared.call("live.toggleFavorite", [ch])) ?? !ch.favorite
        if let i = indexById[ch.id], i < channels.count, channels[i].id == ch.id { channels[i].favorite = on }
    }

    func played(_ ch: Channel) {
        lastPlayedId = ch.id
        guard let id = selectedPlaylist else { return }
        // The player's subtitle and channel card read `guide`; a grid row past the first ones may not be in it yet.
        askNowNext(ch.id)
        Task { _ = try? await HarborEngine.shared.callJSON("live.recordPlay", [.string(id), .string(ch.id)]) }
    }

    /// bp-live-setup: the structured form; kind is "m3u", "xtream" or "epg".
    func add(kind: String, name: String, url: String, epgUrl: String, server: String, username: String, password: String) async -> String? {
        struct Added: Decodable { var id: String }
        do {
            let a: Added = try await HarborEngine.shared.call("live.addStructured", [kind, name, url, epgUrl, server, username, password])
            await added(a.id)
            return nil
        } catch { return error.localizedDescription }
    }

    func add(name: String, url: String, epgUrl: String) async -> String? {
        struct Added: Decodable { var id: String }
        do {
            let a: Added = try await HarborEngine.shared.call("live.addPlaylist", [name, url, epgUrl])
            await added(a.id)
            return nil
        } catch { return error.localizedDescription }
    }

    /// bp-live onAdded setActiveId (the engine ignores a guide-only source), then bp-live-setup
    /// onDone: the sheet closes at once and the playlist loads behind it.
    /// "Adding…" used to wait for the whole playlist download (a big
    /// list or a dead server held the sheet for the length of a network timeout).
    private func added(_ id: String) async {
        _ = try? await HarborEngine.shared.callJSON("live.setActiveSource", [.string(id)])
        selectedPlaylist = id
        // The spinner from the start: between the sources arriving and loadChannels running, a
        // frame drew the empty state ("Add a playlist") and the ring could land on it.
        if !sourcesOnly { loading = true }
        await loadSources()
        if sourcesOnly { return }
        Task { [weak self] in await self?.loadChannels() }
    }

    func setEpgUrl(_ url: String) async {
        guard let id = selectedPlaylist else { return }
        _ = try? await HarborEngine.shared.callJSON("live.setEpgUrl", [.string(id), .string(url)])
        await load()
    }

    func remove(_ id: String) async {
        _ = try? await HarborEngine.shared.callJSON("live.removePlaylist", [.string(id)])
        if selectedPlaylist == id { selectedPlaylist = nil }
        await load()
    }
}
