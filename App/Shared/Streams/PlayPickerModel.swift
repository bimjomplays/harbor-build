import Foundation
import Combine

/// What plays now, for switcher-row.tsx isCurrentStream: the URL the player opened, and the
/// picked stream's own URL, info hash and file (PlayerSrc.streamRef). (Was
/// PlayerSourcesPanel.Current; moved here so the shared picker model can hold it.)
struct PlayingSource: Equatable {
    var url: String
    var streamURL: String?
    var infoHash: String?
    var fileIdx: Int?

    /// switcher-row.tsx isCurrentStream: the same torrent (and file, when both know it), else
    /// the same URL.
    func matches(_ s: ScoredStream) -> Bool {
        if let mine = infoHash?.lowercased(), !mine.isEmpty, let theirs = s.infoHash?.lowercased(), theirs == mine {
            if let a = s.fileIndex, let b = fileIdx { return a == b }
            return true
        }
        guard let u = s.url, !u.isEmpty else { return false }
        return u == url || u == streamURL
    }
}

/// The stream picker's state and logic (bp-streams / use-bp-stream-play / use-pick-handler), lifted
/// out of the TV's PlayPickerView: the chips' state, the filter pool and visible list, the auto-fire
/// machine, the pick / resolve / retry path, the dialogs and the subtitle step. The search itself
/// stays in StreamsModel (`model` here). The view draws and owns the two focus rings; this model
/// reaches them through `bindFocus`, and the view hands it the latest inputs through `update`.
@MainActor
final class PlayPickerModel: ObservableObject {
    // MARK: inputs

    let meta: Meta
    let episode: AnyJSON?
    /// use-bp-stream-play autoPlay: fire the best candidate once the pipeline settles (instantPlay).
    let autoPlay: Bool
    /// bp-streams.tsx applyPreference: this list opened from Play (not Sources or Switch source).
    let applyPreference: Bool
    /// (S4) use-bp-stream-play openPlayerGated: the subtitle step may stand between a pick and the player.
    let subtitleStep: Bool
    /// The search engine model (the view observes it too).
    let model: StreamsModel
    /// Refreshed by `update` on every body pass: they can change while the picker is up.
    private(set) var switching: PlayingSource?
    private var onPlay: (ScoredStream?, StreamsModel.Resolved) -> Void
    private var onClose: (() -> Void)?
    private var dismiss: () -> Void = {}

    /// Forwards the search model's changes: the view observes only this model and reads `model` through it.
    private var streamsChange: AnyCancellable?

