import Foundation
import Combine

/// bp-sports-addon-panel (+ -listings, -streams, -play) state and logic, lifted out of the TV's
/// SportsAddonPanelView: the listing filter and pages, the picked listing's streams, the pick
/// (play / external page / hand-off to the stream list) and the focus seed. The view draws and owns
/// the focus ring; this model reaches it through `bindFocus`. The event model (`sports`) is the
/// view's own observed object and stays where it is.
@MainActor
final class SportsAddonPanelModel: ObservableObject {
    struct Play: Identifiable {
        let url: URL
        let headers: [String: String]
        let title: String
        let subtitle: String?
        let isLive: Bool
        /// bp-sports-addon-play openPlayer `subtitles: result.data.subtitles`: the stream's own subtitles.
        var subtitles: [SeedSubtitle] = []
        var id: String { url.absoluteString }
    }
    struct StreamRow: Decodable, Identifiable { var index: Int; var name: String; var title: String; var external: Bool; var id: Int { index } }
    struct Streams: Decodable { var status: String; var pick: Int?; var rows: [StreamRow] }
    struct Outcome: Decodable { var kind: String; var url: String?; var headers: [String: String]?; var title: String?; var subtitle: String?; var subtitles: [SeedSubtitle]?; var meta: Meta? }
    struct External: Identifiable { let url: String; var id: String { url } }

    /// bp-sports-addon-panel seedRef: the panel opens on the first listing
    /// (it opened on the name field, where Select brings up the keyboard), a picked listing's first
    /// stream takes the focus when the streams land (it stayed on Back, below the list), and Back
    /// returns to the first listing. A seed never pulls the focus off a place the viewer moved to.
    enum Seat: Hashable { case search, browse, refresh, close, more, back, listing(String), stream(Int) }

    static let page = 24

    let game: SportsModel.Game
    let sports: SportsEventModel
    private let initial: SportsEventModel.AddonRow?
    private var onPlay: (Play) -> Void
    private var onClose: () -> Void

    @Published var browse = false
    @Published var query = ""
    @Published var limit = SportsAddonPanelModel.page
    @Published var picked: SportsEventModel.AddonRow?
    @Published var streams: [StreamRow] = []
    @Published var pending = false
    @Published var playing: Int?
    @Published var fault = ""          // "" | "stream" | "listing"
    @Published var external: External?
    @Published var handoff: Meta?
    private var seeded = false
    /// Off screen: closed, or under one of its own covers.
    private var gone = false
    private var placed: Seat?
    private var placedFor: String?
    /// The pick number of the streams on screen. The engine keeps each listing's streams
    /// (sports.ts addonPicked) and answers with what it holds for the listing, numbered by pick, so
    /// an answer below the one shown is stale. Play names the listing, so the streams shown play.
    private var shownPick = 0

    private var readSeat: () -> Seat? = { nil }
    private var writeSeat: (Seat?) -> Void = { _ in }

    init(game: SportsModel.Game, sports: SportsEventModel, initial: SportsEventModel.AddonRow?,
         onPlay: @escaping (Play) -> Void, onClose: @escaping () -> Void) {
        self.game = game
        self.sports = sports
        self.initial = initial
        self.onPlay = onPlay
        self.onClose = onClose
    }

    /// The view's current callbacks.
    func update(onPlay: @escaping (Play) -> Void, onClose: @escaping () -> Void) {
        self.onPlay = onPlay
        self.onClose = onClose
    }

    /// The view's @FocusState, reached through closures.
    func bindFocus(read: @escaping () -> Seat?, write: @escaping (Seat?) -> Void) {
        readSeat = read
        writeSeat = write
    }

    private var seat: Seat? {
        get { readSeat() }
        set { writeSeat(newValue) }
    }

    static func matchCopy(_ row: SportsEventModel.AddonRow) -> String {
        switch row.match {
        case "event": return row.addonName + " · " + T("Event matchup found")
        case "channel": return row.addonName + " · " + T("Possible match · check the broadcast")
        default: return row.addonName
        }
    }

