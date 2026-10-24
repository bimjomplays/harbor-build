import SwiftUI

/// bp-sports-event.tsx: hero (league, pills, sides, score, facts, actions), then the Stats row
/// (live situation diagram, play by play, team statistics), Lineups (pitch, rosters, player
/// tables), Standings, Addon sources and Where to watch (venue + provider tiles).
@MainActor
final class SportsEventModel: ObservableObject {
    struct WatchOption: Decodable, Identifiable { var channelId: String; var name: String; var logo: String?; var url: String; var headers: [String: String]?; var tier: String; var attached: Bool; var label: String; var copy: String; var reasons: [String]; var score: Double; var id: String { channelId } }
    struct Provider: Decodable, Identifiable { var name: String; var url: String; var logo: String; var id: String { name } }
    /// bp-sports-broadcast-source: an official Twitch / YouTube / Kick broadcast (`app` is the provider's URL scheme).
    struct Broadcast: Decodable, Identifiable { var title: String; var url: String; var platform: String; var platformLabel: String; var app: String?; var id: String { url } }
    /// source-store AttachedStream (attached on desktop; the TV plays and clears it).
    struct AttachedStream: Decodable { var url: String; var title: String; var page: String; var kind: String; var headers: [String: String]?; var poster: String }
    struct Watch: Decodable {
        var plan: String; var label: String?; var fixture: String; var channels: [WatchOption]; var providers: [Provider]; var broadcasts: [Broadcast]
        var onAir: Bool?; var attachedStream: AttachedStream?; var sources: Int; var scanned: Int
        /// bp-sports-broadcast-picker canSearch (the index has channels), the league's pins and label.
        var searchable: Bool?; var attachedIds: [String]?; var leagueLabel: String?
    }

    // use-bp-sports-event useBpSportsEventActions (engine `sports.actions`).
    struct Reminder: Decodable { var active: Bool; var setup: Bool; var label: String }
    struct Follow: Decodable, Identifiable { var key: String; var name: String; var logo: String; var on: Bool; var label: String; var id: String { key } }
    struct Actions: Decodable { var reminder: Reminder?; var follow: [Follow]; var opendota: String? }
    struct ReminderOutcome: Decodable { var state: String }

    @Published private(set) var rows: SportsEventRows?
    @Published private(set) var loading = false
    /// use-match-detail: a summary has landed for this game (`detail !== null`,
    /// kept when a later refresh fails), and whether the last read failed.
    @Published private(set) var held = false
    @Published private(set) var failed = false
    @Published private(set) var watch: Watch?
    @Published private(set) var watching = false
    @Published private(set) var actions: Actions?
    struct WhoSides: Decodable { var home: Bool; var away: Bool }
    @Published private(set) var whoSides = WhoSides(home: false, away: false)

    /// bp-sports-event-hero whoOf: only sides with a profile subject are buttons.
    func loadWhoSides(_ game: SportsModel.Game) async {
        if let w: WhoSides = try? await HarborEngine.shared.call("sports.whoSides", [game.wire]) { whoSides = w }
    }

    /// bp-sports-watch.tsx: resolve what Watch can do (stream / broadcast / channel / addons / picker / setup / finished).
    /// The addon summary joins once `loadAddons` lands; neither waits on the other.
    func resolveWatch(_ game: SportsModel.Game) async {
        watchSeq += 1
        let seq = watchSeq
        watching = true; defer { if seq == watchSeq { watching = false } }
        let summary: AnyJSON = addons.map { .object(["matched": .number(Double($0.matched)), "available": .number(Double($0.available))]) } ?? .null
        let w: Watch? = try? await HarborEngine.shared.call("sports.watch", [game.wire, summary])
        // A slower earlier call (without the addon summary) must not overwrite a newer plan.
        if seq == watchSeq { watch = w }
    }
    private var watchSeq = 0

    // use-bp-sports-addon-sources: installed addons with sports catalogs, listings matched to the game.
    struct AddonRow: Decodable, Identifiable, Equatable { var key: String; var addonName: String; var addonLogo: String?; var name: String; var poster: String?; var match: String?; var id: String { key } }
    struct AddonSources: Decodable { var installed: Bool; var failed: Bool; var rows: [AddonRow]; var matched: Int; var available: Int }
    @Published private(set) var addons: AddonSources?
    @Published private(set) var addonsLoading = false
    var matchingAddons: [AddonRow] { addons?.rows.filter { $0.match != nil } ?? [] }