    init(meta: Meta, episode: AnyJSON?, autoPlay: Bool, applyPreference: Bool,
         subtitleStep: Bool, switching: PlayingSource?,
         onPlay: @escaping (ScoredStream?, StreamsModel.Resolved) -> Void, onClose: (() -> Void)?) {
        let streams = StreamsModel()
        self.model = streams
        self.meta = meta
        self.episode = episode
        self.autoPlay = autoPlay
        self.applyPreference = applyPreference
        self.subtitleStep = subtitleStep
        self.switching = switching
        self.onPlay = onPlay
        self.onClose = onClose
        // After every stored property is set: the closure captures self.
        streamsChange = streams.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// The view's current inputs (the closures it was last built with, the switcher's playing stream).
    func update(switching: PlayingSource?, onPlay: @escaping (ScoredStream?, StreamsModel.Resolved) -> Void,
                onClose: (() -> Void)?, dismiss: @escaping () -> Void) {
        self.switching = switching
        self.onPlay = onPlay
        self.onClose = onClose
        self.dismiss = dismiss
    }

    // MARK: focus rings (the view's @FocusState, reached through closures)

    private var readRow: () -> String? = { nil }
    private var writeRow: (String?) -> Void = { _ in }
    private var readChip: () -> String? = { nil }
    private var writeChip: (String?) -> Void = { _ in }

    func bindFocus(row: (read: () -> String?, write: (String?) -> Void), chip: (read: () -> String?, write: (String?) -> Void)) {
        readRow = row.read
        writeRow = row.write
        readChip = chip.read
        writeChip = chip.write
    }

    /// bp-streams autofocus on the first row: "stream:<id>" / "copy:<key>".
    private var rowFocus: String? {
        get { readRow() }
        set { writeRow(newValue) }
    }
    /// The quality chips ("q:<name>"); the cover's first ring lands on "q:All".
    private var chipFocus: String? {
        get { readChip() }
        set { writeChip(newValue) }
    }

    // MARK: state

    /// bp-stream-chips BpSourceKind, the kinds the TV has: "all", "media-server" or "online" (the
    /// source chip's Direct/debrid only and P2P only; no Local Library on a TV).
    @Published var sourceKind = "all"
    /// bp-stream-filters langFilter: the preferred-language chip, first set from
    /// requirePreferredLanguage once the engine has said which languages those are (model.setup).
    @Published var langFilter = false
    private var langSeeded = false
    /// bp-streams preferredSourceFired: the preference acts once per opening.
    private var preferenceFired = false
    /// The viewer picked a row by hand (the preference no longer auto-plays over it).
    private var handPicked = false
    @Published var autoState: AutoState = .off
    @Published var autoTried = 0
    private var startedAt = Date()
    private var firstResultAt: Date?
    enum AutoState: Equatable { case off, waiting, firing(String), cancelled, exhausted }
    @Published var resolving: String?
    @Published var resolveError: String?
    @Published var quality: String = "All"
    @Published var cachedOnly = false
    @Published var addonFilter: String?
    /// bp-stream-dialogs: the one dialog over the picker (P2P consent, debrid down, no sources, auto exhausted).
    @Published var dialog: PickerDialog?
    /// use-pick-handler debridFailStreak: two debrid-side failures in a row → "Debrid is down".
    private var debridFailStreak = 0
    /// use-bp-stream-play failedStreams: rows that already failed read "Unavailable, try another."
    @Published var failedIds: Set<String> = []
    private var alive = true
    /// play-picker.tsx stubBanner / auto-play-transition.tsx stubNotice: the player just sent a stub
    /// back (use-stub-detection.ts recordStubEvent), shown for 6 s.
    @Published var stubNotice = false
    /// A dialog's fullScreenCover makes the view disappear and re-appear: the search task
    /// runs again (a second search cleared the list under the dialog) and onDisappear cancelled the
    /// search and set `alive = false`, so the P2P dialog's "Stream" resolved and then dropped the pick.
    private var searched = false
    /// `seededKey` is where the last seed put the ring; the seed follows a new first row
    /// only while the ring is still there.
    private var seededKey: String?
    private var seedFrom = Date()
    /// The auto step just handed over to the list (bp-streams recoverBpFocus on a surface swap):
    /// the next seed may take the ring from wherever it fell.
    private var seedAfterSwap = false
    /// (S4) use-bp-stream-play `preselect`: the resolved pick waiting on the subtitle step.
    @Published var preselect: PendingPreselect?
    @Published var facet: [String: String] = [:]
    private let memo = PoolMemo()

    struct PendingPreselect {
        var stream: ScoredStream?
        var resolved: StreamsModel.Resolved
        /// The row that was picked: Back puts the ring on it again (the step's focus restore).
        var focusKey: String
    }

    enum PickerDialog: Identifiable {
        case p2p(ScoredStream), debridDown, noSources, exhausted(Int)
        var id: String {
            switch self {
            case .p2p(let s): return "p2p-\(s.id)"
            case .debridDown: return "debrid-down"
            case .noSources: return "no-sources"
            case .exhausted: return "exhausted"
            }
        }
    }

    /// bp-stream-chips.tsx quality chips, mapped onto the parser's resolution values.
    static let qualities: [(String, [String])] = [("All", []), ("4K UHD", ["2160p", "4K"]), ("1080p", ["1080p"]), ("720p", ["720p"]), ("480p", ["480p"]), ("SD", ["SD", "360p", "240p"])]

    // MARK: lifecycle hooks (the view's .task / .onChange / .onAppear blocks call these)

    /// The search task: bp-streams sourceKind starts on the preferred kind when the preference applies.
    func runSearch() async {
        guard !searched else { return }
        searched = true
        if applyPreference, SettingsBridge.shared.slice.playbackSourcePreference == "home-server" { sourceKind = "media-server" }
        if autoEnabled { autoState = .waiting; startedAt = Date() }
        await model.search(meta: meta, episode: episode)
        await autoTick(done: true)
    }

    /// use-auto-fire: settle windows (1.5 s after the first result, 4 s when no cached exact episode,
    /// 10 s cap) so a fast addon does not beat a better one by a few hundred milliseconds.
    func runAutoLoop() async {
        guard autoEnabled else { return }
        // Ticks until auto is over, not only while it waits: when the
        // search-done tick fired a candidate this loop saw `.firing` and ended, so a failed first
        // candidate set `.waiting` with nothing left to tick, and the auto step sat on screen for
        // good. It also runs from before the first task sets `.waiting` (`.off`).
        while !Task.isCancelled {
            if autoState == .cancelled || autoState == .exhausted { return }
            try? await Task.sleep(for: .milliseconds(400))
            // A cancelled sleep returns at once: no last tick (and resolve) once the view has gone.
            if Task.isCancelled { return }
            await autoTick(done: false)
        }
    }

    /// play-picker.tsx / auto-play-transition.tsx: consumeRecentStubEvent(8000) as the picker
    /// opens; the notice clears itself after 6 s. Not the in-player switcher: it has no
    /// stub banner, and reading the event here would take it from the picker it was meant for.
    func consumeStubEvent() async {
        guard switching == nil else { return }
        let ev: String? = try? await HarborEngine.shared.call("deadStreams.consumeStubEvent", [8000])
        guard ev != nil, !Task.isCancelled else { return }
        stubNotice = true
        try? await Task.sleep(for: .seconds(6))
        stubNotice = false
    }

    /// The switcher opens inside the player with no ring of its own: it starts on the
    /// "All" chip, where the picker's cover lands, so the first row's seed takes it from there.
    func appeared() {
        guard switching != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
            if rowFocus == nil, chipFocus == nil { chipFocus = "q:All" }
        }
    }

    func streamCountChanged(_ n: Int) {
        if n > 0, firstResultAt == nil { firstResultAt = Date() }
    }

