import SwiftUI
import UIKit

/// views/kids-detail.tsx without React: Cinemeta + TMDB merged in the engine (engine/kids.ts
/// detail), then one TMDB season at a time (kids-detail/kids-episodes.tsx).
@MainActor
final class KidsDetailModel: ObservableObject {
    struct Season: Decodable, Hashable { var seasonNumber: Int; var name: String }
    struct Collection: Decodable { var id: Int; var name: String; @LossyArray var metas: [Meta] }   // lossy
    struct Detail: Decodable {
        var name: String
        var backdrop: String?
        var logo: String?
        var overview: String
        var genres: [String]
        var runtime: String?
        var year: String?
        var tvId: Int?
        var seasons: [Season]
        var collection: Collection?
        @LossyArray var recs: [Meta]
    }
    struct Episode: Decodable, Identifiable, Equatable {
        var id: Int
        var season: Int
        var episode: Int
        var name: String
        var still: String?
        var rating: String?
        /// TMDB's air_date (engine kidsRoom.episodes), for the next episode's aired check.
        var airDate: String?

        /// cw-resurface.ts isNextAired(false, airDate), as views/player.tsx airedNext reads it:
        /// no date (or one that does not parse) counts as aired.
        var aired: Bool {
            guard let d = airDate, !d.isEmpty else { return true }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withFullDate]
            guard let t = f.date(from: String(d.prefix(10))) else { return true }
            return t <= Date()
        }
    }

    let meta: Meta
    @Published private(set) var detail: Detail?
    @Published private(set) var episodes: [Episode] = []
    @Published private(set) var episodesLoading = true
    @Published private(set) var season = 1

    init(meta: Meta) { self.meta = meta }

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    /// The page's `.task` runs again whenever a cover over it closes (the picker, the
    /// player, a related title). Reloading reset the season to the first one, so after an episode
    /// of Season 3 the grid jumped back to Season 1. Once loaded, keep what is there.
    func load() async {
        guard detail == nil else { return }
        let p = profile
        let d: Detail? = try? await HarborEngine.shared.call("kidsRoom.detail", [meta, p.id, p.linked])
        guard detail == nil else { return }
        detail = d
        if let d {
            await CardMarksStore.shared.refresh(d.recs + (d.collection?.metas ?? []))
            // kids-episodes.tsx: useState(seasons[0]?.seasonNumber ?? 1).
            if d.tvId != nil {
                season = d.seasons.first?.seasonNumber ?? 1
                await loadEpisodes()
            }
        }
    }

    func choose(_ s: Int) {
        guard s != season else { return }
        season = s
        Task { await loadEpisodes() }
    }

    /// (open-items sweep) Every season's episodes once read. The next episode was looked up in the
    /// season on screen only, so a kid who picked another season and then pressed the hero's Play
    /// (S1 E1, or the page's episode hint) got no up-next and no auto-advance.
    private(set) var seasonEpisodes: [Int: [Episode]] = [:]

    /// The episodes of a season that plays, read if the page has not shown it.
    func ensureSeason(_ s: Int) async {
        guard seasonEpisodes[s] == nil, let tvId = detail?.tvId else { return }
        let p = profile
        let list: [Episode] = (try? await HarborEngine.shared.call("kidsRoom.episodes", [tvId, s, p.id, p.linked])) ?? []
        if !list.isEmpty { seasonEpisodes[s] = list }
    }

    /// The season after `s` in the page's season list. Specials (season 0) never lead
    /// into a season or follow one, as the adult page's airedNext.
    func seasonAfter(_ s: Int) -> Int? {
        guard s > 0, let list = detail?.seasons, let i = list.firstIndex(where: { $0.seasonNumber == s }), i + 1 < list.count else { return nil }
        let n: Int = list[i + 1].seasonNumber
        return n > 0 ? n : nil
    }

    /// Reads the season an episode plays in and, when that episode ends it, the next
    /// season, while the picker is up. views/player.tsx takes the next episode from
    /// fetchAdjacentEpisodes, which crosses seasons; the kids page looked in the playing season
    /// only, so the last episode of a season had no up-next and never auto-advanced.
    func prefetch(season s: Int, episode e: Int) async {
        await ensureSeason(s)
        guard let list = seasonEpisodes[s], let last = list.last, last.season == s, last.episode == e,
              let n = seasonAfter(s) else { return }
        await ensureSeason(n)
    }

    private func loadEpisodes() async {
        guard let tvId = detail?.tvId else { return }
        let p = profile
        let asked = season
        episodesLoading = true
        let list: [Episode] = (try? await HarborEngine.shared.call("kidsRoom.episodes", [tvId, asked, p.id, p.linked])) ?? []
        if !list.isEmpty { seasonEpisodes[asked] = list }
        guard asked == season else { return }
        episodes = list
        episodesLoading = false
    }
}