    var rows: [SportsEventModel.AddonRow] { sports.addons?.rows ?? [] }
    var filtered: [SportsEventModel.AddonRow] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        return rows.filter { ($0.match != nil || browse) && (needle.isEmpty || "\($0.name) \($0.addonName)".lowercased().contains(needle)) }
    }

    // MARK: lifecycle

    func appeared() { gone = false }
    func disappeared() { gone = true }

    /// The panel's task: open the initial listing, then seat the focus (once).
    func seedOnce() {
        guard !seeded else { return }
        seeded = true
        if let r = initial { choose(r) }
        seedFocus()
    }

    /// Back on the streams view, else the panel closes.
    func exitPressed() { if picked != nil { back() } else { onClose() } }

    func close() { onClose() }

    func toggleBrowse() { browse.toggle(); limit = Self.page }

    func moreChannels() { limit += Self.page }

    func refresh() {
        guard !sports.addonsLoading else { return }
        Task { await sports.loadAddons(game, force: true) }
    }

    /// The hand-off cover's stream list picked something: the panel plays it.
    func handoffPlayed(_ meta: Meta, _ resolved: StreamsModel.Resolved) {
        guard let link = resolved.data, let url = PlayableURL.make(link.url) else { return }   // the picker checked it
        handoff = nil
        onPlay(Play(url: url, headers: link.headers ?? [:], title: meta.name, subtitle: picked?.addonName, isLive: !["movie", "series"].contains(meta.type),
                    subtitles: link.subtitles ?? []))
    }

    // MARK: focus seed (bp-sports-addon-panel `view` / `placed`)

    /// Which list is up, and whether it has anything in it yet.
    var seedKey: String {
        let filled: Bool = picked != nil ? !streams.isEmpty : !rows.isEmpty
        return (picked?.key ?? "list") + (filled ? ":ready" : ":empty")
    }

    /// bp-sports-addon-streams / -listings seedRef: the first stream (Back while none), the first
    /// listing shown (Browse when none match, Refresh when there are none at all).
    private var seedTarget: Seat {
        if picked != nil { return streams.first.map { Seat.stream($0.index) } ?? Seat.back }
        if let first = filtered.first { return Seat.listing(first.key) }
        return rows.isEmpty ? Seat.refresh : Seat.browse
    }

    func seedFocus() {
        let listing: String = picked?.key ?? "list"
        if placedFor != listing { placedFor = listing; placed = nil }
        let target: Seat = seedTarget
        DispatchQueue.main.async { [self] in
            // The viewer moved on from the last seed: leave the focus where they put it.
            if let p = placed, let now = seat, now != p { return }
            placed = target
            seat = target
        }
    }

    // MARK: picking

    func choose(_ row: SportsEventModel.AddonRow) {
        picked = row; streams = []; pending = true; playing = nil; fault = ""; shownPick = 0
        Task {
            let out: Streams? = try? await HarborEngine.shared.call("sports.addonStreams", [row.key])
            guard picked?.key == row.key else { return }
            if out?.status == "ok", let p = out?.pick {
                guard p >= shownPick else { return }
                shownPick = p
            }
            // A failed answer of this listing's other pick (Back, then the same listing
            // again) landing after streams are up said "Could not load the streams" over streams
            // that still play (the engine keeps them): once streams show, only a reload changes them.
            let status: String = out?.status ?? ""
            if shownPick > 0, status != "ok", status != "reload" { return }
            pending = false
            switch out?.status {
            case "ok": streams = out?.rows ?? []
            case "reload": back(); await sports.loadAddons(game, force: false)
            default: fault = "listing"
            }
        }
    }

    func back() { picked = nil; streams = []; pending = false; playing = nil; fault = "" }

    func play(_ row: SportsEventModel.AddonRow, _ st: StreamRow) {
        guard playing == nil else { return }
        playing = st.index; fault = ""
        Task {
            let out: Outcome? = try? await HarborEngine.shared.call("sports.addonPlay", [row.key, st.index])
            // The viewer went Back to the listings, or closed the panel, while the addon
            // answered: a late "play" closed the event's covers and started the stream anyway.
            guard picked?.key == row.key, !gone else { return }
            playing = nil
            switch out?.kind {
            case "play":
                if let s = out?.url, let url = URL(string: s) {
                    onPlay(Play(url: url, headers: out?.headers ?? [:], title: out?.title ?? row.name, subtitle: out?.subtitle, isLive: true,
                                subtitles: out?.subtitles ?? []))
                } else { fault = "stream" }
            case "external":
                if let u = out?.url { external = External(url: u) } else { fault = "stream" }
            case "handoff":
                if let m = out?.meta { handoff = m } else { fault = "stream" }
            case "reload":
                back(); await sports.loadAddons(game)
            default:
                fault = "stream"
            }
        }
    }
}