    /// bp-stream-filters useState(requirePreferredLanguage && preferredLanguages.length > 0): once per opening.
    func setupChanged(_ setup: StreamsModel.Setup?) {
        guard !langSeeded, let setup else { return }
        langSeeded = true
        langFilter = setup.langFilterDefault
    }

    func autoStepChanged(busy: Bool) {
        guard !busy else { return }
        seededKey = nil
        seedFrom = Date()
        seedAfterSwap = true
        seedRing()
    }

    /// bp-streams: BpNoSourcesDialog when there is no addon, no debrid and no home-server copy
    /// (the switcher lists no copies: `homeServerCopies.length === 0` holds there).
    func phaseChanged(_ phase: StreamsModel.Phase) {
        let noCopies: Bool = switching != nil || model.copies.isEmpty
        // It outranks "tried N sources" (bp-streams shows that one only when !noSources).
        if phase == .done, model.addonCount == 0, model.debridCount == 0, noCopies, dialog == nil || dialog?.id == "exhausted" { dialog = .noSources }
    }

    /// BpAutoExhaustedDialog: shown unless no sources or debrid down already explains it.
    func autoStateChanged(_ state: AutoState) {
        if state == .exhausted, dialog == nil { dialog = .exhausted(autoTried) }
    }

    /// Covered by one of its own dialogs, not closed. The switcher draws its dialogs
    /// inline, so it only disappears when it closes.
    func disappeared() {
        guard dialog == nil || switching != nil else { return }
        alive = false; if autoState == .waiting { autoState = .cancelled }; model.cancel()
    }

    // MARK: focus seed

    /// bp-streams: the row that carries data-bp-autofocus (a home-server copy first, else the first stream).
    var firstRowKey: String? {
        if showHomeServers, let c = model.copies.first { return "copy:" + c.key }
        guard showOnline, let s = visible.first else { return nil }
        return "stream:" + s.id
    }