    func loadAddons(_ game: SportsModel.Game, force: Bool = false) async {
        guard game.state != "post" else { return }
        addonsLoading = true; defer { addonsLoading = false }
        let p = ProfilesStore.shared.active
        let authKey: AnyJSON = p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }.map { .string($0) } ?? .null
        addons = try? await HarborEngine.shared.call("sports.addonSources", [game.wire, authKey, force])
        await resolveWatch(game)
    }

    func togglePin(_ game: SportsModel.Game, _ option: WatchOption) async {
        _ = try? await HarborEngine.shared.callJSON("sports.toggleAttachedChannel", [.string(game.league), .string(option.channelId)])
        await resolveWatch(game)
    }

    /// bp-sports-watch pick: a chosen channel replaces the game's attached stream, then plays.
    func recordPlay(_ option: WatchOption, game: SportsModel.Game) {
        Task {
            _ = try? await HarborEngine.shared.callJSON("sports.recordChannelWatch", [.string(option.channelId)])
            if watch?.attachedStream != nil {
                _ = try? await HarborEngine.shared.callJSON("sports.clearAttachedStream", [.string(game.id)])
                await resolveWatch(game)
            }
        }
    }

    /// The page's `.task`s run again whenever a cover over it closes (the
    /// player, the addon panel, a who page, the channel search): the summary read started over
    /// ("Loading match details..." flashed, the Saved pill dropped) and every addon catalog was
    /// asked again. use-match-detail and use-bp-sports-addon-sources read once per game; the
    /// 30 s interval and Try again / Refresh ask again.
    /// Keyed by the game: another game in the same page reads again.
    private var detailStarted: String?
    private var addonsStarted: String?

    func loadOnce(_ game: SportsModel.Game) async {
        guard detailStarted != game.id else { return }
        detailStarted = game.id
        await load(game)
    }

    func loadAddonsOnce(_ game: SportsModel.Game) async {
        guard addonsStarted != game.id else { return }
        addonsStarted = game.id
        await loadAddons(game)
    }

    /// use-match-detail's effect (also its retry): the read starts over, loading, with nothing held.
    func load(_ game: SportsModel.Game) async {
        loading = true; defer { loading = false }
        held = false
        failed = false
        await readDetail(game)
        await loadRows(game)
    }

    /// use-match-detail's 30 s interval run for a game in progress: a failed read keeps what was held.
    func refresh(_ game: SportsModel.Game) async {
        await readDetail(game)
        // A failed read keeps the held rows too: eventRows went to the network a second
        // time for the summary that had just failed, answered empty, and took Stats and Lineups off
        // the page under "Showing saved match details." (a failed summary is not cached).
        guard !failed else { return }
        await loadRows(game)
    }

    /// use-match-detail run(): only whether a summary exists matters here (the rows come shaped from
    /// `sports.eventRows`). An official promoter card is never asked (useMatchDetail(game,
    /// !officialBoxing)).
    private func readDetail(_ game: SportsModel.Game) async {
        guard game.source != "official-boxing" else { return }
        do {
            let d = try await HarborEngine.shared.callJSON("sports.detail", [game.wire])
            if d.isNull {
                failed = true
            } else {
                held = true
                failed = false
            }
        } catch {
            failed = true
        }
    }

    /// Stats + Lineups rows from the (25 s cached) summary.
    func loadRows(_ game: SportsModel.Game) async {
        if let r: SportsEventRows = try? await HarborEngine.shared.call("sports.eventRows", [game.wire]) { rows = r }
    }

    func loadActions(_ game: SportsModel.Game) async {
        actions = try? await HarborEngine.shared.call("sports.actions", [game.wire])
    }

    /// The bell: "setup" means no webhook is configured yet (the caller opens the webhook fields).
    func toggleReminder(_ game: SportsModel.Game) async -> String {
        let r: ReminderOutcome? = try? await HarborEngine.shared.call("sports.toggleReminder", [game.wire])
        await loadActions(game)
        return r?.state ?? "error"
    }

    func toggleFollow(_ game: SportsModel.Game, _ key: String) async {
        _ = try? await HarborEngine.shared.callJSON("sports.toggleFollow", [game.wire, .string(key)])
        await loadActions(game)
    }
}
