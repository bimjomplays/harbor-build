import SwiftUI

/// The state and logic behind the in-player Subtitles dialog (
/// bp-player-subtitles.tsx): the track lists and their labels / best match from the engine
/// (`subtitles.trackView`), Find more (`subtitles.find`, `prepare`), the manual offset and the Look
/// values, with no view in it. PlayerSubtitlesPanel draws it on the TV with the remote's focus ring;
/// the phone's sheet will draw over the same model.
///
/// Every property is @Published where it was @State, so a write redraws the view exactly as before.
/// The ring itself is the view's @FocusState; the model reads and moves it through `bindFocus`.
@MainActor
final class SubtitlesPanelModel: ObservableObject {
    enum Lane: Hashable { case tracks, find, sync, style }

    struct TrackRow: Decodable { var id: String; var keep: Bool; var langKey: String; var langDisplay: String; var title: String; var detail: String; var tags: [String] }
    struct Ranked: Decodable { var id: String; var eligible: Bool }
    struct TrackView: Decodable { var tracks: [TrackRow]; var ranked: [Ranked] }
    struct TrackIn: Encodable {
        var id: Int
        var lang: String?
        var title: String?
        var codec: String?
        var external: Bool
        var forced: Bool
        var hearingImpaired: Bool
        var `default`: Bool
        var selected: Bool
        var secondary: Bool
        var externalFilename: String?
    }
    struct LangGroup: Identifiable { var id: String; var display: String; var count: Int }
    /// bp-subtitle-find.tsx BpSubtitleTarget.
    struct Target: Codable, Equatable { var imdbId: String; var type: String; var title: String; var season: Int?; var episode: Int? }
    struct Found: Decodable, Identifiable {
        var id: String; var url: String; var lang: String; var langName: String; var title: String
        var detail: String; var tags: [String]; var provider: String; var hearingImpaired: Bool; var forced: Bool
        /// The row's identity: a provider's id alone can repeat.
        /// (open-items sweep 3) With the source first, as bp-subtitle-find keys a row
        /// (`${r.source}:${r.id}:${r.url}`): two sources answering with the same id and URL were one key.
        var key: String { provider + ":" + id + "|" + url }
    }
    struct FindResult: Decodable { var results: [Found]; var tooNew: Bool }
    struct Preset: Decodable, Identifiable { var id: String; var name: String; var values: [String: AnyJSON] }

    static let all = "__all__"
    static let page = 40

    // MARK: inputs
    /// Refreshed by `refreshInputs` on every body pass: the screen swaps the engine (retry, switch) and hands a
    /// dialog opened while the file was still opening its controller later, so these can change under it.
    private(set) var controller: (any PlayerEngineControlling)?
    private(set) var context: PlaybackContext?
    let title: String
    /// The screen's subtitle delay (PlayerSession.subDelay): the dialog reads and writes it there.
    private var subDelayBinding: Binding<Double>

    /// The AVPlayer engine draws every subtitle itself (sideloaded ones as the html5 bridge does, the
    /// file's own through its legible output), so Find more, Sync and Look work on both engines; a
    /// second subtitle there must be one of the sideloaded tracks.
    var mpvExtras: Bool { controller?.supportsMpvExtras ?? true }
    /// Which engine the dialog reads; its track poll restarts with a new one.
    var engineKey: ObjectIdentifier? { controller.map { ObjectIdentifier($0 as AnyObject) } }

    var subDelay: Double {
        get { subDelayBinding.wrappedValue }
        set { subDelayBinding.wrappedValue = newValue }
    }

    // MARK: state
    @Published var lane: Lane = .tracks
    @Published var tracks: [MPVPlayerController.Track] = []
    @Published var rows: [String: TrackRow] = [:]
    @Published var ranked: [Ranked] = []
    @Published var activeLang = SubtitlesPanelModel.all
    @Published var source = "all"
    @Published var hideHI = false
    @Published var forcedOnly = false
    @Published var presets: [Preset] = []
    /// (open-items sweep) Look values asked for and not saved yet. The steppers stepped from the
    /// saved setting, so two presses before the first save landed made one step.
    @Published var lookDraft: [String: Double] = [:]

    // Find more (bp-subtitle-find.tsx)
    @Published var target: Target?
    @Published var override = false
    @Published var query = ""
    @Published var results: [Found]?
    @Published var tooNew = false
    @Published var searching = false
    @Published var limit = SubtitlesPanelModel.page
    @Published var added: Set<String> = []
    @Published var findNote: String?

    private var seq = 0
    private var ranOnce = false
    /// Only the newest trackView answer lands.
    private var refreshRun = 0
    /// The Tracks lane's ring was seeded before the file had any tracks.
    private var seededEmpty = false