    /// use-bp-focus seed pass: the first row takes the ring while the viewer has not moved it.
    func seedRing() {
        guard preselect == nil, !showAutoStep, dialog == nil, resolving == nil, let key = firstRowKey, key != rowFocus,
              Date().timeIntervalSince(seedFrom) < 6 else { return }
        let from = seededKey
        // Untouched: the first seed while the ring is on the "All" chip (where the cover lands) or
        // just after the auto step went; a later seed only while the ring is on the row seeded last.
        // The in-player switcher also takes its first seed while nothing in it has the ring yet.
        let fresh: Bool = chipFocus == "q:All" || seedAfterSwap || (switching != nil && rowFocus == nil && chipFocus == nil)
        let untouched = from == nil ? fresh : rowFocus == from
        guard untouched else { return }
        seededKey = key
        seedAfterSwap = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
            guard from == nil || rowFocus == from else { return }
            rowFocus = key
        }
    }

    // MARK: auto-fire

    /// use-bp-stream-play autoBusy: auto is still finding or starting a source. Before the first
    /// task sets `.waiting`, an auto picker already shows the step (no flash of the list).
    var showAutoStep: Bool {
        switch autoState {
        case .waiting, .firing: return true
        case .off: return autoEnabled
        case .cancelled, .exhausted: return false
        }
    }

    var autoFiring: Bool { if case .firing = autoState { return true }; return false }

    /// bp-detail.tsx play(): `auto = playbackSourcePreference === "online" && instantPlay`. The caller
    /// passes instantPlay as `autoPlay`; a Play press under another preference never fires online.
    var autoEnabled: Bool {
        autoPlay && (!applyPreference || (SettingsBridge.shared.slice.playbackSourcePreference ?? "online") == "online")
    }

    /// bp-streams.tsx's applyPreference effect, once the home-server copies are in (the engine
    /// ports decidePlaybackSource: engine/homeServers.ts preferredSource).
    func applySourcePreference() async {
        guard applyPreference, !preferenceFired else { return }
        preferenceFired = true
        struct Decision: Decodable { var action: String; var copyKey: String? }
        let p = ProfilesStore.shared.active
        let copies: [[String: String]] = model.copies.map { ["key": $0.key, "connectionId": $0.connectionId] }
        guard let d: Decision = try? await HarborEngine.shared.call("homeServers.preferredSource", [p?.id ?? "default", p?.linked ?? true, copies]) else { return }
        switch d.action {
        case "show-all": sourceKind = "all"
        case "show-media-server": sourceKind = "media-server"
        case "play":
            // The engine can wait up to 5 s on the server health probe: a pick by hand in the meantime wins.
            guard let copy = model.copies.first(where: { $0.key == d.copyKey }), resolving == nil, alive, !handPicked else { return }
            await pick(copy: copy)
        default: break
        }
    }

    /// use-bp-stream-play cancelAuto: the resolve in flight stops counting (its result is dropped by
    /// autoTick) and auto is off for good; the list is the picker again.
    func cancelAuto() {
        if case .firing(let id) = autoState, resolving == id { resolving = nil }
        autoState = .cancelled
    }

    /// use-bp-stream-play browseManually: auto stops for good and the list is the picker again.
    func browseManually() { dialog = nil; autoState = .cancelled }

    func closePicker() {
        dialog = nil
        // The in-player switcher closes its panel (bp-stream-dialogs onBack={onClose}); a
        // dismiss here would take the player's own cover down.
        if switching != nil { onClose?(); return }
        // Leave once the dialog's cover is gone; a dismiss while it is still dismissing is dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in dismiss() }
    }

    /// BpAutoExhaustedDialog label: "{title} S{s}E{ee}" with the IMDb numbering when the episode has one.
    var exhaustedLabel: String {
        let s = episode?["imdbSeason"]?.number ?? episode?["season"]?.number
        let e = episode?["imdbEpisode"]?.number ?? episode?["episode"]?.number
        guard let s, let e else { return meta.name }
        return "\(meta.name) S\(clampedInt(s))E" + String(format: "%02d", clampedInt(e))
    }

    var episodeLabel: String? {
        guard let s = episode?["season"]?.number, let e = episode?["episode"]?.number else { return nil }
        let name = episode?["name"]?.string
        return "S\(clampedInt(s)) E\(clampedInt(e))" + (name.map { " · \($0)" } ?? "")
    }

    /// bp-streams heading: "{name} · S{imdbSeason ?? season}E{imdbEpisode ?? episode}", else the name.
    var switchHeading: String {
        let s: Double? = episode?["imdbSeason"]?.number ?? episode?["season"]?.number
        let e: Double? = episode?["imdbEpisode"]?.number ?? episode?["episode"]?.number
        guard let s, let e else { return meta.name }
        return "\(meta.name) · S\(clampedInt(s))E\(clampedInt(e))"
    }

    private func autoTick(done: Bool) async {
        guard autoState == .waiting else { return }
        let now = Date()
        let sinceStart = now.timeIntervalSince(startedAt)
        let sinceFirst = firstResultAt.map { now.timeIntervalSince($0) } ?? -1
        let hasEpisode = episode?["episode"]?.number != nil
        let hasCachedExact = model.streams.contains { $0.isCached }
        let settle: Double = hasEpisode && !hasCachedExact ? 4.0 : 1.5
        let ready = done || model.phase == .done || (sinceFirst >= settle) || sinceStart >= 10
        guard ready else { return }
        if model.streams.isEmpty {
            if done || model.phase == .done || sinceStart >= 10 { autoState = .exhausted }
            return
        }
        // use-bp-stream-play: auto picks from the filtered list (the saved filter's pool).
        let allowed = Set(pool.map(\.id))
        let candidates = await model.autoCandidates(meta: meta, episode: episode).filter { model.streams.indices.contains($0) && allowed.contains(model.streams[$0].id) }
        guard autoState == .waiting else { return }
        // The next candidate that has not failed yet: rows keep their ids now,
        // while a candidate list that grew between ticks shifted what dropFirst(autoTried) skipped.
        guard let first = candidates.first(where: { !failedIds.contains(model.streams[$0].id) }), model.streams.indices.contains(first) else {
            if done || model.phase == .done || sinceStart >= 10 { autoState = .exhausted }
            return
        }
        let s = model.streams[first]
        autoState = .firing(s.id)
        resolving = s.id
        // use-pick-handler: during auto-fire a debrid-side failure retries the same source only under the season lock.
        let r = await resolveRetrying(s, forceP2p: false, sameSource: model.seasonLock) { [self] in if case .firing = autoState { return true }; return false }
        guard case .firing = autoState, !Task.isCancelled else {
            // The viewer picked by hand, or left: free the rows unless a manual pick owns the spinner now.
            if resolving == s.id { resolving = nil }
            return
        }
        resolving = nil
        // A link no URL can be made of counts as a failed candidate, not a silent no-op.
        if r.ok, let ready = Self.playable(r) {
            debridFailStreak = 0
            await model.remember(s, meta: meta, episode: episode, url: r.data?.url)
            // use-pick-handler: PlayerSrc.autoFired + streamRef, so a stall or a failed open can
            // mark this stream dead and bring the picker back on the next candidate (views/player.tsx).
            var handed = ready
            handed.autoPicked = true
            handed.streamRef = await model.deadRef(s)
            onPlay(s, handed)
        } else {
            failedIds.insert(s.id)
            autoTried += 1
            if countDebridFailure(r) {
                // Debrid down ends auto-fire; its dialog explains it instead of "tried N sources".
                dialog = .debridDown
                autoState = .exhausted
                return
            }
            autoState = autoTried >= 3 ? .exhausted : .waiting
        }
    }

    /// use-pick-handler: the debrid-side streak. True when this failure makes two in a row.
    private func countDebridFailure(_ r: StreamsModel.Resolved) -> Bool {
        if r.debridFailure == true, model.debridCount > 0 {
            debridFailStreak += 1
            return debridFailStreak >= 2
        }
        debridFailStreak = 0
        return false
    }

    /// use-pick-handler resetDebridDown: the streak clears and the list stays up.
    func resetDebridDown() {
        debridFailStreak = 0
        dialog = nil
    }

    /// use-pick-handler scheduleSameSourceRetry: a debrid-side failure retries the same source up to
    /// four times, 1.5 s × n apart, before it counts as a failure.
    private func resolveRetrying(_ s: ScoredStream, forceP2p: Bool, sameSource: Bool, stillWanted: () -> Bool) async -> StreamsModel.Resolved {
        var r = await model.resolve(s, forceP2p: forceP2p)
        var n = 0
        while sameSource, !r.ok, r.debridFailure == true, n < 4, alive, stillWanted() {
            n += 1
            try? await Task.sleep(for: .milliseconds(1500 * n))
            guard alive, stillWanted() else { break }
            r = await model.resolve(s, forceP2p: forceP2p)
        }
        return r
    }

    // MARK: the list, its chips and filters

    /// bp-streams s.loading: the pipeline is still running and nothing has passed the filters yet.
    var listLoading: Bool {
        // On the Media servers list only the home-server copies are drawn: until they
        // are in it is still looking. A finished stream search there read "No sources match these
        // filters" (with the loosen ladder when no addon answered) over a copy about to arrive.
        if sourceKind == "media-server", !model.copiesLoaded { return true }
        let running: Bool = model.phase == .searching || model.phase == .idle
        return running && pool.isEmpty
    }

    /// bp-streams header counts: every kind the source chip shows (online streams after every
    /// filter over the ones after the mode / language / cached / saved-filter pass, plus the
    /// home-server copies).
    var sourcesLine: String {
        let copies: Int = showHomeServers ? model.copies.count : 0
        let shown: Int = (showOnline ? visible.count : 0) + copies
        let total: Int = (showOnline ? pool.count : 0) + copies
        var line: String = listLoading ? T("Searching") : T("%lld of %lld sources", shown, total)
        let pending: Int = model.pendingAddonCount
        if pending > 0 { line += " · " + T("%lld addons loading", pending) }
        return line
    }

    // play-picker/stream-facets.ts, minus resolution and availability which the chips above own.
    struct Facet { let key: String; let label: String; let order: [String]; let valueOf: (ScoredStream) -> String? }
    static let facets: [Facet] = [
        Facet(key: "source", label: "Source", order: ["Remux", "BluRay", "WEB-DL", "WEBRip", "HDTV", "CAM"]) { s in
            if s.remux == true { return "Remux" }
            switch (s.source ?? "").uppercased() {
            case "BLURAY", "BDRIP", "BRRIP", "BLU-RAY": return "BluRay"
            case "WEB-DL", "WEBDL", "WEB": return "WEB-DL"
            case "WEBRIP", "HDRIP": return "WEBRip"
            case "HDTV", "DVDRIP": return "HDTV"
            case "CAM", "TS", "HDTS", "TC", "SCR": return "CAM"
            default: return nil
            }
        },
        Facet(key: "codec", label: "Codec", order: ["HEVC", "AV1", "AVC"]) { s in ["HEVC", "AV1", "AVC"].contains(s.codec ?? "") ? s.codec : nil },
        Facet(key: "hdr", label: "HDR", order: ["HDR", "SDR"]) { s in s.hdrFormat != nil ? "HDR" : "SDR" },
        Facet(key: "audio", label: "Audio", order: ["Atmos", "TrueHD", "DTS-HD", "DTS", "DD+"]) { s in
            switch s.audio?.codec { case "Atmos": return "Atmos"; case "TrueHD": return "TrueHD"; case "DTS-HD MA": return "DTS-HD"; case "DTS": return "DTS"; case "DD+": return "DD+"; default: return nil }
        },
    ]

    /// bp-stream-filters addonOrderMode: settings.streamSort === "addon" (the default) or an addon
    /// that ranks its own list; else the Harbor order.
    var sortByAddon: Bool { model.addonRanked || model.streamSort == "addon" }
    /// bp-stream-chips sort chip label (sortForced / sort === "addon" / Harbor's order).
    var sortChipLabel: String {
        T(model.addonRanked ? "Addon order (locked)" : (model.streamSort == "addon" ? "Addon order" : "Harbor pick"))
    }

    private func matchesFacets(_ s: ScoredStream, except: String? = nil) -> Bool {
        for f in Self.facets where f.key != except {
            guard let sel = facet[f.key] else { continue }
            if f.valueOf(s) != sel { return false }
        }
        return true
    }

    func facetOptions(_ f: Facet) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for s in pool where matchesFacets(s, except: f.key) {
            if let v = f.valueOf(s) { counts[v, default: 0] += 1 }
        }
        return f.order.compactMap { k in counts[k].map { (k, $0) } }
    }

    /// A facet chip steps All → each value that exists, like bp-stream-menu.
    func stepFacet(_ f: Facet) {
        let keys = facetOptions(f).map(\.0)
        if let cur = facet[f.key], let i = keys.firstIndex(of: cur) {
            if i + 1 < keys.count { facet[f.key] = keys[i + 1] } else { facet[f.key] = nil }
        } else { facet[f.key] = keys.first }
    }

    /// The addon chip steps All addons → each addon that listed a stream.
    func stepAddonFilter() {
        let list = [nil] + addons.map { Optional($0) }
        let i = list.firstIndex { $0 == addonFilter } ?? 0
        addonFilter = list[(i + 1) % list.count]
    }

    /// "Clear filters": every chip back to its default (the view moves the ring to "All").
    func clearFilters() {
        quality = "All"; cachedOnly = false; langFilter = false; addonFilter = nil; facet = [:]
    }

    var filtered: Bool { quality != "All" || cachedOnly || langFilter || addonFilter != nil || !facet.isEmpty }

    /// bp-stream-filters `base`, in its order: the stream mode (settings.streamMode), the preferred
    /// languages (langFilter), Cached only, then the active saved filter. Each step that would leave
    /// nothing is skipped; a saved filter that matched nothing, or a pool left empty, brings every
    /// stream back and the banner says so (filterFellBack).
    var filterPool: (streams: [ScoredStream], fellBack: Bool) {
        let key: PoolKey = poolKey
        // An equal key is adopted, so a re-sent but unchanged `streams` array (new storage, same
        // values) is compared element by element once, then by storage again.
        if let have = memo.poolKey, have == key { memo.poolKey = key; return memo.pool }
        let built: (streams: [ScoredStream], fellBack: Bool) = computeFilterPool()
        memo.poolKey = key
        memo.pool = built
        return built
    }

    /// bp-stream-filters keeps `base` and `visible` in useMemo; here `pool` and
    /// `visible` were computed properties that each body pass ran about twenty times over (every
    /// quality chip's count, the addon chip, four facet menus, the header counts, the list, the
    /// empty state), each a few filters and a sort over every listed stream, a large struct copied
    /// per kept element. Kept until an input changes; an unchanged `streams` array compares by
    /// storage in O(1).
    private final class PoolMemo {
        var poolKey: PoolKey?
        var pool: (streams: [ScoredStream], fellBack: Bool) = ([], false)
        var visibleKey: VisibleKey?
        var visible: [ScoredStream] = []
    }
    struct PoolKey: Equatable {
        var streams: [ScoredStream]
        var mode: String
        var langFilter: Bool
        var langs: [String]
        var cachedOnly: Bool
        var filterId: String?
    }
    struct VisibleKey: Equatable {
        var pool: PoolKey
        var quality: String
        var addonFilter: String?
        var facet: [String: String]
        var sortByAddon: Bool
        var addonOrder: [String]
        var rememberedIndex: Int?
        var switching: PlayingSource?
    }

    /// Everything `computeFilterPool` reads.
    private var poolKey: PoolKey {
        PoolKey(streams: model.streams, mode: model.streamMode, langFilter: langFilter,
                langs: model.setup?.preferredLangs ?? [], cachedOnly: cachedOnly,
                filterId: model.activeFilterId)
    }

    private func computeFilterPool() -> (streams: [ScoredStream], fellBack: Bool) {
        let candidates: [ScoredStream] = model.streams
        guard !candidates.isEmpty else { return (candidates, false) }
        var all: [ScoredStream] = candidates
        // filterStreamsByMode (its own keep-everything fallback is in the engine's flags).
        if model.streamMode == "addons" {
            all = all.filter { $0.tvModes?.addons ?? true }
        } else if model.streamMode == "p2p" {
            all = all.filter { $0.tvModes?.p2p ?? true }
        }
        let langs: [String] = model.setup?.preferredLangs ?? []
        if langFilter, !langs.isEmpty {
            let matched = all.filter { $0.tvLang ?? true }
            if !matched.isEmpty { all = matched }
        }
        if cachedOnly {
            let cached = all.filter(\.isCached)
            if !cached.isEmpty { all = cached }
        }
        var fellBack = false
        if let id = model.activeFilterId {
            let matched = all.filter { $0.tvFilters?.contains(id) ?? true }
            if matched.isEmpty { fellBack = true } else { all = matched }
        }
        if all.isEmpty {
            all = candidates
            fellBack = true
        }
        return (all, fellBack)
    }
    var pool: [ScoredStream] { filterPool.streams }

    /// bp-stream-filters langHiddenCount: streams (of every one listed) not in a preferred language.
    var langHiddenCount: Int {
        guard !(model.setup?.preferredLangs.isEmpty ?? true) else { return 0 }
        return model.streams.filter { !($0.tvLang ?? true) }.count
    }

    /// bp-stream-chips source chip label: Media servers, else the stream mode's name.
    var sourceChipLabel: String {
        if sourceKind == "media-server" { return T("Media servers") }
        switch model.streamMode {
        case "addons": return T("Direct/debrid only")
        case "p2p": return T("P2P only")
        default: return T("All sources")
        }
    }

    /// bp-stream-chips source menu value, and its options as one chip that steps through them:
    /// All sources, Media servers (when this title has a home-server copy), Direct/debrid only, P2P only.
    func nextSource() {
        let current: String = sourceKind == "online" || (sourceKind == "all" && model.streamMode != "both") ? model.streamMode : sourceKind
        var ids: [String] = ["all"]
        if switching == nil, !model.copies.isEmpty || sourceKind == "media-server" { ids.append("media-server") }
        ids.append("addons")
        ids.append("p2p")
        let at: Int = ids.firstIndex(of: current) ?? 0
        let next: String = ids[(at + 1) % ids.count]
        if next == "addons" || next == "p2p" {
            sourceKind = "online"
            model.setStreamMode(next)
        } else {
            if model.streamMode != "both" { model.setStreamMode("both") }
            sourceKind = next
        }
    }

    /// bp-streams showOnline / showHomeServers.
    var showOnline: Bool { sourceKind == "all" || sourceKind == "online" }
    /// bp-streams `homeServerCopies = download || switching ? [] : …`: none in the switcher.
    var showHomeServers: Bool { switching == nil && (sourceKind == "all" || sourceKind == "media-server") }

    /// bp-stream-chips filter chip: the active filter's name (or "Filter" when it has none), else "Filters".
    var filterChipLabel: String {
        guard let id = model.activeFilterId, let f = model.savedFilters.first(where: { $0.id == id }) else { return T("Filters") }
        return f.name.isEmpty ? T("Filter") : f.name
    }

    /// The filter menu (No filter, then each saved filter) as one chip that steps through it.
    func nextFilter() {
        let ids: [String?] = [nil] + model.savedFilters.map { Optional($0.id) }
        let i = ids.firstIndex { $0 == model.activeFilterId } ?? 0
        let next = ids[(i + 1) % ids.count]
        Task { await model.setActiveFilter(next) }
    }

    /// The sort chip: Harbor's order and the addon order swap (not while an addon ranks its own list).
    func toggleSort() {
        guard !model.addonRanked else { return }
        let next = sortByAddon ? "harbor" : "addon"
        Task { await model.setStreamSort(next) }
    }

    var visible: [ScoredStream] {
        // Everything `computeVisible` reads.
        let key = VisibleKey(pool: poolKey, quality: quality, addonFilter: addonFilter, facet: facet,
                             sortByAddon: sortByAddon, addonOrder: model.addonOrder,
                             rememberedIndex: model.rememberedIndex, switching: switching)
        if let have = memo.visibleKey, have == key { memo.visibleKey = key; return memo.visible }
        let built: [ScoredStream] = computeVisible()
        memo.visibleKey = key
        memo.visible = built
        return built
    }

    private func computeVisible() -> [ScoredStream] {
        let wanted = Self.qualities.first { $0.0 == quality }?.1 ?? []
        let filtered = pool.filter { s in
            (wanted.isEmpty || wanted.contains(s.resolution ?? "")) &&
            (addonFilter == nil || s.addonName == addonFilter) &&
            matchesFacets(s)
        }
        let sorted: [ScoredStream]
        if sortByAddon {
            // orderByAddonNative: addons in the installed order, each stream where its addon listed it.
            var rank: [String: Int] = [:]
            for (i, url) in model.addonOrder.enumerated() { rank[url] = i }
            sorted = filtered.sorted { a, b in
                let ra = a.addonUrl.flatMap { rank[$0] } ?? 9999, rb = b.addonUrl.flatMap { rank[$0] } ?? 9999
                if ra != rb { return ra < rb }
                let na = a.nativeIdx ?? Int.max, nb = b.nativeIdx ?? Int.max
                return na != nb ? na < nb : a.index < b.index
            }
        } else {
            // bp-stream-filters: cached first (base); with every addon shown, the Harbor order puts
            // WatchHub and still-downloading links last, then addons in installed order, then instant
            // markers first; ties keep the cached-first score order.
            var rank: [String: Int] = [:]
            for (i, url) in model.addonOrder.enumerated() where rank[url] == nil { rank[url] = i }
            let everyAddon = addonFilter == nil
            sorted = filtered.sorted { a, b in
                if everyAddon {
                    let wa = a.tvSort?.watchHub == true, wb = b.tvSort?.watchHub == true
                    if wa != wb { return wb }
                    let da = a.tvSort?.needsDownload == true, db = b.tvSort?.needsDownload == true
                    if da != db { return db }
                    let ra = a.addonUrl.flatMap { rank[$0] } ?? 9999, rb = b.addonUrl.flatMap { rank[$0] } ?? 9999
                    if ra != rb { return ra < rb }
                    let ia = a.tvSort?.instant == true, ib = b.tvSort?.instant == true
                    if ia != ib { return ia }
                }
                return a.isCached != b.isCached ? a.isCached : a.index < b.index
            }
        }
        let ordered: [ScoredStream] = pinnedFirst(sorted)
        // bp-streams switch mode `list`: the stream playing now moves to the front.
        guard let current = switching, let at = ordered.firstIndex(where: { current.matches($0) }), at > 0 else { return ordered }
        var out: [ScoredStream] = ordered
        let playing: ScoredStream = out.remove(at: at)
        out.insert(playing, at: 0)
        return out
    }

    /// bp-stream-filters `pinned`: the remembered stream leads the list whenever the filters keep it.
    private func pinnedFirst(_ list: [ScoredStream]) -> [ScoredStream] {
        guard let p = model.rememberedIndex, let i = list.firstIndex(where: { $0.index == p }) else { return list }
        var out = list
        let s = out.remove(at: i)
        out.insert(s, at: 0)
        return out
    }

    var addons: [String] { Array(Set(pool.map(\.addonName))).sorted() }

    /// The picker lifts its best pick; the switcher marks the stream playing now (bp-stream-row
    /// isCurrent: the stronger edge).
    func isHighlighted(_ s: ScoredStream) -> Bool {
        if let current = switching { return current.matches(s) }
        return s.id == model.primary?.id
    }

    // MARK: picking

    /// A row pressed: held from the press (the Task starts a beat later and the P2P consent read
    /// awaits, so a double press got past the guard and resolved the row twice). One
    /// pick at a time, guarded here rather than by disabling every row.
    func rowPressed(_ s: ScoredStream) {
        guard resolving == nil else { return }
        handPicked = true; resolving = s.id; Task { await pick(s) }
    }

    func copyPressed(_ c: StreamsModel.HomeCopy) {
        guard resolving == nil else { return }
        handPicked = true; resolving = c.key; Task { await pick(copy: c) }
    }

    func pick(copy: StreamsModel.HomeCopy) async {
        resolving = copy.key; resolveError = nil
        let r = await model.play(copy: copy, meta: meta)
        resolving = nil
        if r.ok, let ready = Self.playable(r) { openGated(nil, ready, focusKey: "copy:" + copy.key) }
        else if r.ok, r.data != nil { resolveError = Self.badLinkMessage }   //
        else { resolveError = T("This server couldn't start playback (%@).", r.code ?? "unknown") }
    }

    func pick(_ s: ScoredStream) async {
        if autoState == .waiting || { if case .firing = autoState { return true }; return false }() { autoState = .cancelled }
        // use-pick-handler onPlay: an uncached torrent the P2P engine could stream asks first.
        if await model.p2pConsentNeeded(s) {
            if resolving == s.id { resolving = nil }
            dialog = .p2p(s)
            return
        }
        await start(s, forceP2p: false)
    }

    /// use-pick-handler startResolve + resolveAndOpen for a committed pick.
    func start(_ s: ScoredStream, forceP2p: Bool) async {
        resolving = s.id; resolveError = nil
        let r = await resolveRetrying(s, forceP2p: forceP2p, sameSource: true) { [self] in resolving == s.id }
        guard alive, resolving == s.id else { return }
        resolving = nil
        if r.ok, let ready = Self.playable(r) {
            debridFailStreak = 0
            await model.remember(s, meta: meta, episode: episode, url: r.data?.url)
            // PlayerSrc.streamRef for use-stub-detection.ts; a pick by hand is never autoFired.
            var handed = ready
            handed.autoPicked = false
            handed.streamRef = await model.deadRef(s)
            openGated(s, handed, focusKey: "stream:" + s.id)
        } else if r.ok, r.data != nil {
            // The addon answered with a link no URL can be made of: say so (the call
            // sites used to drop it on `URL(string:)` and the picker just sat there).
            failedIds.insert(s.id)
            resolveError = Self.badLinkMessage
        } else {
            failedIds.insert(s.id)
            if countDebridFailure(r) { dialog = .debridDown; return }
            resolveError = r.message ?? T("Couldn't get a playable link (%@). Try another stream.", r.code ?? "unknown")
        }
    }

    /// The P2P dialog's "Stream" and "Always stream P2P".
    func streamViaP2p(_ s: ScoredStream, always: Bool) {
        dialog = nil
        Task {
            if always { await model.setP2pAutoConsent() }
            await start(s, forceP2p: true)
        }
    }

    // `static var`, not `let`: a `let` would cache the first-run language forever (T() re-reads
    // L10n.language on every call, a later language switch would otherwise never take).
    static var badLinkMessage: String { T("This stream's link isn't a valid address. Try another stream.") }

    // MARK: (S4) the subtitle step (use-bp-stream-play openPlayerGated / startPreselect / cancelPreselect)

    /// openPlayerGated: with settings.subtitlePreselect on, a pick by hand of a movie, series or
    /// anime stream waits on "Choose subtitles" before the player opens. Never for an auto-fired stream (instant play keeps its onPlay), a live or iptv
    /// source, nor in the in-player switcher (mode "switch" owns playback through onPick, which
    /// never reaches openPlayerGated). Kid profiles are not exempt upstream either.
    private func openGated(_ s: ScoredStream?, _ r: StreamsModel.Resolved, focusKey: String) {
        guard subtitleStepApplies(r) else { onPlay(s, r); return }
        preselect = PendingPreselect(stream: s, resolved: r, focusKey: focusKey)
    }

    private func subtitleStepApplies(_ r: StreamsModel.Resolved) -> Bool {
        guard subtitleStep, switching == nil, SettingsBridge.shared.slice.subtitlePreselect == true else { return false }
        guard r.autoPicked != true else { return false }
        guard !meta.id.hasPrefix("iptv:") else { return false }
        let kinds: [String] = ["movie", "series", "anime"]
        return kinds.contains(meta.type)
    }

    /// startPreselect(finalSrc): the step closes and the player opens with its choice (nil: Skip,
    /// the src unchanged).
    func startPreselect(_ choice: SubtitlePreselect?) {
        guard let pending = preselect else { return }
        preselect = nil
        var handed = pending.resolved
        handed.subtitlePreselect = choice
        onPlay(pending.stream, handed)
    }

    /// cancelPreselect: back to the stream list, the ring on the row that was picked.
    func cancelPreselect() {
        guard let pending = preselect else { return }
        preselect = nil
        let key = pending.focusKey
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in rowFocus = key }
    }

    /// The resolved result with its link as the player will open it (PlayableURL), or
    /// nil when there is no link or no URL can be made of it.
    static func playable(_ r: StreamsModel.Resolved) -> StreamsModel.Resolved? {
        guard var link = r.data, let url = PlayableURL.make(link.url) else { return nil }
        link.url = url.absoluteString
        var out = r
        out.data = link
        return out
    }
}
