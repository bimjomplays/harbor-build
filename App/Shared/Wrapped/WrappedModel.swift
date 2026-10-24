import SwiftUI

/// Stats (views/wrapped.tsx + views/wrapped/cards.tsx), reached from the Library's "Stats" chip
/// (views/library.tsx, gated by settings.wrappedButton). Upstream stacks the cards in a column;
/// on the TV they are a row of story cards the remote steps through with Left/Right, the top
/// titles open their detail page, and Back returns to the library.
@MainActor
final class WrappedModel: ObservableObject {
    struct TopTitle: Codable, Identifiable, Equatable { var title: String; var count: Int; var imdb: String?; var id: String; var type: String }
    struct Genre: Decodable, Equatable { var genre: String; var count: Int }
    struct Actor: Decodable, Equatable { var name: String; var count: Int; var photo: String? }
    struct Split: Decodable, Equatable { var movies: Int; var series: Int; var anime: Int }
    struct Play: Decodable, Equatable { var id: String; var title: String; var type: String; var watchedAt: Double }
    struct Binge: Decodable, Equatable { var date: String; var count: Int }
    struct Archetype: Decodable, Equatable { var id: String; var label: String; var blurb: String }
    struct HeatDay: Decodable, Equatable { var key: String; var count: Int; var level: Int }
    struct Stats: Decodable, Equatable {
        var source: String
        var year: Int?
        var totalTitles: Int
        var totalPlays: Int
        var estimatedHours: Int
        var topTitles: [TopTitle]
        var topGenres: [Genre]
        var topActors: [Actor]
        var posters: [String: String]
        var split: Split
        var firstPlay: Play?
        var lastPlay: Play?
        var longestBinge: Binge
        var archetype: Archetype
        var heatWeeks: [[HeatDay]]
        var bingeDate: String?
    }
    private struct Enriched: Decodable { var genres: [Genre]; var posters: [String: String]; var actors: [Actor] }

    @Published private(set) var stats: Stats?
    @Published private(set) var loading = true
    private var loaded = false

    func load() async {
        guard !loaded else { return }
        loaded = true
        let s: Stats? = try? await HarborEngine.shared.call("wrapped.load", [])
        stats = s
        loading = false
        // Second phase (enrichTopTitles): posters, genres and people land when TMDB / Cinemeta answer.
        guard let s, s.source != "empty", !s.topTitles.isEmpty else { return }
        let p = ProfilesStore.shared.active
        guard let e: Enriched = try? await HarborEngine.shared.call("wrapped.enrich", [s.topTitles, p?.id ?? "default", p?.linked ?? true]) as Enriched,
              var next = stats else { return }
        if !e.genres.isEmpty { next.topGenres = e.genres }
        next.topActors = e.actors
        next.posters = e.posters
        stats = next
    }
}