    // MARK: focus ring (the view's @FocusState, bound through closures)

    private var focusReader: () -> String? = { nil }
    private var focusWriter: (String?) -> Void = { _ in }
    /// The ring's current target; writing it moves the ring. Both go to the view's @FocusState.
    var focus: String? {
        get { focusReader() }
        set { focusWriter(newValue) }
    }

    /// The view hands over its @FocusState (capturing only the state, never the view or the model).
    func bindFocus(read: @escaping () -> String?, write: @escaping (String?) -> Void) {
        focusReader = read
        focusWriter = write
    }

    /// The view's current inputs, set before it reads `engineKey` so a new engine restarts the track poll.
    func refreshInputs(controller: (any PlayerEngineControlling)?, context: PlaybackContext?, subDelay: Binding<Double>) {
        self.controller = controller
        self.context = context
        self.subDelayBinding = subDelay
    }

    init(controller: (any PlayerEngineControlling)?, context: PlaybackContext?, title: String, subDelay: Binding<Double>) {
        self.controller = controller
        self.context = context
        self.title = title
        self.subDelayBinding = subDelay
    }

    // MARK: lifecycle

    func appeared() {
        if target == nil { target = home; query = context?.meta.name ?? title }
        added.formUnion(TrackPlanner.addedSources)
        // The show's remembered delay was applied when the file opened.
        if let d = controller?.currentSubDelay() { subDelay = (d * 10).rounded() / 10 }
        Task {
            await refresh()
            seedFocus()
            if let list = try? await loadPresets() { presets = list }
        }
    }

    // upstream's dialog reads the live snapshot's tracks. This one read them
    // once: opened while the file was still opening, or before the remembered subtitle came
    // back from its download, it showed "No subtitles" / Off under a subtitle that was on.
    // Keyed to the engine: a reload under the dialog hands it a new one to read.
    func pollTracks() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            let now = (controller?.tracks() ?? []).filter { $0.type == "sub" }
            if now != tracks {
                await refresh()
                // Opened before the file's tracks were read, the ring was
                // seeded on "No subtitles": once they arrive with one on, it moves there while
                // the viewer has not moved it.
                // One chance only: the first arrival spends it even when the viewer
                // had moved, so a later track change never pulls the ring off "No subtitles".
                if seededEmpty, !tracks.isEmpty {
                    seededEmpty = false
                    if lane == .tracks, focus == "line-off" { seedFocus() }
                }
            }
        }
    }

    func laneChanged() {
        if lane == .find, !ranOnce, let t = target {
            ranOnce = true
            Task { await run(t) }
        }
        seedFocus()
    }

    // MARK: header

    var isSeries: Bool { context?.season != nil && context?.episode != nil }

    var headerLine: String {
        let name = context?.meta.name ?? title
        let where_: String
        if isSeries, let s = context?.season, let e = context?.episode {
            where_ = "\(name) · S\(String(format: "%02d", s))E\(String(format: "%02d", e))"
        } else {
            where_ = name
        }
        let on = tracks.first { $0.selected }.map { titleOf($0) } ?? T("Off")
        return "\(where_) · \(on) · \(offsetLabel)"
    }

    /// bp-subtitle-parts.tsx offsetLabel.
    var offsetLabel: String {
        subDelay == 0 ? T("In sync") : "\(subDelay > 0 ? "+" : "")\(String(format: "%.1f", subDelay))s"
    }

    /// The shell seeds focus from the panel id, never the lane, so each lane seeds its own ring.
    func seedFocus() {
        let seed: String
        switch lane {
        case .tracks:
            // bp-player-subtitles seeds the lane's data-bp-autofocus line (the
            // chosen track, else "No subtitles"), else the lane's first focusable, "All languages":
            // a chosen track the filters hide left the ring on the lane chip.
            let on: MPVPlayerController.Track? = tracks.first { $0.selected }
            if let on {
                let shown: Bool = visible.contains(where: { $0.id == on.id })
                seed = shown ? "line-\(on.id)" : "lang-all"
            } else {
                seed = "line-off"
            }
            seededEmpty = tracks.isEmpty
        case .find: seed = "chip-Search"
        case .sync: seed = "chip--0.1s"
        case .style: seed = presets.first.map { "chip-\($0.name)" } ?? "chip-Shadow"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in focus = seed }
    }

    // MARK: Tracks

    func row(_ t: MPVPlayerController.Track) -> TrackRow? { rows[String(t.id)] }
    func titleOf(_ t: MPVPlayerController.Track) -> String { row(t)?.title ?? t.label }

    /// langTracks: the viewer's languages, plus whatever is selected or secondary.
    var langTracks: [MPVPlayerController.Track] { tracks.filter { row($0)?.keep ?? true } }

    /// groupByLang, in first-seen order.
    var groups: [LangGroup] {
        var out: [LangGroup] = []
        for t in langTracks {
            let key = row(t)?.langKey ?? "embedded"
            if let i = out.firstIndex(where: { $0.id == key }) { out[i].count += 1 }
            else { out.append(LangGroup(id: key, display: row(t)?.langDisplay ?? "Embedded", count: 1)) }
        }
        return out
    }

    var visible: [MPVPlayerController.Track] {
        let pool = activeLang == Self.all ? langTracks : langTracks.filter { row($0)?.langKey == activeLang }
        return pool.filter { t in
            if source == "embedded" && t.external { return false }
            if source == "external" && !t.external { return false }
            if hideHI && t.hearingImpaired { return false }
            return !(forcedOnly && !t.forced)
        }
    }

    /// best-match.ts pickBestMatch(visible): the first ranked track inside the pool, if it clears the gate.
    var best: MPVPlayerController.Track? {
        let ids = Set(visible.map { String($0.id) })
        guard let top = ranked.first(where: { ids.contains($0.id) }), top.eligible else { return nil }
        return visible.first { String($0.id) == top.id }
    }

    func select(_ t: MPVPlayerController.Track?) {
        controller?.select(track: t, type: "sub")
        // bp-ten-foot onSubtitle → rememberSubChoice: the show's language (or off) and this episode's track.
        controller?.rememberSubtitle(t)
        refreshSoon()
    }

    /// setSecondarySub: a second track under the first, or off again (on AVPlayer, added tracks only).
    func toggleSecondary(_ t: MPVPlayerController.Track) {
        controller?.setSecondarySub(t.secondary ? nil : t)
        refreshSoon()
    }

    func refreshSoon() {
        Task {
            await refresh()
            try? await Task.sleep(for: .milliseconds(250))
            await refresh()
        }
    }

    /// mpv's subtitle tracks, then upstream's labels and best-match order for them.
    func refresh() async {
        let list = (controller?.tracks() ?? []).filter { $0.type == "sub" }
        tracks = list
        refreshRun += 1
        let run = refreshRun
        let ins = list.map { t in
            TrackIn(id: t.id, lang: t.lang, title: t.title, codec: t.codec, external: t.external, forced: t.forced,
                    hearingImpaired: t.hearingImpaired, default: t.isDefault, selected: t.selected, secondary: t.secondary,
                    externalFilename: t.externalFilename)
        }
        let p = ProfilesStore.shared.active
        do {
            let view: TrackView = try await HarborEngine.shared.call("subtitles.trackView",
                [p?.id ?? "default", p?.linked ?? true, ins, controller?.streamFilename(), context?.season, context?.episode])
            // An older answer (the list before the viewer's pick, or before the
            // file's tracks arrived) landing last put back its rows: the picked track could drop
            // out of the list (its `keep` computed while another one was selected).
            guard run == refreshRun else { return }
            var byId: [String: TrackRow] = [:]
            for r in view.tracks { byId[r.id] = r }
            rows = byId
            ranked = view.ranked
        } catch {
            guard run == refreshRun else { return }
            rows = [:]
            ranked = []
        }
    }

    // MARK: Find more (bp-subtitle-find.tsx)

    var home: Target {
        let meta = context?.meta
        let imdb = context?.imdbId ?? ((meta?.id.hasPrefix("tt") ?? false) ? (meta?.id ?? "") : "")
        return Target(imdbId: imdb, type: isSeries ? "series" : "movie", title: meta?.name ?? title,
                      season: isSeries ? context?.season : nil, episode: isSeries ? context?.episode : nil)
    }

    /// Results without the filtered-out HI / non-forced entries, grouped by language in first-seen order.
    var flat: [Found] {
        let kept = (results ?? []).filter { !(hideHI && $0.hearingImpaired) && !(forcedOnly && !$0.forced) }
        var order: [String] = []
        var byLang: [String: [Found]] = [:]
        // (open-items sweep 3) A row whose key repeats (the same source listing one file twice) is
        // drawn once: ForEach and the ring's focus value need each key once.
        var seen: Set<String> = []
        for r in kept {
            guard seen.insert(r.key).inserted else { continue }
            if byLang[r.langName] == nil { order.append(r.langName) }
            byLang[r.langName, default: []].append(r)
        }
        return order.flatMap { byLang[$0] ?? [] }
    }

    /// The "Back to what's playing" chip.
    func backToPlaying() {
        // The chip leaves with the override: the ring goes to Search.
        focus = "chip-Search"
        override = false
        query = context?.meta.name ?? title
        target = home
        Task { await run(home) }
    }

    /// The "Show N more" chip.
    func showMore() {
        let list = flat
        // The last page takes the chip away: the ring goes to the
        // first row it revealed instead of wherever the focus engine put it.
        let from: Int = limit
        limit += Self.page
        // Once the revealed row is drawn: set in the press itself, the ring
        // aimed at a row the list did not have yet.
        if from < list.count, list.count <= from + Self.page {
            let ring: String = "find-\(list[from].key)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in focus = ring }
        }
    }

    func changeEp(season: Int?, episode: Int?) {
        guard var t = target else { return }
        t.season = season
        t.episode = episode
        target = t
        Task { await run(t) }
    }

    func run(_ t: Target) async {
        seq += 1
        let mine = seq
        searching = true
        results = nil
        limit = Self.page
        findNote = nil
        let p = ProfilesStore.shared.active
        let authKey = p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
        let found: FindResult?
        do {
            let r: FindResult = try await HarborEngine.shared.call("subtitles.find",
                [p?.id ?? "default", p?.linked ?? true, authKey, t, home, context?.meta.id, context?.meta.releaseDate])
            found = r
        } catch {
            found = nil
            findNote = error.localizedDescription
        }
        guard mine == seq else { return }
        results = found?.results ?? []
        tooNew = found?.tooNew ?? false
        searching = false
    }

    /// submit(): a typed title (with an optional "S2E5" or year) becomes the new target.
    func submit() async {
        guard let current = target else { return }
        searching = true
        results = nil
        let resolved: Target?
        do {
            let t: Target = try await HarborEngine.shared.call("subtitles.titleTarget", [query, current])
            resolved = t
        } catch {
            resolved = nil
        }
        guard let next = resolved else { await run(current); return }
        target = next
        override = true
        await run(next)
    }

    /// Download + decode through the engine (zips, encodings), then hand mpv a local file.
    func add(_ r: Found) async {
        struct Prepared: Decodable { var text: String; var format: String }
        do {
            // One cache name per URL (TrackPlanner.subtitleFile), shared with the
            // remembered-subtitle restore: a result already prepared is not downloaded again, and
            // the next visit to this episode reuses the file. (The name was the provider's result
            // id, which can be long or carry characters a file name cannot.)
            let file: URL
            if let cached = TrackPlanner.cachedSubtitleFile(source: r.url) {
                file = cached
            } else {
                let prep: Prepared = try await HarborEngine.shared.call("subtitles.prepare", [r.url])
                try FileManager.default.createDirectory(at: TrackPlanner.subsDir, withIntermediateDirectories: true)
                file = TrackPlanner.subtitleFile(source: r.url, format: prep.format)
                try prep.text.write(to: file, atomically: true, encoding: .utf8)
            }
            controller?.addSubtitle(file: file, title: r.title, lang: r.lang)
            controller?.rememberAddedSubtitle(file: file, source: r.url, title: r.title, lang: r.lang)
            added.insert(r.url)
            TrackPlanner.addedSources.insert(r.url)
            findNote = nil
            refreshSoon()
        } catch {
            findNote = T("Couldn't load that subtitle: %@", error.localizedDescription)
        }
    }

    // MARK: Sync (bp-subtitle-tune.tsx BpSubtitleSync, manual offset)

    func setDelay(_ value: Double) {
        subDelay = value
        controller?.setSubDelay(value)
        controller?.rememberSubDelay(value)
        objectWillChange.send()
    }

    /// A nudge chip: the delay steps by `step`, rounded to a tenth.
    func nudgeDelay(by step: Double) { setDelay(((subDelay + step) * 10).rounded() / 10) }

    // MARK: Look (bp-subtitle-tune.tsx BpSubtitleLook)

    /// (open-items sweep) One Look stepper press: the next press steps from this value, not from
    /// the setting still being saved.
    func stepLook(_ key: String, _ value: Double) {
        lookDraft[key] = value
        Task {
            try? await SettingsBridge.shared.patch([key: .number(value)])
            if lookDraft[key] == value { lookDraft[key] = nil }
            controller?.refreshSubtitleStyle()
        }
    }

    func update(_ change: [String: AnyJSON]) {
        // (open-items sweep) A preset or reset replaces any stepper value still being saved.
        for key in change.keys { lookDraft[key] = nil }
        Task {
            try? await SettingsBridge.shared.patch(change)
            controller?.refreshSubtitleStyle()
        }
    }

    private func loadPresets() async throws -> [Preset] {
        let list: [Preset] = try await HarborEngine.shared.call("subtitles.presets", [])
        return list
    }

    func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
}
